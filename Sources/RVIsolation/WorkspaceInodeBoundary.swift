#if os(macOS)
import Darwin
import Foundation
import RVDomain
import Synchronization

/// Identity of one workspace name, captured before the contained process runs.
struct WorkspaceInodeStamp: Equatable, Sendable {
    var device: UInt64
    var inode: UInt64
    var linkCount: UInt64
    var kind: Kind

    enum Kind: Equatable, Sendable {
        case directory
        case regular
        case symlink
    }
}

enum WorkspacePublishDecision: Equatable, Sendable {
    /// The saved inode is still the one captured before launch. Write it.
    case update
    /// The agent created a name. Create a new inode. Never attach an existing one.
    case create
    /// The agent removed a name whose inode is still the captured one.
    case remove
    /// A name the snapshot does not own. Do not unlink it.
    case leave
    /// The saved name is a different inode, or a file's link count changed.
    case reject
}

/// Whether copy-back may treat `live` as the captured inode.
///
/// A directory's link count is the number of names inside it. On APFS that
/// includes files and symlinks, not only subdirectories. Publish adds and
/// removes those names, so the count is not directory identity. A regular
/// file or symlink whose link count changed has another name, and writing
/// or unlinking it would touch that other name.
func workspaceInodeAcceptableForPublish(
    captured: WorkspaceInodeStamp,
    live: WorkspaceInodeStamp
) -> Bool {
    guard captured.device == live.device,
        captured.inode == live.inode,
        captured.kind == live.kind
    else {
        return false
    }
    switch captured.kind {
    case .directory:
        return true
    case .regular, .symlink:
        return captured.linkCount == live.linkCount
    }
}

/// Publishing rule for one relative path.
///
/// `workspaceInodeAcceptableForPublish` is the authority check. A hard link
/// planted on the hidden original tree fails it and must not be written or
/// unlinked.
func workspacePublishDecision(
    snapshot: WorkspaceInodeStamp?,
    saved: WorkspaceInodeStamp?,
    onVolume: Bool
) -> WorkspacePublishDecision {
    if onVolume {
        switch (snapshot, saved) {
        case (let captured?, let live?)
            where workspaceInodeAcceptableForPublish(captured: captured, live: live):
            return .update
        case (nil, nil):
            return .create
        default:
            return .reject
        }
    }
    switch (snapshot, saved) {
    case (let captured?, let live?)
        where workspaceInodeAcceptableForPublish(captured: captured, live: live):
        return .remove
    case (nil, .some), (nil, nil):
        return .leave
    default:
        return .reject
    }
}

/// Mutable boundary state. The supervisor calls into the boundary from
/// multiple client-connection threads, so every field lives behind one
/// lock. Methods snapshot what they need under short locks and never call
/// back into a locking method while holding the lock.
///
/// The lock serializes number assignment, not fd lifetime: a number read
/// under the lock can be closed (and its value reused) by teardown before
/// the reader's `fstat`/`dup`/`openat` runs. Readers must therefore be
/// externally serialized against close/detach. Today that holds: launch
/// reads under the supervisor state lock that close also takes, and
/// `heldDescriptors`/`savedFileData` have no production callers outside
/// that discipline. A future concurrent reader must pin lifetime (dup
/// under the lock) instead of trusting a bare number.
private struct BoundaryMutable: Sendable {
    var volumeFD: Int32
    var savedFD: Int32
    var released = false
    var didDetach = false
    /// Set when a saved file was truncated and the backup restore did not
    /// finish. `restoreOriginalDirectory` must not rename that tree onto
    /// the workspace.
    var blockWorkspaceRename = false
}

/// Mounts the workspace path on a fresh volume before a contained process runs.
///
/// Seatbelt allows a write whose path is inside the workspace even when that
/// name is a hard link to an inode outside it. Hard links cannot cross devices.
/// A same-user `link` into this mount fails with `EXDEV`, including links
/// created after the preflight scan. Results are copied back only through a
/// file descriptor whose device, inode, and kind still match the pre-launch
/// snapshot. Regular files and symlinks must also keep their link count.
/// Directory link count changes as children are published.
///
/// A same-user `diskutil unmount force` can tear this mount down. Polite
/// unmount is blocked by a directory descriptor held until the process group
/// is dead. Force-unmount is not claimed as closed.
final class WorkspaceInodeBoundary: Sendable {
    let workspacePath: String
    private let savedPath: String
    private let quarantinePath: String
    private let imagePath: String?
    private let disk: String
    private let volumeDevice: UInt64
    private let savedDevice: UInt64
    private let savedInode: UInt64
    private let mountSource: String
    private let imageDevice: UInt64?
    private let imageInode: UInt64?
    private let mutable: Mutex<BoundaryMutable>
    private let snapshot: [String: WorkspaceInodeStamp]

    init(
        workspacePath: String,
        savedPath: String,
        quarantinePath: String,
        imagePath: String?,
        disk: String,
        volumeDevice: UInt64,
        savedDevice: UInt64,
        savedInode: UInt64,
        mountSource: String,
        imageDevice: UInt64?,
        imageInode: UInt64?,
        volumeFD: Int32,
        savedFD: Int32,
        snapshot: [String: WorkspaceInodeStamp]
    ) {
        self.workspacePath = workspacePath
        self.savedPath = savedPath
        self.quarantinePath = quarantinePath
        self.imagePath = imagePath
        self.disk = disk
        self.volumeDevice = volumeDevice
        self.savedDevice = savedDevice
        self.savedInode = savedInode
        self.mountSource = mountSource
        self.imageDevice = imageDevice
        self.imageInode = imageInode
        self.mutable = Mutex(BoundaryMutable(volumeFD: volumeFD, savedFD: savedFD))
        self.snapshot = snapshot
    }

    deinit {
        let fds = mutable.withLock { ($0.volumeFD, $0.savedFD) }
        if fds.0 >= 0 { close(fds.0) }
        if fds.1 >= 0 { close(fds.1) }
    }

    func remainsEstablished() -> Bool {
        let fd = mutable.withLock { $0.volumeFD }
        guard fd >= 0 else { return false }
        var status = stat()
        guard fstat(fd, &status) == 0 else { return false }
        return device(of: status) == volumeDevice
    }

    var volumeDeviceIdentifier: UInt64 { volumeDevice }
    var diskIdentifier: String { disk }
    var isReleased: Bool { mutable.withLock { $0.released } }

    /// Directory descriptors RV holds for the mount and the hidden original.
    /// Callers compare these identities with a child's open files.
    func heldDescriptors() -> [Int32] {
        mutable.withLock { [$0.volumeFD, $0.savedFD] }.filter { $0 >= 0 }
    }

    /// Move the mount and saved directory descriptors above the granted
    /// stdio and admission slots so a later `dup2` onto 0...5 cannot publish
    /// them into a runtime.
    func relocateHeldDescriptors(atLeast floor: Int32) -> Bool {
        mutable.withLock { state in
            relocateDescriptor(&state.volumeFD, above: floor)
                && relocateDescriptor(&state.savedFD, above: floor)
        }
    }

    /// Bytes of one file in the hidden original tree. Nil when that name is
    /// not there. This does not read the mounted volume.
    func savedFileData(_ relative: String) -> Data? {
        guard mutable.withLock({ $0.released }) == false,
            let fd = openSaved(relative, directory: false), fd >= 0
        else {
            return nil
        }
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base, raw.count)
            }
            if count > 0 {
                data.append(buffer, count: count)
                continue
            }
            if count == 0 { return data }
            if errno == EINTR { continue }
            return nil
        }
    }

    /// Remove host-staged agent credential links and the cage dir from the
    /// volume before publish. Only names the snapshot does not own are
    /// removed, so project-owned files at the same paths publish normally.
    /// Only staged symlinks go: a regular file the contained process wrote
    /// at an auth path is project state and publishes through the normal
    /// decision.
    func scrubHostStagedAgentHomes() {
        // Upgrade cleanup only: new launches never stage credentials in a
        // workspace. The link list is the shared staging catalog, so staged
        // and scrubbed paths cannot drift apart.
        let manager = FileManager.default
        for relative in AgentHomeStaging.credentialLinks.map(\.relative) {
            guard snapshot[relative] == nil else { continue }
            let path = "\(workspacePath)/\(relative)"
            guard (try? manager.destinationOfSymbolicLink(atPath: path)) != nil else { continue }
            try? manager.removeItem(atPath: path)
        }
        guard snapshot[AgentHomeStaging.cageDirectoryName] == nil else { return }
        try? manager.removeItem(atPath: "\(workspacePath)/\(AgentHomeStaging.cageDirectoryName)")
    }

    /// Copy volume contents onto the original inodes, then put that directory
    /// back at the workspace path and release the volume.
    func publishAndRestore() -> Result<Void, IsolationApplyError> {
        scrubHostStagedAgentHomes()
        let published: Result<Void, IsolationApplyError>
        if remainsEstablished() {
            published = publishIntoSaved(writing: true)
        } else {
            published = .failure(.workspaceInodeBoundaryFailed)
        }
        let restored = restoreOriginalDirectory()
        switch (published, restored) {
        case (.success, .success):
            return .success(())
        case (.failure(let error), _), (_, .failure(let error)):
            return .failure(error)
        }
    }

    func snapshotStamps() -> [String: WorkspaceInodeStamp] {
        snapshot
    }

    func recoveryIdentity(
        lockPath: String,
        lockDevice: UInt64,
        lockInode: UInt64,
        ownerToken: UUID,
        snapshotPath: String,
        snapshotDevice: UInt64,
        snapshotInode: UInt64
    ) -> WorkspaceDurableIdentity {
        WorkspaceDurableIdentity(
            savedPath: savedPath,
            savedDevice: savedDevice,
            savedInode: savedInode,
            quarantinePath: quarantinePath,
            volumeDevice: volumeDevice,
            disk: disk,
            mountSource: mountSource,
            imagePath: imagePath,
            imageDevice: imageDevice,
            imageInode: imageInode,
            lockPath: lockPath,
            lockDevice: lockDevice,
            lockInode: lockInode,
            ownerToken: ownerToken,
            snapshotPath: snapshotPath,
            snapshotDevice: snapshotDevice,
            snapshotInode: snapshotInode
        )
    }

    /// The publish rules reject the saved tree. The mount is left in place.
    func preflightPublish() -> Result<Void, IsolationApplyError> {
        publishIntoSaved(writing: false)
    }

    /// Copy the volume onto the hidden original. Does not unmount.
    func publishPreservingMount() -> Result<Void, IsolationApplyError> {
        scrubHostStagedAgentHomes()
        return publishIntoSaved(writing: true)
    }

    /// Detach this volume only when the mount source and device still match.
    func detachOwnedMount() -> Result<Void, IsolationApplyError> {
        if mutable.withLock({ $0.released || $0.didDetach }) { return .success(()) }
        guard mountedIdentityMatches() else { return .failure(.workspaceInodeBoundaryFailed) }
        let volume = mutable.withLock { state -> Int32 in
            defer { state.volumeFD = -1 }
            return state.volumeFD
        }
        if volume >= 0 {
            close(volume)
        }
        detachVolume()
        if currentDevice(workspacePath) == volumeDevice {
            return .failure(.workspaceInodeBoundaryFailed)
        }
        mutable.withLock { $0.didDetach = true }
        return .success(())
    }

    private func mountedIdentityMatches() -> Bool {
        guard let device = currentDevice(workspacePath), device == volumeDevice else { return false }
        guard let facts = workspaceMountFacts(workspacePath), facts.source == mountSource else {
            return false
        }
        return true
    }

    /// Drop the volume without copying. The original directory returns unchanged.
    func discardAndRestore() -> Result<Void, IsolationApplyError> {
        restoreOriginalDirectory()
    }

    private func publishIntoSaved(writing: Bool) -> Result<Void, IsolationApplyError> {
        guard remainsEstablished() else {
            return .failure(.workspaceInodeBoundaryFailed)
        }
        // A cancelled publish stops before it spends the detach slice.
        // The caller still unmounts. A clock stop is not a committed tree.
        if cancelClockAllowsTreeCopy() == false {
            return .failure(.workspaceInodeBoundaryFailed)
        }
        let fds = mutable.withLock { ($0.volumeFD, $0.savedFD) }
        guard fds.1 >= 0 else {
            return .failure(.workspaceInodeBoundaryFailed)
        }
        guard let volumeEntries = collectTree(root: fds.0, checkDevice: volumeDevice) else {
            return .failure(.workspaceInodeBoundaryFailed)
        }
        var rejected = false
        let present = volumeEntries.keys.sorted { pathDepth($0) < pathDepth($1) }
        for relative in present {
            if cancelClockAllowsTreeCopy() == false {
                return .failure(.workspaceInodeBoundaryFailed)
            }
            guard let entry = volumeEntries[relative] else { continue }
            let decision = workspacePublishDecision(
                snapshot: snapshot[relative],
                saved: savedStamp(relative),
                onVolume: true
            )
            switch decision {
            case .update:
                if writing, updateSaved(relative, from: entry) == false {
                    rejected = true
                }
            case .create:
                if writing, createSaved(relative, from: entry) == false {
                    rejected = true
                }
            case .remove, .leave, .reject:
                rejected = true
            }
        }
        let missing = snapshot.keys.filter { volumeEntries[$0] == nil }
            .sorted { pathDepth($0) > pathDepth($1) }
        for relative in missing {
            if cancelClockAllowsTreeCopy() == false {
                return .failure(.workspaceInodeBoundaryFailed)
            }
            let decision = workspacePublishDecision(
                snapshot: snapshot[relative],
                saved: savedStamp(relative),
                onVolume: false
            )
            switch decision {
            case .remove:
                if writing, removeSaved(relative) == false {
                    rejected = true
                }
            case .leave:
                break
            case .update, .create, .reject:
                rejected = true
            }
        }
        if rejected {
            return .failure(.workspaceInodeBoundaryFailed)
        }
        return .success(())
    }

    private func restoreOriginalDirectory() -> Result<Void, IsolationApplyError> {
        if mutable.withLock({ $0.blockWorkspaceRename }) {
            return .failure(.workspaceInodeBoundaryFailed)
        }
        if mutable.withLock({ $0.released }) { return .success(()) }
        let volume = mutable.withLock { state -> Int32 in
            defer { state.volumeFD = -1 }
            return state.volumeFD
        }
        if volume >= 0 {
            close(volume)
        }
        let detached = detachVolume()
        let workspaceDevice = currentDevice(workspacePath)
        if workspaceDevice == volumeDevice {
            // The mount is still here. Do not delete it by path: that would
            // operate on the volume, and a forced replacement could be a
            // different tree. Leave both directories and fail closed.
            return .failure(.workspaceInodeBoundaryFailed)
        }
        if FileManager.default.fileExists(atPath: workspacePath) {
            if FileManager.default.fileExists(atPath: quarantinePath) {
                return .failure(.workspaceInodeBoundaryFailed)
            }
            guard renamePath(workspacePath, quarantinePath) else {
                return .failure(.workspaceInodeBoundaryFailed)
            }
        }
        guard renamePath(savedPath, workspacePath) else {
            return .failure(.workspaceInodeBoundaryFailed)
        }
        let saved = mutable.withLock { state -> Int32 in
            defer { state.savedFD = -1 }
            return state.savedFD
        }
        if saved >= 0 {
            close(saved)
        }
        mutable.withLock { $0.released = true }
        _ = inodeCheckedDelete(quarantinePath)
        // The device check above is the mount, not the detach. A force
        // umount can succeed while `hdiutil detach` fails or is skipped.
        // The image path is what a later detach still needs.
        if let imagePath, diskImageMayRemoveImage(detachSucceeded: detached) {
            unlink(imagePath)
        }
        return .success(())
    }

    @discardableResult
    private func detachVolume() -> Bool {
        // The session reap and the death poll already consumed this clock
        // when cancel armed it. Adopting it here does not start 7.75s over.
        let clock = CooperativeLaunchStop.adoptCancelClock(DiskImageCancelClock())
        if blockingWorkIsCancelled() || clock.deadline != nil {
            return detachCancelledVolume(clock: clock)
        }
        // Unmount directly first: arbitration-mediated unmounts wedge when
        // the daemon is unresponsive, and then every detach below fails
        // "Resource busy" while the mount leaks.
        unmountDirect(workspacePath, onlySource: disk, clock: clock)
        if clock.deadline != nil || blockingWorkIsCancelled() {
            return finishCancelledDetach(clock: clock)
        }
        for _ in 0..<8 {
            if blockingWorkIsCancelled() {
                return finishCancelledDetach(clock: clock)
            }
            let result = runTool(
                ["/usr/bin/hdiutil", "detach", "-force", "-quiet", disk],
                honorCancellation: false,
                deadline: 8,
                clock: clock
            )
            // A deadline means diskimagesd is wedged. Further detaches wait
            // out the same wedge and hold the isolation shard until the job
            // cap. A fast nonzero exit is the transient failure the retry is
            // for. Cancellation shares `clock` with the umounts; another
            // full sequence would spend the return bound twice. An in-flight
            // cancel arms that same clock inside the helper, so this return
            // does not start a second 7.75s.
            if clock.deadline != nil || blockingWorkIsCancelled() {
                return DiskImageCancelBudget.preemptCleanupSucceeded(
                    status: result.status,
                    timedOut: result.timedOut
                )
            }
            if result.status == 0 {
                return true
            }
            if result.timedOut {
                return false
            }
            usleep(40_000)
        }
        return false
    }

    /// Cancelled teardown. One clock covers both umounts, the detach, and
    /// every mutex wait. The 45-second default is not used. Force unmount
    /// is the 0.5s slice `cancelledSequenceBudget` already counts, so a
    /// protected holder cannot run out the other teardown's clock.
    /// Returns whether `hdiutil detach` exited 0. A skipped detach is not
    /// success: the caller must not unlink the image.
    private func detachCancelledVolume(clock: DiskImageCancelClock) -> Bool {
        if clock.deadline == nil {
            clock.arm(spentSinceCancel: CooperativeLaunchStop.spentSinceCancel())
        }
        let plainCap = DiskImageCancelBudget.cancelledDetachHelpers().plainUnmount
        unmountDirect(
            workspacePath,
            onlySource: disk,
            plainDeadline: min(plainCap, clock.remaining),
            forceDeadline: DiskImageCancelBudget.cancelledForceSlice(remaining: clock.remaining),
            clock: clock
        )
        return finishCancelledDetach(clock: clock)
    }

    private func finishCancelledDetach(clock: DiskImageCancelClock) -> Bool {
        if clock.deadline == nil {
            clock.arm(spentSinceCancel: CooperativeLaunchStop.spentSinceCancel())
        }
        let detachLeft = min(DiskImageCancelBudget.detachCap, clock.remaining)
        guard detachLeft > 0 else { return false }
        let result = runTool(
            ["/usr/bin/hdiutil", "detach", "-force", "-quiet", disk],
            honorCancellation: false,
            deadline: detachLeft,
            clock: clock
        )
        return DiskImageCancelBudget.preemptCleanupSucceeded(
            status: result.status,
            timedOut: result.timedOut
        )
    }

    private func updateSaved(_ relative: String, from entry: TreeEntry) -> Bool {
        guard let captured = snapshot[relative] else { return false }
        switch entry.kind {
        case .directory:
            guard let fd = openSaved(relative, directory: true), fd >= 0 else { return false }
            defer { close(fd) }
            var status = stat()
            guard fstat(fd, &status) == 0, acceptableSavedInode(captured, status) else { return false }
            return fchmod(fd, entry.mode) == 0
        case .regular:
            guard let source = openVolume(relative, directory: false), source >= 0 else { return false }
            defer { close(source) }
            guard let dest = openSaved(relative, directory: false, writable: true), dest >= 0 else {
                return updateReadOnlySaved(relative, from: source, captured: captured, mode: entry.mode)
            }
            defer { close(dest) }
            var status = stat()
            guard fstat(dest, &status) == 0, acceptableSavedInode(captured, status) else { return false }
            let outcome = replaceOriginalOnlyAfterStagedCopy(
                source: source,
                original: dest,
                originalPath: (savedPath as NSString).appendingPathComponent(relative),
                mayContinue: publishCopyMayContinue,
                copyXattr: copyExtendedAttributes
            )
            if outcome.reachedTruncate && outcome.mayRenameOntoWorkspace == false {
                mutable.withLock { $0.blockWorkspaceRename = true }
            }
            guard outcome.committed else { return false }
            return fchmod(dest, entry.mode) == 0
        case .symlink:
            guard let target = readVolumeLink(relative) else { return false }
            guard let parent = savedParent(relative) else { return false }
            defer { close(parent.fd) }
            var status = stat()
            let matched = parent.name.withCString { name in
                fstatat(parent.fd, name, &status, AT_SYMLINK_NOFOLLOW) == 0
            }
            guard matched, acceptableSavedInode(captured, status) else { return false }
            let removed = parent.name.withCString { name in
                unlinkat(parent.fd, name, 0) == 0
            }
            guard removed else { return false }
            return parent.name.withCString { name in
                target.withCString { link in
                    symlinkat(link, parent.fd, name) == 0
                }
            }
        }
    }

    /// Copy back onto a saved file that refuses `O_RDWR`, such as the mode-444
    /// files dependency managers ship. Untouched content needs no write at
    /// all; edited content takes a momentary owner-write bit that the final
    /// chmod restores, so the mode survives the round trip. The inode is
    /// never replaced, and every open re-verifies the captured identity, so
    /// the authority check keeps its meaning. A failure after the mode bit
    /// is set leaves content intact with owner-write added; the next publish
    /// takes the writable path and restores the volume mode.
    private func updateReadOnlySaved(
        _ relative: String,
        from source: Int32,
        captured: WorkspaceInodeStamp,
        mode: mode_t
    ) -> Bool {
        guard let parent = savedParent(relative) else { return false }
        defer { close(parent.fd) }
        let readOnly = parent.name.withCString { name in
            openat(parent.fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard readOnly >= 0 else { return false }
        defer { close(readOnly) }
        var status = stat()
        guard fstat(readOnly, &status) == 0, acceptableSavedInode(captured, status) else {
            return false
        }
        guard let same = savedContentsEqual(source, readOnly) else { return false }
        if same {
            if modeBits(status.st_mode) == mode { return true }
            return fchmod(readOnly, mode) == 0
        }
        guard fchmod(readOnly, modeBits(status.st_mode) | 0o200) == 0 else { return false }
        let dest = parent.name.withCString { name in
            openat(parent.fd, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        }
        guard dest >= 0 else { return false }
        defer { close(dest) }
        var fresh = stat()
        guard fstat(dest, &fresh) == 0, acceptableSavedInode(captured, fresh) else { return false }
        guard lseek(source, 0, SEEK_SET) == 0 else { return false }
        let outcome = replaceOriginalOnlyAfterStagedCopy(
            source: source,
            original: dest,
            originalPath: (savedPath as NSString).appendingPathComponent(relative),
            mayContinue: publishCopyMayContinue,
            copyXattr: copyExtendedAttributes
        )
        if outcome.reachedTruncate && outcome.mayRenameOntoWorkspace == false {
            mutable.withLock { $0.blockWorkspaceRename = true }
        }
        guard outcome.committed else { return false }
        return fchmod(dest, mode) == 0
    }

    /// Byte-compare two descriptors from their starts. Nil when either side
    /// is unreadable. Leaves both offsets at end-of-file.
    private func savedContentsEqual(_ left: Int32, _ right: Int32) -> Bool? {
        guard lseek(left, 0, SEEK_SET) == 0, lseek(right, 0, SEEK_SET) == 0 else { return nil }
        var leftBuffer = [UInt8](repeating: 0, count: 64 * 1024)
        var rightBuffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if directoryReadMayContinue(cancelClockAllowsTreeCopy()) == false { return nil }
            let leftCount = readDescriptor(left, into: &leftBuffer)
            let rightCount = readDescriptor(right, into: &rightBuffer)
            guard leftCount >= 0, rightCount >= 0 else { return nil }
            guard leftCount == rightCount else { return false }
            if leftCount == 0 { return true }
            guard leftBuffer.prefix(leftCount).elementsEqual(rightBuffer.prefix(rightCount)) else {
                return false
            }
        }
    }

    private func readDescriptor(_ fd: Int32, into buffer: inout [UInt8]) -> Int {
        buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            while true {
                let count = read(fd, base, raw.count)
                if count < 0, errno == EINTR { continue }
                return count
            }
        }
    }

    private func createSaved(_ relative: String, from entry: TreeEntry) -> Bool {
        guard let parent = savedParent(relative) else { return false }
        defer { close(parent.fd) }
        switch entry.kind {
        case .directory:
            let created = parent.name.withCString { name in
                mkdirat(parent.fd, name, entry.mode) == 0
            }
            return created
        case .regular:
            let dest = parent.name.withCString { name in
                openat(
                    parent.fd,
                    name,
                    O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_WRONLY,
                    entry.mode
                )
            }
            guard dest >= 0 else { return false }
            defer { close(dest) }
            guard let source = openVolume(relative, directory: false), source >= 0 else {
                unlinkNewSaved(parent.fd, parent.name)
                return false
            }
            defer { close(source) }
            guard copyFileDataObservingCancelClock(from: source, to: dest) else {
                unlinkNewSaved(parent.fd, parent.name)
                return false
            }
            return true
        case .symlink:
            guard let target = readVolumeLink(relative) else { return false }
            return parent.name.withCString { name in
                target.withCString { link in
                    symlinkat(link, parent.fd, name) == 0
                }
            }
        }
    }

    private func removeSaved(_ relative: String) -> Bool {
        guard let captured = snapshot[relative], let parent = savedParent(relative) else {
            return false
        }
        defer { close(parent.fd) }
        var status = stat()
        let matched = parent.name.withCString { name in
            fstatat(parent.fd, name, &status, AT_SYMLINK_NOFOLLOW) == 0
        }
        guard matched, acceptableSavedInode(captured, status) else { return false }
        let flags = captured.kind == .directory ? AT_REMOVEDIR : 0
        return parent.name.withCString { name in
            unlinkat(parent.fd, name, flags) == 0
        }
    }

    private func savedStamp(_ relative: String) -> WorkspaceInodeStamp? {
        guard let parent = savedParent(relative) else { return nil }
        defer { close(parent.fd) }
        var status = stat()
        let ok = parent.name.withCString { name in
            fstatat(parent.fd, name, &status, AT_SYMLINK_NOFOLLOW) == 0
        }
        guard ok else { return nil }
        return stamp(of: status)
    }

    /// Walk from the held saved directory. Refuse a symlink or an inode that
    /// is not the captured directory. `~Copyable` is unnecessary: this fd is
    /// closed by the caller, and the held root fd stays open.
    private func savedParent(_ relative: String) -> (fd: Int32, name: String)? {
        let parts = relative.split(separator: "/").map(String.init)
        guard let name = parts.last else { return nil }
        var current = dup(mutable.withLock { $0.savedFD })
        guard current >= 0 else { return nil }
        var walked = ""
        for part in parts.dropLast() {
            walked = walked.isEmpty ? part : walked + "/" + part
            let next = part.withCString { name in
                openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            close(current)
            guard next >= 0 else { return nil }
            var status = stat()
            guard fstat(next, &status) == 0 else {
                close(next)
                return nil
            }
            if let captured = snapshot[walked] {
                guard acceptableSavedInode(captured, status) else {
                    close(next)
                    return nil
                }
            }
            current = next
        }
        return (current, name)
    }

    private func openSaved(_ relative: String, directory: Bool, writable: Bool = false) -> Int32? {
        guard let parent = savedParent(relative) else { return nil }
        defer { close(parent.fd) }
        let flags = O_NOFOLLOW | O_CLOEXEC | (directory
            ? O_RDONLY | O_DIRECTORY
            : (writable ? O_RDWR : O_RDONLY))
        let fd = parent.name.withCString { name in
            openat(parent.fd, name, flags)
        }
        return fd >= 0 ? fd : nil
    }

    private func openVolume(_ relative: String, directory: Bool) -> Int32? {
        guard let parent = volumeParent(relative) else { return nil }
        defer { close(parent.fd) }
        let flags = O_NOFOLLOW | O_CLOEXEC | (directory ? (O_RDONLY | O_DIRECTORY) : O_RDONLY)
        let fd = parent.name.withCString { name in
            openat(parent.fd, name, flags)
        }
        return fd >= 0 ? fd : nil
    }

    private func volumeParent(_ relative: String) -> (fd: Int32, name: String)? {
        let parts = relative.split(separator: "/").map(String.init)
        guard let name = parts.last else { return nil }
        var current = dup(mutable.withLock { $0.volumeFD })
        guard current >= 0 else { return nil }
        for part in parts.dropLast() {
            let next = part.withCString { name in
                openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            close(current)
            guard next >= 0 else { return nil }
            current = next
        }
        return (current, name)
    }

    private func readVolumeLink(_ relative: String) -> String? {
        guard let parent = volumeParent(relative) else { return nil }
        defer { close(parent.fd) }
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = parent.name.withCString { name in
            readlinkat(parent.fd, name, &buffer, buffer.count - 1)
        }
        guard count >= 0, count < buffer.count - 1 else { return nil }
        return String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func reattach(
        project: String,
        identity: WorkspaceDurableIdentity,
        snapshot: [String: WorkspaceInodeStamp]
    ) -> Result<WorkspaceInodeBoundary, IsolationApplyError> {
        guard RVIsolationMount.observe(
            project: project,
            savedPath: identity.savedPath,
            savedDevice: identity.savedDevice,
            savedInode: identity.savedInode,
            volumeDevice: identity.volumeDevice,
            mountSource: identity.mountSource
        ) == .ownedMount else {
            return .failure(.workspaceInodeBoundaryFailed)
        }
        let savedFD = identity.savedPath.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        let volumeFD = project.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard savedFD >= 0, volumeFD >= 0 else {
            if savedFD >= 0 { close(savedFD) }
            if volumeFD >= 0 { close(volumeFD) }
            return .failure(.workspaceInodeBoundaryFailed)
        }
        var savedStatus = stat()
        var volumeStatus = stat()
        guard fstat(savedFD, &savedStatus) == 0,
            fstat(volumeFD, &volumeStatus) == 0,
            device(of: savedStatus) == identity.savedDevice,
            UInt64(savedStatus.st_ino) == identity.savedInode,
            device(of: volumeStatus) == identity.volumeDevice
        else {
            close(savedFD)
            close(volumeFD)
            return .failure(.workspaceInodeBoundaryFailed)
        }
        return .success(
            WorkspaceInodeBoundary(
                workspacePath: project,
                savedPath: identity.savedPath,
                quarantinePath: identity.quarantinePath,
                imagePath: identity.imagePath,
                disk: identity.disk,
                volumeDevice: identity.volumeDevice,
                savedDevice: identity.savedDevice,
                savedInode: identity.savedInode,
                mountSource: identity.mountSource,
                imageDevice: identity.imageDevice,
                imageInode: identity.imageInode,
                volumeFD: volumeFD,
                savedFD: savedFD,
                snapshot: snapshot
            )
        )
    }

    /// Put the hidden original back when this workspace's volume is already gone.
    static func restoreHiddenOriginal(
        project: String,
        identity: WorkspaceDurableIdentity
    ) -> Result<Void, IsolationApplyError> {
        let observation = RVIsolationMount.observe(
            project: project,
            savedPath: identity.savedPath,
            savedDevice: identity.savedDevice,
            savedInode: identity.savedInode,
            volumeDevice: identity.volumeDevice,
            mountSource: identity.mountSource
        )
        switch observation {
        case .originalRestored:
            return removeOwnedImage(identity)
        case .missingMount:
            break
        case .ownedMount, .unrelatedMount, .savedTreeMismatch, .ambiguous:
            return .failure(.workspaceInodeBoundaryFailed)
        }
        if FileManager.default.fileExists(atPath: project) {
            if FileManager.default.fileExists(atPath: identity.quarantinePath) {
                return .failure(.workspaceInodeBoundaryFailed)
            }
            guard renamePath(project, identity.quarantinePath) else {
                return .failure(.workspaceInodeBoundaryFailed)
            }
        }
        guard renamePath(identity.savedPath, project) else {
            return .failure(.workspaceInodeBoundaryFailed)
        }
        guard let restored = workspacePathIdentity(project),
            restored.device == identity.savedDevice,
            restored.inode == identity.savedInode,
            restored.isDirectory
        else {
            return .failure(.workspaceInodeBoundaryFailed)
        }
        _ = inodeCheckedDelete(identity.quarantinePath)
        return removeOwnedImage(identity)
    }

    private static func removeOwnedImage(
        _ identity: WorkspaceDurableIdentity
    ) -> Result<Void, IsolationApplyError> {
        guard let imagePath = identity.imagePath,
            let imageDevice = identity.imageDevice,
            let imageInode = identity.imageInode
        else {
            return .success(())
        }
        var status = stat()
        let exists = imagePath.withCString { lstat($0, &status) == 0 }
        if exists == false { return .success(()) }
        guard device(of: status) == imageDevice,
            UInt64(status.st_ino) == imageInode,
            (status.st_mode & S_IFMT) == S_IFREG
        else {
            return .success(())
        }
        guard imagePath.withCString({ unlink($0) == 0 }) else {
            return .failure(.workspaceInodeBoundaryFailed)
        }
        return .success(())
    }
}

func establishWorkspaceInodeBoundary(
    at workspacePath: String
) -> Result<WorkspaceInodeBoundary, IsolationApplyError> {
    if blockingWorkIsCancelled() {
        return .failure(.cancelled)
    }
    let rootFD = workspacePath.withCString { path in
        open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard rootFD >= 0 else { return .failure(.workspaceInodeBoundaryFailed) }
    var rootStatus = stat()
    guard fstat(rootFD, &rootStatus) == 0 else {
        close(rootFD)
        return .failure(.workspaceInodeBoundaryFailed)
    }
    let originalDevice = device(of: rootStatus)
    guard let captured = collectTree(root: rootFD, checkDevice: originalDevice) else {
        close(rootFD)
        return .failure(.workspaceInodeBoundaryFailed)
    }
    for entry in captured.values where entry.kind == .regular && entry.stamp.linkCount > 1 {
        close(rootFD)
        return .failure(.workspaceContainsInodeAlias)
    }
    close(rootFD)

    let parent = (workspacePath as NSString).deletingLastPathComponent
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
    let savedPath = (parent as NSString).appendingPathComponent(".rv-saved-\(token)")
    let quarantinePath = (parent as NSString).appendingPathComponent(".rv-quarantine-\(token)")
    let byteCount = captured.values.reduce(UInt64(0)) { $0 + $1.bytes }
    guard renamePath(workspacePath, savedPath) else {
        return .failure(.workspaceInodeBoundaryFailed)
    }
    guard mkdir(workspacePath, 0o700) == 0 else {
        _ = renamePath(savedPath, workspacePath)
        return .failure(.workspaceInodeBoundaryFailed)
    }
    let mounted: MountedDisk
    switch createMountedDisk(byteCount: byteCount, mountPoint: workspacePath, token: String(token)) {
    case .failure(let error):
        rmdir(workspacePath)
        _ = renamePath(savedPath, workspacePath)
        return .failure(error)
    case .success(let disk):
        mounted = disk
    }
    _ = workspacePath.withCString { chmod($0, 0o700) }
    guard let volumeDevice = currentDevice(workspacePath), volumeDevice != originalDevice else {
        let detached = detachWorkspaceDisk(mounted.disk, mountPoint: workspacePath)
        rmdir(workspacePath)
        _ = renamePath(savedPath, workspacePath)
        unlinkImageIfDetached(mounted.imagePath, detachSucceeded: detached)
        return .failure(.workspaceInodeBoundaryFailed)
    }
    let savedFD = savedPath.withCString { path in
        open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    let volumeFD = workspacePath.withCString { path in
        open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard savedFD >= 0, volumeFD >= 0 else {
        if savedFD >= 0 { close(savedFD) }
        if volumeFD >= 0 { close(volumeFD) }
        let detached = detachWorkspaceDisk(mounted.disk, mountPoint: workspacePath)
        rmdir(workspacePath)
        _ = renamePath(savedPath, workspacePath)
        unlinkImageIfDetached(mounted.imagePath, detachSucceeded: detached)
        return .failure(.workspaceInodeBoundaryFailed)
    }
    var savedStatus = stat()
    guard fstat(savedFD, &savedStatus) == 0, device(of: savedStatus) == originalDevice else {
        close(savedFD)
        close(volumeFD)
        let detached = detachWorkspaceDisk(mounted.disk, mountPoint: workspacePath)
        rmdir(workspacePath)
        _ = renamePath(savedPath, workspacePath)
        unlinkImageIfDetached(mounted.imagePath, detachSucceeded: detached)
        return .failure(.workspaceInodeBoundaryFailed)
    }
    if copyTree(from: savedFD, to: volumeFD, expectDevice: originalDevice) == false {
        close(savedFD)
        close(volumeFD)
        let detached = detachWorkspaceDisk(mounted.disk, mountPoint: workspacePath)
        rmdir(workspacePath)
        _ = renamePath(savedPath, workspacePath)
        unlinkImageIfDetached(mounted.imagePath, detachSucceeded: detached)
        return .failure(.workspaceInodeBoundaryFailed)
    }
    var volumeStatus = stat()
    guard fstat(volumeFD, &volumeStatus) == 0, device(of: volumeStatus) == volumeDevice else {
        close(savedFD)
        close(volumeFD)
        let detached = detachWorkspaceDisk(mounted.disk, mountPoint: workspacePath)
        rmdir(workspacePath)
        _ = renamePath(savedPath, workspacePath)
        unlinkImageIfDetached(mounted.imagePath, detachSucceeded: detached)
        return .failure(.workspaceInodeBoundaryFailed)
    }
    guard let mountSource = workspaceMountSource(workspacePath), mountSource.isEmpty == false else {
        close(savedFD)
        close(volumeFD)
        let detached = detachWorkspaceDisk(mounted.disk, mountPoint: workspacePath)
        rmdir(workspacePath)
        _ = renamePath(savedPath, workspacePath)
        unlinkImageIfDetached(mounted.imagePath, detachSucceeded: detached)
        return .failure(.workspaceInodeBoundaryFailed)
    }
    let imageIdentity = mounted.imagePath.flatMap(workspacePathIdentity)
    if mounted.imagePath != nil, imageIdentity?.isDirectory != false {
        close(savedFD)
        close(volumeFD)
        let detached = detachWorkspaceDisk(mounted.disk, mountPoint: workspacePath)
        rmdir(workspacePath)
        _ = renamePath(savedPath, workspacePath)
        unlinkImageIfDetached(mounted.imagePath, detachSucceeded: detached)
        return .failure(.workspaceInodeBoundaryFailed)
    }
    let boundary = WorkspaceInodeBoundary(
        workspacePath: workspacePath,
        savedPath: savedPath,
        quarantinePath: quarantinePath,
        imagePath: mounted.imagePath,
        disk: mounted.disk,
        volumeDevice: volumeDevice,
        savedDevice: originalDevice,
        savedInode: UInt64(savedStatus.st_ino),
        mountSource: mountSource,
        imageDevice: imageIdentity?.device,
        imageInode: imageIdentity?.inode,
        volumeFD: volumeFD,
        savedFD: savedFD,
        snapshot: captured.mapValues(\.stamp)
    )
    guard boundary.relocateHeldDescriptors(atLeast: 16) else {
        _ = boundary.discardAndRestore()
        return .failure(.workspaceInodeBoundaryFailed)
    }
    return .success(boundary)
}

private struct MountedDisk {
    var disk: String
    var imagePath: String?
}

struct TreeEntry {
    var stamp: WorkspaceInodeStamp
    var mode: mode_t
    var bytes: UInt64
    var kind: WorkspaceInodeStamp.Kind { stamp.kind }
}

private func createMountedDisk(
    byteCount: UInt64,
    mountPoint: String,
    token: String
) -> Result<MountedDisk, IsolationApplyError> {
    let first = createMountedDiskBody(byteCount: byteCount, mountPoint: mountPoint, token: token)
    guard case .failure(.workspaceInodeBoundaryFailed) = first.result else { return first.result }
    // A timed-out helper was killed because diskimagesd stopped answering.
    // Retrying it stacks another full deadline onto the shard. A helper
    // that exited nonzero is the transient failure the retry is for.
    if blockingWorkIsCancelled() || diskImageMayRetryCreate(
        publishedDisk: first.publishedDisk,
        detachSucceeded: first.detachSucceeded,
        timedOut: first.timedOut
    ) == false {
        return first.result
    }
    usleep(100_000)
    let image = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-inode-\(token).sparseimage").path
    // Process exit plus a detach that exited 0 is not enough. Unlink only
    // when that attempt already proved the disk cannot appear.
    if diskImageMayRemoveImage(detachSucceeded: first.detachSucceeded) {
        unlink(image)
    }
    return createMountedDiskBody(byteCount: byteCount, mountPoint: mountPoint, token: token).result
}

private func createMountedDiskBody(
    byteCount: UInt64,
    mountPoint: String,
    token: String
) -> MountedDiskAttempt {
    // Productive builds need headroom the project itself does not predict:
    // `.build`, `node_modules`, and `target` routinely exceed the source
    // tree by orders of magnitude. A sparse image makes the ceiling cheap
    // (blocks allocate on write), so size for real builds, not for the
    // source size. Disk-backed always: a build-sized ram disk would pin
    // gigabytes of RAM per workspace.
    let gib: UInt64 = 1024 * 1024 * 1024
    let overhead = byteCount &* 2 &+ gib
    let minimum: UInt64 = gib
    let bytes = max(overhead, minimum)
    let image = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-inode-\(token).sparseimage").path
    let megabytes = max(Int(bytes / (1024 * 1024)) + 1, 32)
    var timedOut = false
    var publishedDisk = false
    var detachSucceeded = true
    let clock = DiskImageCancelClock()
    func finish(_ result: Result<MountedDisk, IsolationApplyError>) -> MountedDiskAttempt {
        MountedDiskAttempt(
            result: result,
            timedOut: timedOut,
            publishedDisk: publishedDisk,
            detachSucceeded: detachSucceeded
        )
    }
    let created = runTool(
        [
            "/usr/bin/hdiutil", "create", "-size", "\(megabytes)m",
            "-fs", "Case-sensitive HFS+",
            "-volname", "rv\(token.prefix(8))", "-type", "SPARSE", "-quiet", image,
        ],
        honorCancellation: true,
        clock: clock
    )
    timedOut = created.timedOut
    guard created.status == 0 else {
        // A timed-out create may still be in diskimagesd. Unlink only
        // when that helper has already exited.
        if created.timedOut == false {
            unlink(image)
        }
        return finish(.failure(.workspaceInodeBoundaryFailed))
    }
    // `-nomount` plus a direct mount_hfs of the HFS slice: attaching
    // with a mountpoint asks DiskArbitration to mount, which wedges when
    // the daemon is unresponsive. Owners stay honored, matching the old
    // `-owners on` attach.
    let attached = runTool(
        ["/usr/bin/hdiutil", "attach", "-nomount", "-plist", image],
        honorCancellation: true,
        clock: clock
    )
    timedOut = timedOut || attached.timedOut
    guard attached.status == 0 else {
        // A preempted or failed attach can publish a disk before it exits.
        // The in-lock path already detached when the helper was preempted
        // or still alive. A later detach that exits 0 must not unlink
        // while that parked attach can still publish.
        publishedDisk = true
        let leaked = PreemptedDiskHelperCleanup.plan(arguments: [
            "/usr/bin/hdiutil", "attach", "-nomount", "-plist", image,
        ])
        // A parked attach can still publish. Do not detach it. A reaped
        // timeout already detached inside runTool and still may detach here.
        if attached.helperStillAlive {
            detachSucceeded = false
            timedOut = true
            return finish(.failure(.workspaceInodeBoundaryFailed))
        }
        let detachThis = diskImageMustDetachBeforeUnlock(
            cleanup: leaked,
            helperStillAlive: attached.helperStillAlive,
            preempted: false,
            timedOut: attached.timedOut,
            status: attached.status
        )
        if let follow = leaked.followUpArguments, detachThis || attached.timedOut == false {
            let detached = runTool(
                follow,
                honorCancellation: false,
                deadline: DiskImageCancelBudget.preemptCleanup,
                clock: clock
            )
            let detachOutput = detached.stderr + "\n" + detached.stdout
            // Exit 0 is not proof the disk is gone. This call does not
            // wait out diskimagesd, so the image stays until a later
            // cleanup that has.
            let canAppear = diskImageCanStillAppear(
                helperStillAlive: detached.helperStillAlive,
                detachStatus: detached.status,
                detachTimedOut: detached.timedOut,
                detachOutput: detachOutput,
                imageListedAfterDetach: nil,
                waitedForPublication: false
            )
            detachSucceeded = diskImageMayUnlinkPublishedImage(
                helperStillAlive: detached.helperStillAlive,
                detachSucceeded: DiskImageCancelBudget.preemptCleanupSucceeded(
                    status: detached.status,
                    timedOut: detached.timedOut
                ),
                diskCanStillAppear: canAppear
            )
            if diskImageMayRemoveImage(detachSucceeded: detachSucceeded) {
                unlink(image)
            } else {
                timedOut = true
            }
        } else {
            detachSucceeded = false
            timedOut = true
        }
        return finish(.failure(.workspaceInodeBoundaryFailed))
    }
    guard let disk = diskDevice(inPlist: attached.stdout) else {
        let target = DiskImageCancelBudget.detachTargetWhenPlistMissesDisk(
            image: image,
            plistStdout: attached.stdout,
            mountPoint: mountPoint
        )
        let detached = runTool(
            ["/usr/bin/hdiutil", "detach", "-force", "-quiet", target],
            honorCancellation: false,
            deadline: DiskImageCancelBudget.detachCap,
            clock: clock
        )
        publishedDisk = true
        // Detach ran. Exit 0 is not permission to unlink or retry while
        // diskimagesd can still publish this image.
        detachSucceeded = false
        timedOut = true
        _ = detached
        return finish(.failure(.workspaceInodeBoundaryFailed))
    }
    publishedDisk = true
    guard let slice = hfsSliceDevice(inPlist: attached.stdout) else {
        _ = detachWorkspaceDisk(disk, mountPoint: nil)
        detachSucceeded = false
        timedOut = true
        return finish(.failure(.workspaceInodeBoundaryFailed))
    }
    if blockingWorkIsCancelled() {
        let detached = detachWorkspaceDisk(disk, mountPoint: nil)
        detachSucceeded = false
        timedOut = true
        // Exit 0 is not the disk being gone, and it is not `.cancelled`.
        if establishCancelReportsCancelled(detachExitedZero: detached) {
            return finish(.failure(.cancelled))
        }
        return finish(.failure(.workspaceInodeBoundaryFailed))
    }
    let mounted = runTool(
        ["/sbin/mount_hfs", "-o", "nobrowse,nodev,nosuid", slice, mountPoint],
        honorCancellation: true,
        clock: clock
    )
    timedOut = timedOut || mounted.timedOut
    guard mounted.status == 0 else {
        _ = detachWorkspaceDisk(disk, mountPoint: mountPoint)
        detachSucceeded = false
        timedOut = true
        return finish(.failure(.workspaceInodeBoundaryFailed))
    }
    return finish(.success(MountedDisk(disk: disk, imagePath: image)))
}

private struct MountedDiskAttempt {
    var result: Result<MountedDisk, IsolationApplyError>
    var timedOut: Bool
    var publishedDisk: Bool
    var detachSucceeded: Bool
}

/// `system-entities` from `hdiutil attach -plist` output as typed values.
/// Plist XML carries only JSON-shaped values here (strings, booleans,
/// arrays, dicts); malformed XML or anything outside that shape fails
/// closed to nil.
private func systemEntities(inPlist stdout: String) -> [JSONValue]? {
    guard let data = stdout.data(using: .utf8),
        let root = try? PropertyListDecoder().decode(JSONValue.self, from: data)
    else { return nil }
    return root["system-entities"]?.asArray
}

private func diskDevice(inPlist stdout: String) -> String? {
    guard let entities = systemEntities(inPlist: stdout) else { return nil }
    let devices = entities.compactMap { $0["dev-entry"]?.string }
    return devices.first { $0.contains("disk") && $0.hasSuffix("s1") == false && $0.contains("s") == false }
        ?? devices.first
}

func collectTree(root: Int32, checkDevice: UInt64) -> [String: TreeEntry]? {
    var entries: [String: TreeEntry] = [:]
    guard readTree(fd: root, prefix: "", expectedDevice: checkDevice, into: &entries) else { return nil }
    return entries
}

private func readTree(
    fd: Int32,
    prefix: String,
    expectedDevice: UInt64,
    into entries: inout [String: TreeEntry]
) -> Bool {
    if directoryReadMayContinue(cancelClockAllowsTreeCopy()) == false { return false }
    guard let names = directoryNames(fd, isWorkspaceRoot: prefix.isEmpty) else { return false }
    for name in names {
        if directoryReadMayContinue(cancelClockAllowsTreeCopy()) == false { return false }
        let relative = prefix.isEmpty ? name : prefix + "/" + name
        var status = stat()
        let stated = name.withCString { item in
            fstatat(fd, item, &status, AT_SYMLINK_NOFOLLOW) == 0
        }
        guard stated, device(of: status) == expectedDevice, let stamp = stamp(of: status) else {
            return false
        }
        let bytes = stamp.kind == .regular ? UInt64(status.st_size) : 0
        entries[relative] = TreeEntry(stamp: stamp, mode: modeBits(status.st_mode), bytes: bytes)
        if stamp.kind == .directory {
            let child = name.withCString { item in
                openat(fd, item, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard child >= 0 else { return false }
            let ok = readTree(fd: child, prefix: relative, expectedDevice: expectedDevice, into: &entries)
            close(child)
            if ok == false { return false }
        }
    }
    return true
}

/// Copy names onto the volume as new inodes. A regular file whose link count
/// rose after the snapshot aborts the launch before the agent runs.
func copyTree(
    from source: Int32,
    to destination: Int32,
    expectDevice: UInt64,
    isWorkspaceRoot: Bool = true
) -> Bool {
    if cancelClockAllowsTreeCopy() == false { return false }
    guard let names = directoryNames(source, isWorkspaceRoot: isWorkspaceRoot) else {
        return false
    }
    for name in names {
        if cancelClockAllowsTreeCopy() == false { return false }
        var status = stat()
        let stated = name.withCString { item in
            fstatat(source, item, &status, AT_SYMLINK_NOFOLLOW) == 0
        }
        guard stated, device(of: status) == expectDevice, let kind = stamp(of: status)?.kind else {
            return false
        }
        let mode = modeBits(status.st_mode)
        switch kind {
        case .directory:
            guard name.withCString({ mkdirat(destination, $0, mode) == 0 }) else {
                return false
            }
            let childSource = name.withCString { item in
                openat(source, item, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            let childDest = name.withCString { item in
                openat(destination, item, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard childSource >= 0, childDest >= 0 else {
                if childSource >= 0 { close(childSource) }
                if childDest >= 0 { close(childDest) }
                return false
            }
            let copied = copyTree(
                from: childSource,
                to: childDest,
                expectDevice: expectDevice,
                isWorkspaceRoot: false
            )
            close(childSource)
            close(childDest)
            if copied == false { return false }
        case .symlink:
            var buffer = [CChar](repeating: 0, count: 4096)
            let count = name.withCString { item in
                readlinkat(source, item, &buffer, buffer.count - 1)
            }
            guard count >= 0, count < buffer.count - 1 else {
                return false
            }
            buffer[count] = 0
            let linked = name.withCString { item in
                symlinkat(buffer, destination, item) == 0
            }
            if linked == false {
                return false
            }
        case .regular:
            if status.st_nlink > 1 {
                return false
            }
            let input = name.withCString { item in
                openat(source, item, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard input >= 0 else {
                return false
            }
            var again = stat()
            guard fstat(input, &again) == 0, again.st_nlink <= 1 else {
                close(input)
                return false
            }
            let output = name.withCString { item in
                openat(
                    destination,
                    item,
                    O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_WRONLY,
                    mode
                )
            }
            guard output >= 0 else {
                close(input)
                return false
            }
            let copied = copyFileDataObservingCancelClock(from: input, to: output)
            let modeOK = copied && fchmod(output, mode) == 0
            close(input)
            close(output)
            if modeOK == false { return false }
        }
    }
    return true
}

/// The one clock `Flag.cancel()` armed. A copy stops while `detachCap` is
/// still left, so unmount and detach run inside the 8-second return.
/// No clock means the copy is not clipped. This does not arm a second clock.
func cancelClockAllowsTreeCopy(now: Date = Date()) -> Bool {
    if blockingWorkIsCancelled() {
        CooperativeLaunchStop.noteCancel(now: now)
    }
    guard blockingWorkIsCancelled() || CooperativeLaunchStop.cancelClock?.deadline != nil else {
        return true
    }
    return DiskImageCancelBudget.copyMayContinue(
        deadline: CooperativeLaunchStop.cancelClock?.deadline,
        now: now
    )
}

/// File bytes in chunks so a tree larger than the time left stops before
/// detach is skipped. The xattr copy uses that same clock and does not run
/// once only the detach reserve is left.
func copyFileDataObservingCancelClock(from source: Int32, to destination: Int32) -> Bool {
    copyFileLeavingDetachReserve(
        from: source,
        to: destination,
        mayContinue: publishCopyMayContinue,
        copyXattr: copyExtendedAttributes
    )
}

private func publishCopyMayContinue(_ point: CopyClockPoint) -> Bool {
    _ = point
    return cancelClockAllowsTreeCopy()
}

private func copyExtendedAttributes(_ source: Int32, _ destination: Int32) -> Bool {
    copyXattrsObservingClock(from: source, to: destination) {
        cancelClockAllowsTreeCopy()
    }
}

private func unlinkNewSaved(_ dirfd: Int32, _ name: String) {
    _ = name.withCString { item in
        unlinkat(dirfd, item, 0)
    }
}

func directoryNames(_ dirfd: Int32, isWorkspaceRoot: Bool) -> [String]? {
    guard let listed = readDirectoryNames(dirfd, mayContinue: { cancelClockAllowsTreeCopy() }) else {
        return nil
    }
    var names: [String] = []
    for name in listed {
        // Volume bookkeeping is never workspace content. On filesystems
        // that ignore ownership (workspace volumes) the owner gate cannot
        // distinguish the daemon's copy, so root-level daemon names skip
        // regardless of apparent owner; where ownership is honored only a
        // root-owned copy skips. A nested same-named directory remains part
        // of the boundary.
        if isWorkspaceRoot, WorkspaceFilesystemMetadata.isBookkeepingName(name) {
            var status = stat()
            let stated = name.withCString { item in
                fstatat(dirfd, item, &status, AT_SYMLINK_NOFOLLOW) == 0
            }
            if stated,
                WorkspaceFilesystemMetadata.shouldSkip(
                    name: name,
                    isRootChild: true,
                    isDirectory: kind(of: status.st_mode) == .directory,
                    isSymbolicLink: kind(of: status.st_mode) == .symlink,
                    ownerUid: status.st_uid,
                    ownersIgnored: WorkspaceFilesystemMetadata.filesystemIgnoresOwnership(
                        descriptor: dirfd
                    )
                )
            {
                continue
            }
        }
        names.append(name)
    }
    return names
}

private func acceptableSavedInode(_ captured: WorkspaceInodeStamp, _ status: stat) -> Bool {
    guard let live = stamp(of: status) else { return false }
    return workspaceInodeAcceptableForPublish(captured: captured, live: live)
}

private func stamp(of status: stat) -> WorkspaceInodeStamp? {
    guard let kind = kind(of: status.st_mode) else { return nil }
    return WorkspaceInodeStamp(
        device: device(of: status),
        inode: UInt64(status.st_ino),
        linkCount: UInt64(status.st_nlink),
        kind: kind
    )
}

func kind(of mode: mode_t) -> WorkspaceInodeStamp.Kind? {
    switch mode & S_IFMT {
    case S_IFREG: return .regular
    case S_IFDIR: return .directory
    case S_IFLNK: return .symlink
    default: return nil
    }
}

func modeBits(_ mode: mode_t) -> mode_t {
    mode & 0o777
}

func device(of status: stat) -> UInt64 {
    UInt64(status.st_dev)
}

private func currentDevice(_ path: String) -> UInt64? {
    var status = stat()
    guard path.withCString({ lstat($0, &status) == 0 }) else { return nil }
    return device(of: status)
}

struct WorkspacePathIdentity: Equatable {
    var device: UInt64
    var inode: UInt64
    var isDirectory: Bool
}

func workspacePathIdentity(_ path: String) -> WorkspacePathIdentity? {
    var status = stat()
    guard path.withCString({ lstat($0, &status) == 0 }) else { return nil }
    return WorkspacePathIdentity(
        device: device(of: status),
        inode: UInt64(status.st_ino),
        isDirectory: (status.st_mode & S_IFMT) == S_IFDIR
    )
}

struct WorkspaceMountFacts: Equatable {
    var source: String
    var point: String
}

func workspaceMountFacts(_ path: String) -> WorkspaceMountFacts? {
    var info = statfs()
    guard path.withCString({ statfs($0, &info) == 0 }) else { return nil }
    let source = withUnsafePointer(to: info.f_mntfromname) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: info.f_mntfromname)) {
            String(cString: $0)
        }
    }
    let point = withUnsafePointer(to: info.f_mntonname) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: info.f_mntonname)) {
            String(cString: $0)
        }
    }
    return WorkspaceMountFacts(source: source, point: point)
}

func workspaceMountSource(_ path: String) -> String? {
    workspaceMountFacts(path)?.source
}

private func pathDepth(_ path: String) -> Int {
    path.split(separator: "/").count
}

private func renamePath(_ source: String, _ destination: String) -> Bool {
    source.withCString { from in
        destination.withCString { to in
            rename(from, to) == 0
        }
    }
}

/// Delete a leftover mountpoint directory only when every inode is a
/// single-link object. A planted hard link is left in place.
private func inodeCheckedDelete(_ root: String) -> Bool {
    var status = stat()
    let exists = root.withCString { lstat($0, &status) == 0 }
    guard exists else { return true }
    guard kind(of: status.st_mode) == .directory else {
        if status.st_nlink > 1 { return false }
        return root.withCString { unlink($0) == 0 }
    }
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else {
        return false
    }
    for name in names {
        let child = (root as NSString).appendingPathComponent(name)
        if inodeCheckedDelete(child) == false { return false }
    }
    return root.withCString { rmdir($0) == 0 }
}

private struct ToolOutput {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut = false
    var helperStillAlive = false

    init(
        status: Int32,
        stdout: String,
        stderr: String,
        timedOut: Bool = false,
        helperStillAlive: Bool = false
    ) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.helperStillAlive = helperStillAlive
    }
}

private enum DiskImageAttempt {
    case done(ToolOutput)
    case yielded
}

/// One diskimage helper at a time. Parallel `hdiutil`/`mount_hfs` calls
/// pile onto diskimagesd until it stops answering; each waiter then sits
/// through its deadline and the F-M shard hits the job cap. The lock is
/// only around the helper, not the contained command.
///
/// A cancelled teardown does not sit out that wait. Non-urgent holders
/// abort when a cancelled caller is queued. The lock stays held until
/// the aborted helper has exited and a preempted attach or mount has
/// been detached or unmounted, so the next helper cannot start on top
/// of a parked process or a leaked device. Lock-wait time counts toward
/// the caller's deadline. The cancelled detach path's own deadlines stay
/// inside the 8-second return bound (`DiskImageCancelBudget`).
private enum DiskImageToolSerialization {
    static let lock = Mutex<UInt8>(0)
    private static let priority = Mutex<DiskImagePriority>(DiskImagePriority())

    static func contains(_ path: String) -> Bool {
        path == "/usr/bin/hdiutil" || path == "/sbin/mount_hfs" || path == "/sbin/umount"
    }

    static func notePriorityWaiter() {
        priority.withLock { $0.waiters += 1 }
    }

    static func endPriorityWaiter() {
        priority.withLock { state in
            if state.waiters > 0 { state.waiters -= 1 }
        }
    }

    static func beginHolding(urgent: Bool) {
        priority.withLock { $0.urgent = urgent }
    }

    static func endHolding() {
        priority.withLock { $0.urgent = false }
    }

    /// True when another cancelled teardown is queued. Urgent holders yield
    /// too, unless this acquire was granted a turn (`yieldsToWaiter`).
    /// Otherwise a second `detachCancelledVolume` gives up while the first
    /// still holds the lock and leaves its volume mounted.
    static func hasPriorityWaiter() -> Bool {
        waiterCount() > 0
    }

    static func waiterCount() -> Int {
        priority.withLock { $0.waiters }
    }

    private static let publication = Mutex<PublicationGate>(PublicationGate())

    static func publicationGateHeld() -> Bool {
        publication.withLock { $0.held }
    }

    static func notePublicationGate(
        _ plan: PreemptedDiskHelperCleanup,
        helperStillAlive: Bool,
        diskCanStillAppear: Bool,
        busy: Bool,
        pid: pid_t
    ) {
        let parked = publication.withLock { $0 }
        let parkedAlive = parked.pid > 1 && kill(parked.pid, 0) == 0
        let held = diskImagePublicationGateUpdate(
            plan: plan,
            helperStillAlive: helperStillAlive,
            diskCanStillAppear: diskCanStillAppear,
            busy: busy,
            parkedHelperStillAlive: parkedAlive,
            parkedDiskCanStillAppear: parked.held && parkedAlive,
            publicationAlreadyHeld: parked.held
        )
        let keep = diskImagePublicationHoldAfterUpdate(
            updateKeepsHold: held,
            planHasImage: diskImagePublicationImage(plan) != nil,
            parkedImageKnown: parked.image?.isEmpty == false,
            helperStillAlive: helperStillAlive || parkedAlive,
            diskCanStillAppear: diskCanStillAppear
        )
        publication.withLock { state in
            if keep {
                state.held = true
                if let image = diskImagePublicationImage(plan) { state.image = image }
                if pid > 1 { state.pid = pid }
            } else {
                state.held = false
                state.image = nil
                state.pid = 0
            }
        }
    }

    /// One bounded recheck once the helper is dead. The 0.5s sleep and the
    /// 0.25s info are clipped to the cancel clock, so a cancelled acquire
    /// still returns inside `returnBound`. A sibling row does not clear
    /// while this file is present. A nil listing does not clear on a failed
    /// stat. This does not spin until the 30-minute cap.
    static func clearPublicationGateIfDiskIsGone(clock: DiskImageCancelClock) {
        let parked = publication.withLock { $0 }
        guard parked.held else { return }
        let helperAlive = parked.pid > 1 && kill(parked.pid, 0) == 0
        guard let image = parked.image, image.isEmpty == false else {
            guard diskImagePublicationCanClear(
                helperStillAlive: helperAlive,
                diskCanStillAppear: false,
                imageKnown: false
            ) else { return }
            publication.withLock { state in
                let stillNoImage = state.image == nil || state.image?.isEmpty == true
                let alive = state.pid > 1 && kill(state.pid, 0) == 0
                guard state.held, stillNoImage, alive == false else { return }
                state.held = false
                state.image = nil
                state.pid = 0
            }
            return
        }
        if helperAlive { return }
        let cleanup = diskImageRecheckAllowance(
            budget: DiskImageCancelBudget.preemptCleanup,
            cancelDeadline: clock.deadline,
            now: Date()
        )
        if cleanup > 0 {
            usleep(UInt32(cleanup * 1_000_000))
        }
        let infoBudget = diskImageRecheckAllowance(
            budget: DiskImageCancelBudget.preemptReap,
            cancelDeadline: clock.deadline,
            now: Date()
        )
        guard infoBudget > 0 else { return }
        let deadline = Date().addingTimeInterval(infoBudget)
        let listed = workspaceImageListed(image, returnDeadline: deadline, clock: clock)
        let identityIsImage = image.contains("rv-inode-") && image.hasSuffix(".sparseimage")
        let imageFileGone = diskImageParkedPathIsGone(image, identityIsImage: identityIsImage)
        guard diskImagePublicationRecheckCanClear(
            helperStillAlive: false,
            imageListed: listed.imageListed,
            infoTimedOut: listed.infoTimedOut,
            imageFileGone: imageFileGone,
            identityIsImage: identityIsImage
        ) else { return }
        publication.withLock { state in
            guard let current = state.image, diskImageSamePath(current, image) else { return }
            let alive = state.pid > 1 && kill(state.pid, 0) == 0
            guard alive == false else { return }
            state.held = false
            state.image = nil
            state.pid = 0
        }
    }
}

final class DiskImageArmedSlice: @unchecked Sendable {
    var deadline: Date?
}

private struct PublicationGate: Sendable {
    var held = false
    var image: String?
    var pid: pid_t = 0
}

func diskImagePublicationImage(_ plan: PreemptedDiskHelperCleanup) -> String? {
    switch plan {
    case .unlinkSparseImage(let path), .detachImage(let path), .unmount(let path):
        return path
    case .none:
        return nil
    }
}

private struct DiskImagePriority: Sendable {
    var waiters = 0
    var urgent = false
}

private func diskDevice(in text: String) -> String? {
    text.split(whereSeparator: \.isWhitespace).map(String.init).first { $0.hasPrefix("/dev/disk") }
}

/// The mountable HFS slice from a `-nomount` attach plist: the entity
/// whose content hint is Apple_HFS, or the sole partition when hints are
/// absent (images rv creates carry exactly one volume).
func hfsSliceDevice(inPlist stdout: String) -> String? {
    guard let entities = systemEntities(inPlist: stdout) else { return nil }
    let devices: [(device: String, hint: String?)] = entities.compactMap { entity in
        guard let device = entity["dev-entry"]?.string else { return nil }
        return (device, entity["content-hint"]?.string)
    }
    if let hfs = devices.first(where: { $0.hint == "Apple_HFS" }) {
        return hfs.device
    }
    let partitions = devices.dropFirst().map(\.device)
    return partitions.count == 1 ? partitions.first : nil
}

/// Tears a workspace disk down without asking DiskArbitration to unmount.
/// Arbitration-mediated unmounts wedge when diskarbitrationd is
/// unresponsive (after which `hdiutil detach` fails "Resource busy"),
/// while a direct `umount` completes in milliseconds and detaching the
/// bare disk afterwards succeeds.
@discardableResult
private func detachWorkspaceDisk(_ disk: String, mountPoint: String?) -> Bool {
    let clock = CooperativeLaunchStop.adoptCancelClock(DiskImageCancelClock())
    if blockingWorkIsCancelled(), clock.deadline == nil {
        clock.arm(spentSinceCancel: CooperativeLaunchStop.spentSinceCancel())
    }
    if let mountPoint {
        let plain = clock.deadline == nil
            ? nil
            : min(DiskImageCancelBudget.cancelledDetachHelpers().plainUnmount, clock.remaining)
        unmountDirect(
            mountPoint,
            onlySource: disk,
            plainDeadline: plain,
            forceDeadline: clock.deadline == nil ? nil : cancelledForceUnmountBudget(clock),
            clock: clock
        )
    }
    if clock.deadline != nil || blockingWorkIsCancelled() {
        if clock.deadline == nil {
            clock.arm(spentSinceCancel: CooperativeLaunchStop.spentSinceCancel())
        }
        let detachLeft = min(DiskImageCancelBudget.detachCap, clock.remaining)
        if detachLeft <= 0 { return false }
        let cancelledDetach = runTool(
            ["/usr/bin/hdiutil", "detach", "-force", "-quiet", disk],
            honorCancellation: false,
            deadline: detachLeft,
            clock: clock
        )
        return DiskImageCancelBudget.preemptCleanupSucceeded(
            status: cancelledDetach.status,
            timedOut: cancelledDetach.timedOut
        )
    }
    let detached = runTool(
        ["/usr/bin/hdiutil", "detach", "-force", "-quiet", disk],
        honorCancellation: false,
        clock: clock
    )
    return DiskImageCancelBudget.preemptCleanupSucceeded(
        status: detached.status,
        timedOut: detached.timedOut
    )
}

private func unlinkImageIfDetached(_ image: String?, detachSucceeded: Bool) {
    guard let image, diskImageMayRemoveImage(detachSucceeded: detachSucceeded) else { return }
    unlink(image)
}

/// File-level so `detachWorkspaceDisk` uses the same 0.5s force slice
/// `cancelledSequenceBudget` counts. `remaining - 1` let one holder
/// occupy the lock until the other teardown's clock expired.
private func cancelledForceUnmountBudget(_ clock: DiskImageCancelClock) -> TimeInterval {
    DiskImageCancelBudget.cancelledForceSlice(remaining: clock.remaining)
}

/// Direct `umount` of our own volume. Only runs when the mountpoint's
/// statfs source is our disk, so a reused path never unmounts a foreign
/// volume. Plain unmount first; forced only while our source is still
/// mounted (open descriptors make the plain call fail busy).
private func unmountDirect(
    _ mountPoint: String,
    onlySource disk: String,
    plainDeadline: TimeInterval? = nil,
    forceDeadline: TimeInterval? = nil,
    clock: DiskImageCancelClock = DiskImageCancelClock()
) {
    func isOurs(_ source: String?) -> Bool {
        guard let source else { return false }
        return source == disk || source.hasPrefix(disk + "s")
    }
    guard isOurs(workspaceMountSource(mountPoint)) else { return }
    _ = runTool(
        ["/sbin/umount", mountPoint],
        honorCancellation: false,
        deadline: plainDeadline,
        clock: clock
    )
    guard isOurs(workspaceMountSource(mountPoint)) else { return }
    let force = clock.deadline == nil ? forceDeadline : cancelledForceUnmountBudget(clock)
    if clock.deadline != nil, (force ?? 0) <= 0 { return }
    _ = runTool(
        ["/sbin/umount", "-f", mountPoint],
        honorCancellation: false,
        deadline: force,
        clock: clock
    )
}

/// Runs a short-lived helper.
///
/// The pipes are drained while the child runs. `waitUntilExit` before that
/// drain deadlocks once a child fills the pipe, and it also ignores task
/// cancellation. Under parallel launches DiskArbitration holds `hdiutil`
/// long enough that a cancelled test used to sit inside that wait until the
/// runner timed the test out. A helper with no deadline did the same thing:
/// a wedged `hdiutil` never returned, and the isolation job sat until GitHub
/// cancelled it. The default deadline kills that helper and returns.
/// Mount and unmount go through `mount_hfs`/`umount` directly instead of
/// arbitration-mediated `diskutil`, so they stay fast when the daemon is
/// unresponsive; only bare-disk attach/detach still use `hdiutil`.
/// Cancellation kills the helper and returns.
/// The executor runs this on `rv-executor-apply`; the poll sees that thread's
/// flag as well as `Task.isCancelled`. Cleanup calls pass
/// `honorCancellation: false` so a cancelled task can still detach the disk
/// it created. Diskimage helpers take `DiskImageToolSerialization.lock`
/// until the helper has exited or the reap deadline has passed. A preempted
/// attach or mount is detached or unmounted before a retry, and only when
/// that follow-up exits 0. Lock-wait time counts toward the cancelled
/// sequence clock, never the 45-second default. A cancel that arrives
/// during the wait notes a priority waiter on the next poll instead of
/// running the attempt as non-urgent. Urgent holders yield to that waiter
/// unless this acquire was granted a turn.
private func runTool(
    _ arguments: [String],
    honorCancellation: Bool = false,
    deadline: TimeInterval? = 45,
    clock suppliedClock: DiskImageCancelClock = DiskImageCancelClock()
) -> ToolOutput {
    let clock = CooperativeLaunchStop.adoptCancelClock(suppliedClock)
    guard let executable = arguments.first else {
        return ToolOutput(status: 1, stdout: "", stderr: "missing executable")
    }
    guard DiskImageToolSerialization.contains(executable) else {
        return runToolBody(
            arguments,
            honorCancellation: honorCancellation,
            deadline: deadline,
            yieldToPriorityWaiter: false
        ).output
    }
    // A yield has no caller-visible failure. Before spawn, nothing ran.
    // Mid-flight, the helper was killed so this same teardown can take
    // the lock; retrying here keeps the caller's own retry for a real
    // diskimagesd failure. The preempted helper is reaped, and a partial
    // image, attach, or mount is cleaned, before the lock drops.
    let helperSlice = deadline
    let acquireSlice = deadline ?? 45
    // The 45-second slice starts when the lock is taken, not while a peer
    // holds it. A later poll does not move that end. The wait to take the
    // lock stops at 120 seconds, not at the 30-minute job cap and not at 45.
    let armedSlice = DiskImageArmedSlice()
    let peerWaitEnd = Date().addingTimeInterval(DiskImageCancelBudget.peerAcquireWait)
    var notedPriority = false
    var protectNext = false
    defer {
        if notedPriority {
            DiskImageToolSerialization.endPriorityWaiter()
        }
    }
    while true {
        if blockingWorkIsCancelled() {
            clock.arm(spentSinceCancel: CooperativeLaunchStop.spentSinceCancel())
        }
        if let end = clock.deadline {
            // The wait is the sequence clock. A 45-second default, or a
            // 0.5-second umount slice, must not expire it while a peer
            // still holds the lock.
            _ = diskImageNextWaitDeadline(
                current: end,
                now: Date(),
                cancelled: true,
                cancelDeadline: end
            )
            if diskImageLockWaitIsExpired(cancelled: true, cancelClockSpent: Date() >= end) {
                return ToolOutput(status: -1, stdout: "", stderr: "diskimage lock", timedOut: true)
            }
        } else if let armed = armedSlice.deadline {
            armedSlice.deadline = diskImageNextWaitDeadline(
                current: armed,
                now: Date(),
                cancelled: false,
                cancelDeadline: nil
            )
        }
        if blockingWorkIsCancelled(), notedPriority == false {
            DiskImageToolSerialization.notePriorityWaiter()
            notedPriority = true
        }
        let notedAtEntry = notedPriority
        let protectThis = protectNext
        protectNext = false
        let attempt = DiskImageToolSerialization.lock.withLockIfAvailable { _ -> DiskImageAttempt in
            if notedAtEntry {
                DiskImageToolSerialization.endPriorityWaiter()
            }
            let urgent = blockingWorkIsCancelled()
            DiskImageToolSerialization.beginHolding(urgent: urgent)
            let others = DiskImageToolSerialization.waiterCount()
            // A missed lock sets `protectThis` for this acquire. That turn
            // is only for an urgent holder. A non-urgent create or attach
            // still yields, so the cancelled waiter can unmount.
            if DiskImageCancelBudget.yieldsToWaiter(
                otherWaiters: others,
                protectThisAcquire: protectThis,
                holderIsUrgent: urgent
            ) {
                DiskImageToolSerialization.endHolding()
                return .yielded
            }
            let budgetEnd: Date
            if let cancelEnd = clock.deadline {
                budgetEnd = cancelEnd
            } else {
                armedSlice.deadline = diskImageAcquireSliceDeadline(
                    armed: armedSlice.deadline,
                    now: Date(),
                    slice: acquireSlice,
                    peerHoldsLock: false
                )
                budgetEnd = armedSlice.deadline ?? Date().addingTimeInterval(acquireSlice)
            }
            let remaining = budgetEnd.timeIntervalSinceNow
            if diskImagePeerWaitFailsBoundary(
                peerHoldsLock: false,
                acquireSliceSpent: remaining <= 0
            ) {
                DiskImageToolSerialization.endHolding()
                return .done(
                    ToolOutput(status: -1, stdout: "", stderr: "diskimage lock", timedOut: true)
                )
            }
            DiskImageToolSerialization.clearPublicationGateIfDiskIsGone(clock: clock)
            if diskImageMayStartHelper(
                publicationHeld: DiskImageToolSerialization.publicationGateHeld(),
                arguments: arguments
            ) == false {
                DiskImageToolSerialization.endHolding()
                return .done(
                    ToolOutput(status: -1, stdout: "", stderr: "diskimage published", timedOut: true)
                )
            }
            var attemptSeconds = remaining
            if let helperSlice {
                attemptSeconds = min(attemptSeconds, helperSlice)
            }
            // Once the clock is armed, plain umount, force umount, and
            // detach all use `urgentDeadline`. Force is 0.5s, the slice
            // the sequence budget counts, not the time left minus 1s.
            if clock.deadline != nil,
                let urgentCap = DiskImageCancelBudget.urgentDeadline(arguments: arguments) {
                attemptSeconds = min(attemptSeconds, urgentCap)
            }
            let ran = runToolBody(
                arguments,
                honorCancellation: honorCancellation,
                deadline: attemptSeconds,
                yieldToPriorityWaiter: DiskImageCancelBudget.yieldsToWaiter(
                    otherWaiters: 1,
                    protectThisAcquire: protectThis,
                    holderIsUrgent: urgent
                ),
                parkIfStuck: false,
                returnDeadline: budgetEnd,
                clock: clock
            )
            let plan = PreemptedDiskHelperCleanup.plan(arguments: arguments)
            let returnDeadline = budgetEnd
            let mustDetach = diskImageMustDetachBeforeUnlock(
                cleanup: plan,
                helperStillAlive: ran.helperStillAlive,
                preempted: ran.preempted,
                timedOut: ran.output.timedOut,
                status: ran.output.status
            )
            if ran.helperStillAlive || ran.preempted || mustDetach {
                // One cleanup, then the closure returns. A live helper or a
                // busy detach keeps the publication hold so the next attach
                // does not start, and umount can take the mutex. "busy" is
                // not a reason to spin. An empty listing is not proof the
                // disk is gone, so it does not finish cleanup.
                var helperAlive = ran.helperStillAlive
                if helperAlive, clock.deadline != nil {
                    let slice = DiskImageCancelBudget.reapSlice(until: returnDeadline, now: Date())
                    let end = Date().addingTimeInterval(slice)
                    while helperAlive, Date() < end {
                        if ran.pid > 1, kill(ran.pid, 0) != 0 {
                            helperAlive = false
                            break
                        }
                        usleep(10_000)
                    }
                }
                let cleanup: PreemptCleanupOutcome
                if helperAlive {
                    cleanup = PreemptCleanupOutcome(
                        succeeded: false,
                        targetWasAbsent: false,
                        busy: false,
                        diskCanStillAppear: true,
                        waitedForPublication: false
                    )
                } else {
                    // One publication wait, not a retry loop. An empty or
                    // unreported listing still does not prove the disk is gone.
                    let allowance = min(
                        DiskImageCancelBudget.preemptCleanup,
                        max(0, returnDeadline.timeIntervalSinceNow)
                    )
                    if allowance > 0 {
                        usleep(UInt32(allowance * 1_000_000))
                    }
                    cleanup = applyPreemptCleanup(
                        plan,
                        returnDeadline: returnDeadline,
                        clock: clock,
                        helperCanStillPublish: false,
                        waitedForPublication: allowance > 0
                    )
                }
                let exit = diskImageSerializationExit(
                    helperStillAlive: helperAlive,
                    diskCanStillAppear: helperAlive || cleanup.diskCanStillAppear,
                    detachOutputContainsBusy: cleanup.busy
                )
                DiskImageToolSerialization.notePublicationGate(
                    plan,
                    helperStillAlive: helperAlive,
                    diskCanStillAppear: helperAlive || cleanup.diskCanStillAppear,
                    busy: cleanup.busy,
                    pid: ran.pid
                )
                if helperAlive == false && cleanup.diskCanStillAppear == false && cleanup.busy == false {
                    DiskImageToolSerialization.clearPublicationGateIfDiskIsGone(clock: clock)
                }
                DiskImageToolSerialization.endHolding()
                let mayRetry = diskImageMayRetryPreemptedHelper(
                    cleanup: plan,
                    cleanupSucceeded: cleanup.succeeded,
                    helperStillAlive: helperAlive,
                    targetWasAbsent: cleanup.targetWasAbsent,
                    diskCanStillAppear: helperAlive || cleanup.diskCanStillAppear || cleanup.busy
                )
                if exit.mayStartNextAttach && mayRetry
                    && (ran.preempted || ran.output.status != 0) && ran.output.timedOut == false {
                    return .yielded
                }
                if exit.mayStartNextAttach == false || cleanup.busy || cleanup.diskCanStillAppear || helperAlive {
                    return .done(
                        ToolOutput(
                            status: -1,
                            stdout: "",
                            stderr: cleanup.busy ? "diskimage busy" : "preempt cleanup failed",
                            timedOut: true,
                            helperStillAlive: helperAlive
                        )
                    )
                }
                if ran.preempted || ran.output.timedOut {
                    var output = ran.output
                    output.helperStillAlive = helperAlive
                    return .done(output)
                }
            }
            DiskImageToolSerialization.clearPublicationGateIfDiskIsGone(clock: clock)
            DiskImageToolSerialization.endHolding()
            var output = ran.output
            output.helperStillAlive = ran.helperStillAlive
            return .done(output)
        }
        if attempt != nil, notedAtEntry {
            notedPriority = false
        }
        switch attempt {
        case nil:
            protectNext = true
            if clock.deadline == nil,
                diskImagePeerWaitFailsBoundary(
                    peerHoldsLock: true,
                    acquireSliceSpent: false,
                    peerWaitSpent: Date() >= peerWaitEnd
                ) {
                return ToolOutput(status: -1, stdout: "", stderr: "diskimage lock", timedOut: true)
            }
            usleep(10_000)
        case .some(.done(let output)):
            return output
        case .some(.yielded):
            protectNext = true
            if let end = clock.deadline,
                diskImageLockWaitIsExpired(cancelled: true, cancelClockSpent: Date() >= end) {
                return ToolOutput(status: -1, stdout: "", stderr: "diskimage lock", timedOut: true)
            } else if diskImagePeerWaitFailsBoundary(
                peerHoldsLock: true,
                acquireSliceSpent: false,
                peerWaitSpent: Date() >= peerWaitEnd
            ) {
                return ToolOutput(status: -1, stdout: "", stderr: "diskimage lock", timedOut: true)
            }
            usleep(20_000)
        }
    }
}

private struct PreemptCleanupOutcome {
    var succeeded: Bool
    var targetWasAbsent: Bool
    var busy: Bool
    var diskCanStillAppear: Bool
    var waitedForPublication: Bool
}

/// Runs inside `DiskImageToolSerialization.lock`. Unlink is immediate.
/// A follow-up detach or unmount uses `runToolBody` directly so it does
/// not take the lock again. Success is exit 0 before the deadline. The
/// reap after SIGKILL is bounded by `returnDeadline`. The follow-up stays
/// on this helper's own image or mount.
@discardableResult
private func applyPreemptCleanup(
    _ plan: PreemptedDiskHelperCleanup,
    returnDeadline: Date,
    clock: DiskImageCancelClock,
    helperCanStillPublish: Bool,
    waitedForPublication: Bool = false
) -> PreemptCleanupOutcome {
    guard diskImageCleanupConfinedToCaller(plan) else {
        return PreemptCleanupOutcome(
            succeeded: false,
            targetWasAbsent: false,
            busy: false,
            diskCanStillAppear: true,
            waitedForPublication: waitedForPublication
        )
    }
    switch plan {
    case .none:
        return PreemptCleanupOutcome(
            succeeded: true,
            targetWasAbsent: false,
            busy: false,
            diskCanStillAppear: false,
            waitedForPublication: true
        )
    case .unlinkSparseImage(let path):
        // Create does not publish a disk. A helper that is still running
        // can. Leave the file until that helper has exited.
        guard diskImageMayUnlinkPublishedImage(
            helperStillAlive: helperCanStillPublish,
            detachSucceeded: true,
            diskCanStillAppear: false
        ) else {
            return PreemptCleanupOutcome(
                succeeded: false,
                targetWasAbsent: false,
                busy: false,
                diskCanStillAppear: helperCanStillPublish,
                waitedForPublication: waitedForPublication
            )
        }
        unlink(path)
        return PreemptCleanupOutcome(
            succeeded: true,
            targetWasAbsent: false,
            busy: false,
            diskCanStillAppear: false,
            waitedForPublication: true
        )
    case .detachImage(let image):
        return detachPublishedTarget(
            plan,
            identity: image,
            returnDeadline: returnDeadline,
            clock: clock,
            helperCanStillPublish: helperCanStillPublish,
            waitedForPublication: waitedForPublication
        )
    case .unmount(let mount):
        return detachPublishedTarget(
            plan,
            identity: mount,
            returnDeadline: returnDeadline,
            clock: clock,
            helperCanStillPublish: helperCanStillPublish,
            waitedForPublication: waitedForPublication
        )
    }
}

private func detachPublishedTarget(
    _ plan: PreemptedDiskHelperCleanup,
    identity: String,
    returnDeadline: Date,
    clock: DiskImageCancelClock,
    helperCanStillPublish: Bool,
    waitedForPublication: Bool
) -> PreemptCleanupOutcome {
    // The original helper can still publish. Do not detach or unmount
    // until it has exited.
    if helperCanStillPublish {
        return PreemptCleanupOutcome(
            succeeded: false,
            targetWasAbsent: false,
            busy: false,
            diskCanStillAppear: true,
            waitedForPublication: false
        )
    }
    guard let follow = plan.followUpArguments else {
        return PreemptCleanupOutcome(
            succeeded: false,
            targetWasAbsent: false,
            busy: false,
            diskCanStillAppear: true,
            waitedForPublication: waitedForPublication
        )
    }
    let ran = runToolBody(
        follow,
        honorCancellation: false,
        deadline: min(DiskImageCancelBudget.preemptCleanup, max(0, returnDeadline.timeIntervalSinceNow)),
        yieldToPriorityWaiter: false,
        parkIfStuck: false,
        returnDeadline: returnDeadline,
        clock: clock
    )
    let output = ran.output.stderr + "\n" + ran.output.stdout
    if ran.helperStillAlive {
        return PreemptCleanupOutcome(
            succeeded: false,
            targetWasAbsent: false,
            busy: false,
            diskCanStillAppear: true,
            waitedForPublication: false
        )
    }
    let busy = diskImageDetachIsBusy(
        status: ran.output.status,
        timedOut: ran.output.timedOut,
        output: output
    )
    let absent = diskImageCleanupTargetWasAbsent(
        status: ran.output.status,
        timedOut: ran.output.timedOut,
        output: output
    )
    let listed: Bool? = busy ? true : workspaceImageListed(
        identity,
        returnDeadline: returnDeadline,
        clock: clock
    ).imageListed
    let canAppear = diskImageCanStillAppear(
        helperStillAlive: ran.helperStillAlive,
        detachStatus: ran.output.status,
        detachTimedOut: ran.output.timedOut,
        detachOutput: output,
        imageListedAfterDetach: listed,
        waitedForPublication: waitedForPublication
    )
    let detachOK = DiskImageCancelBudget.preemptCleanupSucceeded(
        status: ran.output.status,
        timedOut: ran.output.timedOut
    )
    let finished = diskImageMayUnlinkPublishedImage(
        helperStillAlive: ran.helperStillAlive,
        detachSucceeded: detachOK,
        diskCanStillAppear: canAppear
    )
    return PreemptCleanupOutcome(
        succeeded: finished,
        targetWasAbsent: absent && canAppear == false,
        busy: busy,
        diskCanStillAppear: canAppear,
        waitedForPublication: waitedForPublication
    )
}

struct DiskImageListingRead: Equatable, Sendable {
    var imageListed: Bool?
    var infoTimedOut: Bool
}

/// `hdiutil info` for one image. A timeout is not an empty listing.
/// Already inside the serialization lock, so this uses `runToolBody`.
private func workspaceImageListed(
    _ image: String,
    returnDeadline: Date,
    clock: DiskImageCancelClock
) -> DiskImageListingRead {
    let info = runToolBody(
        ["/usr/bin/hdiutil", "info", "-plist"],
        honorCancellation: false,
        deadline: min(1.0, max(0, returnDeadline.timeIntervalSinceNow)),
        yieldToPriorityWaiter: false,
        parkIfStuck: false,
        returnDeadline: returnDeadline,
        clock: clock
    )
    if info.helperStillAlive || info.output.timedOut || info.output.status != 0 {
        return DiskImageListingRead(imageListed: nil, infoTimedOut: true)
    }
    guard let data = info.output.stdout.data(using: .utf8),
        let images = AttachedWorkspaceImage.parse(hdiutilInfo: data)
    else { return DiskImageListingRead(imageListed: nil, infoTimedOut: false) }
    return DiskImageListingRead(
        imageListed: diskImageInfoListingShowsImage(
            parsedImageCount: images.count,
            identity: image,
            imagePaths: images.map(\.imagePath),
            mountPoints: images.compactMap(\.mountPoint)
        ),
        infoTimedOut: false
    )
}

private struct HelperRun {
    var output: ToolOutput
    var preempted = false
    var helperStillAlive = false
    var pid: pid_t = 0
}

private func runToolBody(
    _ arguments: [String],
    honorCancellation: Bool,
    deadline: TimeInterval?,
    yieldToPriorityWaiter: Bool,
    parkIfStuck: Bool = true,
    returnDeadline: Date? = nil,
    clock: DiskImageCancelClock? = nil
) -> HelperRun {
    guard let executable = arguments.first else {
        return HelperRun(output: ToolOutput(status: 1, stdout: "", stderr: "missing executable"))
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = Array(arguments.dropFirst())
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    process.standardInput = FileHandle.nullDevice
    let outFD = output.fileHandleForReading.fileDescriptor
    let errFD = errors.fileHandleForReading.fileDescriptor
    guard setToolNonblocking(outFD), setToolNonblocking(errFD) else {
        return HelperRun(output: ToolOutput(status: 1, stdout: "", stderr: "pipe flags"))
    }
    do {
        try process.run()
    } catch {
        return HelperRun(output: ToolOutput(status: 1, stdout: "", stderr: String(describing: error)))
    }
    var stdout = Data()
    var stderr = Data()
    var limit = deadline.map { Date().addingTimeInterval($0) }
    if let returnDeadline, let existing = limit {
        limit = min(existing, returnDeadline)
    } else if let returnDeadline {
        limit = returnDeadline
    }
    var interrupted = false
    var timedOut = false
    var preempted = false
    var didArmCancel = false
    while process.isRunning {
        stdout.append(readToolPipe(outFD))
        stderr.append(readToolPipe(errFD))
        // `honorCancellation` stays false for umount and detach so a
        // cancelled task can still tear the disk down. Those helpers
        // used to keep the 45s snapshot they computed at spawn. Arm the
        // shared clock on the poll that first sees the flag, and cap
        // this process at the urgent slice. Time after that arm counts
        // against the same 7.75s; the next helper does not get another.
        if blockingWorkIsCancelled(),
            didArmCancel == false,
            DiskImageCancelBudget.urgentDeadline(arguments: arguments) != nil {
            didArmCancel = true
            let spent = CooperativeLaunchStop.spentSinceCancel()
            clock?.arm(spentSinceCancel: spent)
            let allowed = DiskImageCancelBudget.inFlightLimit(
                callerDeadline: deadline,
                spentSinceCancel: spent,
                arguments: arguments
            )
            var cap = Date().addingTimeInterval(allowed)
            if let end = clock?.deadline ?? CooperativeLaunchStop.cancelClock?.deadline {
                cap = min(cap, end)
            }
            limit = limit.map { min($0, cap) } ?? cap
        }
        let cancelled = honorCancellation && blockingWorkIsCancelled()
        let expired = limit.map { Date() >= $0 } ?? false
        // A cancelled teardown is waiting on the serialization lock.
        // Kill this helper immediately so that teardown can acquire the
        // lock inside its own deadline. `runTool` retries afterwards.
        // This is not a diskimagesd timeout.
        preempted = yieldToPriorityWaiter && DiskImageToolSerialization.hasPriorityWaiter()
        if preempted {
            interrupted = true
            kill(process.processIdentifier, SIGKILL)
            break
        }
        if cancelled || expired {
            interrupted = true
            timedOut = expired
            process.terminate()
            // Grace and the reap stop at the cancel clock. Adding them
            // after that deadline would put the return past 8 seconds.
            let stopAt = clock?.deadline ?? CooperativeLaunchStop.cancelClock?.deadline ?? returnDeadline
            let graceEnd = Date().addingTimeInterval(DiskImageCancelBudget.signalGrace)
            let graceStop = stopAt.map { min($0, graceEnd) } ?? graceEnd
            while process.isRunning, Date() < graceStop {
                stdout.append(readToolPipe(outFD))
                stderr.append(readToolPipe(errFD))
                usleep(10_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            break
        }
        usleep(10_000)
    }
    var helperStillAlive = false
    if interrupted {
        // Bounded reap, then park. `parkIfStuck: false` used to spin until
        // the process exited, so a D-state umount kept the cancelled caller
        // past 8 seconds. The return deadline cuts the reap short.
        let reapBound = clock?.deadline ?? CooperativeLaunchStop.cancelClock?.deadline ?? returnDeadline
        let reapDeadline = reapBound.map {
            Date().addingTimeInterval(DiskImageCancelBudget.reapSlice(until: $0, now: Date()))
        } ?? Date().addingTimeInterval(DiskImageCancelBudget.preemptReap)
        while process.isRunning, Date() < reapDeadline {
            stdout.append(readToolPipe(outFD))
            stderr.append(readToolPipe(errFD))
            usleep(10_000)
        }
        if process.isRunning {
            UnreapedToolProcesses.park(process)
            helperStillAlive = true
        } else {
            process.waitUntilExit()
        }
        _ = parkIfStuck
    } else {
        process.waitUntilExit()
    }
    stdout.append(readToolPipe(outFD))
    stderr.append(readToolPipe(errFD))
    try? output.fileHandleForReading.close()
    try? errors.fileHandleForReading.close()
    let status: Int32 = interrupted ? -1 : process.terminationStatus
    return HelperRun(
        output: ToolOutput(
            status: status,
            stdout: String(data: stdout, encoding: .utf8) ?? "",
            stderr: String(data: stderr, encoding: .utf8) ?? "",
            timedOut: timedOut
        ),
        preempted: preempted,
        helperStillAlive: helperStillAlive,
        pid: helperStillAlive ? process.processIdentifier : 0
    )
}

/// Runs `/bin/sleep` until the current task is cancelled.
/// The status is `-1` when cancellation kills the helper.
func cancellableHelperProbe() -> Int32 {
    runTool(["/bin/sleep", "30"], honorCancellation: true, deadline: 30).status
}

private func setToolNonblocking(_ fd: Int32) -> Bool {
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0 else { return false }
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0
}

private func readToolPipe(_ fd: Int32) -> Data {
    var bytes = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        // `O_NONBLOCK` does not stick on a Foundation pipe. A blocking
        // `read` here never returns to the deadline check, so a quiet
        // `hdiutil` holds the isolation job until the runner cancels it.
        var state = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&state, 1, 0)
        if ready < 0 {
            if errno == EINTR { continue }
            return bytes
        }
        if ready == 0 { return bytes }
        // `poll` also reports POLLHUP/POLLERR. `O_NONBLOCK` does not stick
        // on a Foundation pipe, so a `read` without POLLIN blocks and the
        // deadline above never runs. That is the isolation-job hang.
        if state.revents & Int16(POLLIN) == 0 { return bytes }
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return read(fd, base, raw.count)
        }
        if count > 0 {
            bytes.append(contentsOf: buffer.prefix(count))
            continue
        }
        if count < 0, errno == EINTR || errno == EAGAIN { return bytes }
        return bytes
    }
}

/// Foundation `Process.deinit` calls `waitUntilExit`. A helper stuck in
/// disk I/O after SIGKILL must stay referenced so that deinit cannot block
/// the caller. The array lives in a class: a mutable static is not
/// concurrency-safe, and `Process` is not `Sendable`, so a lock around a
/// `static var` does not satisfy Swift 6.
private final class ParkedToolProcesses: Sendable {
    private let box = Mutex<[Process]>([])

    func park(_ process: Process) {
        box.withLock { $0.append(process) }
    }
}

private enum UnreapedToolProcesses {
    private static let parked = ParkedToolProcesses()

    static func park(_ process: Process) {
        parked.park(process)
    }
}
#endif
