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
///
/// Publish is resumable after a clock-stopped partial pass. A name an
/// earlier pass already removed stays removed (`.leave` off-volume, and
/// a saved-missing name on-volume is created fresh, touching no existing
/// inode). A name an earlier pass already created (no snapshot stamp,
/// saved inode present with no alias) is updated in place; `updateSaved`
/// re-verifies that live stamp at write time. An aliased saved inode
/// (link count above one for a file or symlink) still rejects.
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
        case (_, nil):
            return .create
        case (nil, let live?)
            where live.kind == .directory || live.linkCount == 1:
            return .update
        default:
            return .reject
        }
    }
    switch (snapshot, saved) {
    case (let captured?, let live?)
        where workspaceInodeAcceptableForPublish(captured: captured, live: live):
        return .remove
    case (_, nil), (nil, .some):
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
/// the reader's `fstat`/`openat` runs. The path walkers (`savedParent`,
/// `volumeParent`) therefore dup under the lock and work on their own fd.
/// Other bare-number readers must be externally serialized against
/// close/detach. Today that holds: launch reads under the supervisor state
/// lock that close also takes, and `heldDescriptors`/`savedFileData` have
/// no production callers outside that discipline.
private struct BoundaryMutable: Sendable {
    var volumeFD: Int32
    var savedFD: Int32
    var released = false
    var didDetach = false
    /// Set when a saved file was truncated and the backup restore did not
    /// finish. `restoreOriginalDirectory` must not rename that tree onto
    /// the workspace.
    var blockWorkspaceRename = false
    var publishOutcome: WorkspacePublishOutcome = .notRun
    /// Where a content-policy rejection moved the volume's disk image
    /// instead of unlinking it. Nil for every other outcome.
    var retainedRejectedImage: String?
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
    let savedPath: String
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
        guard let status = fstatWithinCopyClock(fd) else { return false }
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
        return diskImageReadFDToEndWithinCopyClock(fd)
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
        // and scrubbed paths cannot drift apart. Each unlink runs off the
        // caller. A stopped call is not a missing path, and it does not
        // start the next removal on this thread.
        for relative in AgentHomeStaging.credentialLinks.map(\.relative) {
            guard snapshot[relative] == nil else { continue }
            let path = "\(workspacePath)/\(relative)"
            if scrubStagedSymlink(path) == .stopped { return }
        }
        guard snapshot[AgentHomeStaging.cageDirectoryName] == nil else { return }
        _ = scrubRemoveTree("\(workspacePath)/\(AgentHomeStaging.cageDirectoryName)")
    }

    private enum ScrubStep {
        case done
        case stopped
    }

    /// Removes `path` only when a finished `lstat` says it is a symlink.
    private func scrubStagedSymlink(_ path: String) -> ScrubStep {
        switch diskImageObservePath(path) {
        case .stopped:
            return .stopped
        case .missing:
            return .done
        case .value(let snapshot):
            guard (snapshot.mode & S_IFMT) == S_IFLNK else { return .done }
            return unlinkPathObservingClock(path)
        }
    }

    /// Best-effort removal of a staged tree. A clock stop returns `.stopped`
    /// and leaves the rest. A finished failure is ignored by the caller,
    /// matching the previous `try?` removal.
    private func scrubRemoveTree(_ path: String) -> ScrubStep {
        switch diskImageObservePath(path) {
        case .stopped:
            return .stopped
        case .missing:
            return .done
        case .value(let snapshot):
            let kind = snapshot.mode & S_IFMT
            guard kind == S_IFDIR else { return unlinkPathObservingClock(path) }
            guard let names = readDirectoryNamesStoppingForDetachReserve(
                path,
                mayContinue: { cancelClockAllowsTreeCopy() }
            ) else {
                return .stopped
            }
            for name in names {
                if scrubRemoveTree(path + "/" + name) == .stopped { return .stopped }
            }
            return rmdirPathObservingClock(path)
        }
    }

    private func unlinkPathObservingClock(_ path: String) -> ScrubStep {
        let ok = diskImagePerformWithinCopyClock {
            path.withCString { unlink($0) == 0 }
        }
        if ok == nil { return .stopped }
        return .done
    }

    private func rmdirPathObservingClock(_ path: String) -> ScrubStep {
        let ok = diskImagePerformWithinCopyClock {
            path.withCString { rmdir($0) == 0 }
        }
        if ok == nil { return .stopped }
        return .done
    }

    /// Copy volume contents onto the original inodes, then put that directory
    /// back at the workspace path and release the volume.
    func publishAndRestore() -> Result<Void, IsolationApplyError> {
        scrubHostStagedAgentHomes()
        var wrote = false
        var rejected = false
        let published: Result<Void, IsolationApplyError>
        if remainsEstablished() {
            published = publishIntoSaved(writing: true, wrote: &wrote, rejected: &rejected)
        } else {
            published = .failure(.workspaceInodeBoundaryFailed)
        }
        // A symlink-policy rejection wrote nothing, so the volume is the only
        // copy of the agent's work: keep its image instead of unlinking it.
        // Tamper, inode, and unreadable rejections keep the discard.
        let restored = restoreOriginalDirectory(
            retainingImage: rejected && publishOutcome.isContentPolicyRejection
        )
        // The copy budget is already the detach reserve. Publish did not
        // write and did not reject, and the original directory is back.
        // The volume's unpublished names are gone with it. That is a
        // finished cancel, not a boundary failure. A real reject still fails.
        let cancelledWithoutWrite = blockingWorkIsCancelled()
            && wrote == false
            && rejected == false
            && cancelClockAllowsTreeCopy() == false
            && mutable.withLock { $0.blockWorkspaceRename } == false
        switch (published, restored) {
        case (.success, .success):
            return .success(())
        case (.failure, .success) where cancelledWithoutWrite:
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
        var wrote = false
        var rejected = false
        return publishIntoSaved(writing: false, wrote: &wrote, rejected: &rejected)
    }

    /// Copy the volume onto the hidden original. Does not unmount.
    func publishPreservingMount() -> Result<Void, IsolationApplyError> {
        scrubHostStagedAgentHomes()
        var wrote = false
        var rejected = false
        return publishIntoSaved(writing: true, wrote: &wrote, rejected: &rejected)
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
        let detached = detachVolume()
        switch observedDevice(workspacePath, afterDetach: true) {
        case .device(let device) where device == volumeDevice:
            return .failure(.workspaceInodeBoundaryFailed)
        case .stopped:
            return .failure(.workspaceInodeBoundaryFailed)
        case .device, .missing:
            break
        }
        // A changed device proves only the unmount. Without a detach
        // that exited 0 the disk stays attached, and marking cleanup
        // complete would let file cleanup unlink its image.
        guard detached else { return .failure(.workspaceInodeBoundaryFailed) }
        mutable.withLock { $0.didDetach = true }
        return .success(())
    }

    private func mountedIdentityMatches() -> Bool {
        guard case let .device(device) = observedDevice(workspacePath), device == volumeDevice else {
            return false
        }
        guard let facts = workspaceMountFacts(workspacePath), facts.source == mountSource else {
            return false
        }
        return true
    }

    /// Drop the volume without copying. The original directory returns unchanged.
    func discardAndRestore() -> Result<Void, IsolationApplyError> {
        restoreOriginalDirectory()
    }

    private func publishIntoSaved(
        writing: Bool,
        wrote: inout Bool,
        rejected: inout Bool
    ) -> Result<Void, IsolationApplyError> {
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
        // Every entry is validated before anything is written, so one
        // rejected name leaves the saved tree untouched.
        switch planPublish(volumeEntries) {
        case .stopped:
            return .failure(.workspaceInodeBoundaryFailed)
        case .rejected(let rejections):
            rejected = true
            mutable.withLock { $0.publishOutcome = .rejected(rejections) }
            return .failure(.workspaceInodeBoundaryFailed)
        case .planned(let steps):
            guard writing else { return .success(()) }
            return commitPublish(steps, wrote: &wrote, rejected: &rejected)
        }
    }

    private func restoreOriginalDirectory(
        retainingImage: Bool = false
    ) -> Result<Void, IsolationApplyError> {
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
        switch observedDevice(workspacePath, afterDetach: true) {
        case .device(let device) where device == volumeDevice:
            // The mount is still here. Do not delete it by path: that would
            // operate on the volume, and a forced replacement could be a
            // different tree. Leave both directories and fail closed.
            return .failure(.workspaceInodeBoundaryFailed)
        case .stopped:
            // A stopped stat is not proof the mount is gone.
            return .failure(.workspaceInodeBoundaryFailed)
        case .device, .missing:
            break
        }
        switch diskImagePathExistsWithinCancelClock(workspacePath) {
        case nil:
            return .failure(.workspaceInodeBoundaryFailed)
        case true:
            switch diskImagePathExistsWithinCancelClock(quarantinePath) {
            case nil, true:
                return .failure(.workspaceInodeBoundaryFailed)
            case false:
                guard renamePath(workspacePath, quarantinePath) else {
                    return .failure(.workspaceInodeBoundaryFailed)
                }
            }
        case false:
            break
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
            if retainingImage {
                switch retainRejectedImage(imagePath) {
                case .retained(let path):
                    mutable.withLock { $0.retainedRejectedImage = path }
                case .stopped:
                    return .failure(.workspaceInodeBoundaryFailed)
                case .left:
                    // Every rename failed. The image stays where it is;
                    // retention never falls back to unlinking the work.
                    break
                }
            } else if diskImageUnlinkWithinCancelClock(imagePath) == nil {
                // A stopped unlink is not the image being gone.
                return .failure(.workspaceInodeBoundaryFailed)
            }
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

    /// A clock-stopped saved-tree mutation can still land from its parked
    /// worker after this tree is renamed onto the workspace. Nil fences
    /// that rename; Recovery reattaches with a fresh boundary and resumes.
    private func savedMutation(_ result: Bool?) -> Bool {
        if result == nil {
            mutable.withLock { $0.blockWorkspaceRename = true }
            return false
        }
        return result == true
    }

    // MARK: Transactional publish

    /// One planned mutation of the saved tree. Steps run in this order:
    /// new directories, staged new files, in-place updates, installs of
    /// staged files and new symlinks, retirement of removed names, then
    /// directory modes deepest first. A directory therefore stays writable
    /// while its children change.
    private enum PublishStep {
        case makeDirectory(String)
        case stageFile(String, mode_t)
        case updateFile(String, mode_t)
        case replaceSymlink(String, target: String)
        case installFile(String)
        case createSymlink(String, target: String)
        case retire(String)
        case setDirectoryMode(String, mode_t)

        var relative: String {
            switch self {
            case .makeDirectory(let relative), .stageFile(let relative, _),
                .updateFile(let relative, _), .replaceSymlink(let relative, _),
                .installFile(let relative), .createSymlink(let relative, _),
                .retire(let relative), .setDirectoryMode(let relative, _):
                return relative
            }
        }
    }

    /// How to put one applied step back. Each undo re-verifies the inode it
    /// touches before it mutates anything.
    private enum PublishUndo {
        case removeEmptyDirectory(String)
        case discardStage(String)
        case restoreFile(String, backup: String, mode: mode_t, stamp: WorkspaceInodeStamp)
        case restoreMode(String, mode: mode_t, stamp: WorkspaceInodeStamp)
        case restoreSymlink(String, target: String)
        case removeCreated(String, WorkspaceInodeStamp)
        case removeLink(String, target: String)
        case unretire(String, retired: String)

        var relative: String {
            switch self {
            case .removeEmptyDirectory(let relative), .discardStage(let relative),
                .restoreFile(let relative, _, _, _), .restoreMode(let relative, _, _),
                .restoreSymlink(let relative, _), .removeCreated(let relative, _),
                .removeLink(let relative, _), .unretire(let relative, _):
                return relative
            }
        }
    }

    private enum PublishPlan {
        case planned([PublishStep])
        case rejected([WorkspacePublishRejection])
        case stopped
    }

    private struct PublishJournal {
        var undo: [PublishUndo] = []
        var rollbackReady = false
    }

    /// What the last publish left in the saved tree.
    /// Path of the detached disk image kept after a symlink-policy rejection,
    /// holding every edit the agent made. Nil when no image was retained.
    var retainedRejectedImagePath: String? {
        mutable.withLock { $0.retainedRejectedImage }
    }

    var publishOutcome: WorkspacePublishOutcome {
        mutable.withLock { $0.publishOutcome }
    }

    /// Host directory beside the saved tree that holds removed names until
    /// the publish commits. Deterministic, so a resumed publish purges it.
    private var rollbackPath: String {
        let parent = (savedPath as NSString).deletingLastPathComponent
        let name = (savedPath as NSString).lastPathComponent
        let token = name.hasPrefix(".rv-saved-") ? String(name.dropFirst(".rv-saved-".count)) : name
        return (parent as NSString).appendingPathComponent(".rv-rollback-\(token)")
    }

    /// Decide every name without writing. Inode checks, kind checks, the
    /// symlink policy, and the removed-subtree check all run here.
    private func planPublish(_ volumeEntries: [String: TreeEntry]) -> PublishPlan {
        var rejections: [WorkspacePublishRejection] = []
        func reject(_ relative: String, _ reason: WorkspacePublishRejection.Reason) {
            rejections.append(WorkspacePublishRejection(relative: relative, reason: reason))
        }
        var links: [String: String] = [:]
        for (relative, entry) in volumeEntries where entry.kind == .symlink {
            if cancelClockAllowsTreeCopy() == false { return .stopped }
            guard let target = readVolumeLink(relative) else {
                reject(relative, .unreadable)
                continue
            }
            links[relative] = target
        }
        let linkTable = WorkspaceLinkTable(links)
        var makes: [PublishStep] = []
        var stages: [PublishStep] = []
        var updates: [PublishStep] = []
        var installs: [PublishStep] = []
        var modes: [PublishStep] = []
        let present = volumeEntries.keys.sorted { (pathDepth($0), $0) < (pathDepth($1), $1) }
        for relative in present {
            if cancelClockAllowsTreeCopy() == false { return .stopped }
            guard let entry = volumeEntries[relative] else { continue }
            let saved = savedStamp(relative)
            switch workspacePublishDecision(snapshot: snapshot[relative], saved: saved, onVolume: true) {
            case .update:
                guard let saved, saved.kind == entry.kind else {
                    reject(relative, .kindChanged)
                    continue
                }
                switch entry.kind {
                case .directory:
                    modes.append(.setDirectoryMode(relative, entry.mode))
                case .regular:
                    updates.append(.updateFile(relative, entry.mode))
                case .symlink:
                    guard let target = links[relative] else { continue }
                    guard let current = readSavedLink(relative) else {
                        reject(relative, .unreadable)
                        continue
                    }
                    // An untouched link is not rewritten, so a link the
                    // project already had is never judged by the policy.
                    if current == target { continue }
                    guard workspaceSymlinkTargetStaysInside(link: relative, target: target, links: linkTable) else {
                        reject(relative, .symlinkEscapesWorkspace)
                        continue
                    }
                    updates.append(.replaceSymlink(relative, target: target))
                }
            case .create:
                switch entry.kind {
                case .directory:
                    makes.append(.makeDirectory(relative))
                    modes.append(.setDirectoryMode(relative, entry.mode))
                case .regular:
                    guard stageNameIsFree(relative, volumeEntries) else {
                        reject(relative, .unreadable)
                        continue
                    }
                    stages.append(.stageFile(relative, entry.mode))
                    installs.append(.installFile(relative))
                case .symlink:
                    guard let target = links[relative] else { continue }
                    guard workspaceSymlinkTargetStaysInside(link: relative, target: target, links: linkTable) else {
                        reject(relative, .symlinkEscapesWorkspace)
                        continue
                    }
                    installs.append(.createSymlink(relative, target: target))
                }
            case .remove, .leave, .reject:
                reject(relative, .inodeChanged)
            }
        }
        var removed = Set<String>()
        for relative in snapshot.keys.sorted() where volumeEntries[relative] == nil {
            if cancelClockAllowsTreeCopy() == false { return .stopped }
            switch workspacePublishDecision(
                snapshot: snapshot[relative],
                saved: savedStamp(relative),
                onVolume: false
            ) {
            case .remove:
                removed.insert(relative)
            case .leave:
                break
            case .update, .create, .reject:
                reject(relative, .inodeChanged)
            }
        }
        var retires: [PublishStep] = []
        for relative in removed.sorted() where removed.contains(parentRelative(relative)) == false {
            if snapshot[relative]?.kind == .directory {
                switch removedSubtreeIsOwned(relative, removed: removed) {
                case nil:
                    if cancelClockAllowsTreeCopy() == false { return .stopped }
                    reject(relative, .unreadable)
                    continue
                case false:
                    reject(relative, .unexpectedNameInRemovedDirectory)
                    continue
                case true:
                    break
                }
            }
            retires.append(.retire(relative))
        }
        guard rejections.isEmpty else {
            return .rejected(rejections.sorted { $0.relative < $1.relative })
        }
        return .planned(makes + stages + updates + installs + retires + modes.reversed())
    }

    private func parentRelative(_ relative: String) -> String {
        (relative as NSString).deletingLastPathComponent
    }

    private func stageNameIsFree(_ relative: String, _ volumeEntries: [String: TreeEntry]) -> Bool {
        let parent = parentRelative(relative)
        let stage = workspacePublishStageName(for: (relative as NSString).lastPathComponent)
        let staged = parent.isEmpty ? stage : parent + "/" + stage
        return snapshot[staged] == nil && volumeEntries[staged] == nil
    }

    /// Whether every saved name under a removed directory is itself a
    /// removed snapshot name. Nil when the subtree could not be read.
    private func removedSubtreeIsOwned(_ relative: String, removed: Set<String>) -> Bool? {
        guard let fd = openSaved(relative, directory: true) else { return nil }
        defer { close(fd) }
        guard let entries = collectTree(root: fd, checkDevice: savedDevice) else { return nil }
        return entries.keys.allSatisfy { removed.contains(relative + "/" + $0) }
    }

    private func readSavedLink(_ relative: String) -> String? {
        guard let parent = savedParent(relative) else { return nil }
        defer { close(parent.fd) }
        return readlinkWithinCopyClock(parent.fd, parent.name)
    }

    /// Apply every planned step. A finished failure undoes the applied
    /// steps in reverse. A clock stop leaves them for the resumable publish
    /// and fences the workspace rename so a partial tree never lands.
    private func commitPublish(
        _ steps: [PublishStep],
        wrote: inout Bool,
        rejected: inout Bool
    ) -> Result<Void, IsolationApplyError> {
        // A stale rollback directory is from an interrupted earlier pass of
        // this same publish. Resuming forward means its names stay removed.
        switch diskImagePathExistsWithinCancelClock(rollbackPath) {
        case nil:
            return .failure(.workspaceInodeBoundaryFailed)
        case true:
            guard inodeCheckedDelete(rollbackPath) else {
                rejected = true
                mutable.withLock {
                    $0.publishOutcome = .rejected([
                        WorkspacePublishRejection(relative: rollbackPath, reason: .unreadable),
                    ])
                }
                return .failure(.workspaceInodeBoundaryFailed)
            }
        case false:
            break
        }
        var journal = PublishJournal()
        var failedAt: String?
        for (index, step) in steps.enumerated() {
            if cancelClockAllowsTreeCopy() == false || mutable.withLock({ $0.blockWorkspaceRename }) {
                failedAt = step.relative
                break
            }
            if let fault = WorkspacePublishFaults.commitFault, fault(index, step.relative) {
                failedAt = step.relative
                break
            }
            wrote = true
            let applied = apply(step, index: index, journal: &journal)
            journal.undo.append(contentsOf: applied.undo)
            if applied.ok == false {
                failedAt = step.relative
                break
            }
        }
        guard let failedAt else {
            let leftovers = finishPublish(journal)
            mutable.withLock { $0.publishOutcome = .committed(leftovers: leftovers) }
            return .success(())
        }
        if cancelClockAllowsTreeCopy() == false || mutable.withLock({ $0.blockWorkspaceRename }) {
            if wrote { mutable.withLock { $0.blockWorkspaceRename = true } }
            mutable.withLock { $0.publishOutcome = .interrupted(at: failedAt) }
            return .failure(.workspaceInodeBoundaryFailed)
        }
        rejected = true
        let unrestored = rollBack(journal)
        mutable.withLock {
            $0.publishOutcome = unrestored.isEmpty
                ? .rolledBack(failedAt: failedAt)
                : .residual(failedAt: failedAt, unrestored: unrestored)
        }
        return .failure(.workspaceInodeBoundaryFailed)
    }

    /// Delete rollback material after a commit. Returns host paths that
    /// could not be deleted.
    private func finishPublish(_ journal: PublishJournal) -> [String] {
        var leftovers: [String] = []
        for case .restoreFile(_, let backup, _, _) in journal.undo
        where diskImageUnlinkWithinCopyClock(backup) != true {
            leftovers.append(backup)
        }
        if journal.rollbackReady, inodeCheckedDelete(rollbackPath) == false {
            leftovers.append(rollbackPath)
        }
        return leftovers
    }

    /// Undo in reverse. Returns the saved names that could not be put back;
    /// their backups (and the rollback directory) are kept.
    private func rollBack(_ journal: PublishJournal) -> [String] {
        var unrestored: [String] = []
        for undo in journal.undo.reversed() {
            if undoStep(undo) {
                if case .restoreFile(_, let backup, _, _) = undo {
                    _ = diskImageUnlinkWithinCopyClock(backup)
                }
            } else {
                unrestored.append(undo.relative)
            }
        }
        if journal.rollbackReady, unrestored.isEmpty {
            _ = diskImageRmdirWithinCopyClock(rollbackPath)
        }
        return unrestored
    }

    private typealias StepResult = (ok: Bool, undo: [PublishUndo])

    private func apply(_ step: PublishStep, index: Int, journal: inout PublishJournal) -> StepResult {
        switch step {
        case .makeDirectory(let relative):
            guard let parent = savedParent(relative) else { return (false, []) }
            defer { close(parent.fd) }
            // Owner-writable until the final mode step, so children land.
            guard savedMutation(mkdiratWithinCopyClock(parent.fd, parent.name, 0o700)) else {
                return (false, [])
            }
            return (true, [.removeEmptyDirectory(relative)])
        case .stageFile(let relative, let mode):
            return stageNewFile(relative, mode: mode)
        case .updateFile(let relative, let mode):
            return updateSavedFile(relative, mode: mode)
        case .replaceSymlink(let relative, let target):
            return replaceSavedSymlink(relative, target: target)
        case .installFile(let relative):
            return installStagedFile(relative)
        case .createSymlink(let relative, let target):
            guard let parent = savedParent(relative) else { return (false, []) }
            defer { close(parent.fd) }
            guard savedMutation(symlinkWithinCopyClock(parent.fd, parent.name, target)) else {
                return (false, [])
            }
            return (true, [.removeLink(relative, target: target)])
        case .retire(let relative):
            return retireSaved(relative, index: index, journal: &journal)
        case .setDirectoryMode(let relative, let mode):
            guard let fd = openSaved(relative, directory: true) else { return (false, []) }
            defer { close(fd) }
            guard let status = fstatWithinCopyClock(fd), let live = stamp(of: status) else {
                return (false, [])
            }
            if let captured = snapshot[relative], acceptableSavedInode(captured, status) == false {
                return (false, [])
            }
            let old = modeBits(status.st_mode)
            if old == mode { return (true, []) }
            return (
                savedMutation(fchmodWithinCopyClock(fd, mode)),
                [.restoreMode(relative, mode: old, stamp: live)]
            )
        }
    }

    /// Write a new file under its staging name in the destination's
    /// directory. A stale stage from an interrupted pass is replaced.
    private func stageNewFile(_ relative: String, mode: mode_t) -> StepResult {
        guard let parent = savedParent(relative) else { return (false, []) }
        defer { close(parent.fd) }
        let stage = workspacePublishStageName(for: parent.name)
        switch fstatatObservingCopyClock(parent.fd, stage) {
        case .stopped:
            return (false, [])
        case .failed:
            break
        case .value(let status):
            guard kind(of: status.st_mode) == .regular, status.st_nlink == 1,
                savedMutation(unlinkatWithinCopyClock(parent.fd, stage, 0))
            else { return (false, []) }
        }
        let opened = openatOutcomeWithinCopyClock(
            parent.fd,
            stage,
            O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_WRONLY,
            mode
        )
        // A parked O_CREAT can still create the stage after the saved
        // tree is renamed onto the workspace. Fence it.
        if opened.stopped {
            mutable.withLock { $0.blockWorkspaceRename = true }
            return (false, [])
        }
        guard opened.fd >= 0 else { return (false, []) }
        let dest = opened.fd
        defer { close(dest) }
        let undo: [PublishUndo] = [.discardStage(relative)]
        guard let source = openVolume(relative, directory: false) else { return (false, undo) }
        defer { close(source) }
        let copied = copyFileDataOutcomeObservingCancelClock(from: source, to: dest)
        guard copied == .finished else {
            // A parked write still holds a duplicate of `dest`.
            if copied == .stopped {
                mutable.withLock { $0.blockWorkspaceRename = true }
            }
            return (false, undo)
        }
        return (true, undo)
    }

    /// Rename a finished stage onto its name. `RENAME_EXCL` never replaces
    /// an inode that appeared at that name.
    private func installStagedFile(_ relative: String) -> StepResult {
        guard let parent = savedParent(relative) else { return (false, []) }
        defer { close(parent.fd) }
        let stage = workspacePublishStageName(for: parent.name)
        guard let staged = fstatatWithinCopyClock(parent.fd, stage), let stamp = stamp(of: staged) else {
            return (false, [])
        }
        let name = parent.name
        let renamed = renameatWithinCopyClock(parent.fd) { fd in
            stage.withCString { from in
                name.withCString { to in renameatx_np(fd, from, fd, to, UInt32(RENAME_EXCL)) }
            }
        }
        guard savedMutation(renamed) else { return (false, []) }
        return (true, [.removeCreated(relative, stamp)])
    }

    /// Move a removed name into the rollback directory. The captured inode
    /// is re-verified first; the move keeps it intact for undo.
    private func retireSaved(_ relative: String, index: Int, journal: inout PublishJournal) -> StepResult {
        guard let captured = snapshot[relative] else { return (false, []) }
        if journal.rollbackReady == false {
            guard savedMutation(diskImageMkdirWithinCopyClock(rollbackPath, 0o700)) else {
                return (false, [])
            }
            journal.rollbackReady = true
        }
        guard let parent = savedParent(relative) else { return (false, []) }
        defer { close(parent.fd) }
        guard let status = fstatatWithinCopyClock(parent.fd, parent.name),
            acceptableSavedInode(captured, status)
        else { return (false, []) }
        let retired = String(index)
        let destination = (rollbackPath as NSString).appendingPathComponent(retired)
        let name = parent.name
        let renamed = renameatWithinCopyClock(parent.fd) { fd in
            name.withCString { from in
                destination.withCString { to in
                    renameatx_np(fd, from, AT_FDCWD, to, UInt32(RENAME_EXCL))
                }
            }
        }
        guard savedMutation(renamed) else { return (false, []) }
        return (true, [.unretire(relative, retired: retired)])
    }

    private func replaceSavedSymlink(_ relative: String, target: String) -> StepResult {
        guard let captured = snapshot[relative] ?? savedStamp(relative) else { return (false, []) }
        guard let parent = savedParent(relative) else { return (false, []) }
        defer { close(parent.fd) }
        guard let status = fstatatWithinCopyClock(parent.fd, parent.name),
            acceptableSavedInode(captured, status),
            let old = readlinkWithinCopyClock(parent.fd, parent.name)
        else { return (false, []) }
        guard savedMutation(unlinkatWithinCopyClock(parent.fd, parent.name, 0)) else { return (false, []) }
        let undo: [PublishUndo] = [.restoreSymlink(relative, target: old)]
        return (savedMutation(symlinkWithinCopyClock(parent.fd, parent.name, target)), undo)
    }

    /// Copy a volume file onto its captured saved inode. The pre-commit
    /// bytes are retained until the whole publish commits.
    private func updateSavedFile(_ relative: String, mode: mode_t) -> StepResult {
        // A resumed create has no snapshot stamp. Its authority is the
        // live saved stamp, re-verified against the opened inode below.
        guard let captured = snapshot[relative] ?? savedStamp(relative) else { return (false, []) }
        guard let source = openVolume(relative, directory: false), source >= 0 else { return (false, []) }
        defer { close(source) }
        guard let dest = openSaved(relative, directory: false, writable: true), dest >= 0 else {
            return updateReadOnlySaved(relative, from: source, captured: captured, mode: mode)
        }
        defer { close(dest) }
        guard let status = fstatWithinCopyClock(dest), acceptableSavedInode(captured, status),
            let live = stamp(of: status)
        else {
            return (false, [])
        }
        let oldMode = modeBits(status.st_mode)
        let outcome = replaceOriginalOnlyAfterStagedCopy(
            source: source,
            original: dest,
            originalPath: (savedPath as NSString).appendingPathComponent(relative),
            retainBackup: true,
            mayContinue: publishCopyMayContinue,
            copyXattr: copyExtendedAttributes
        )
        if outcome.reachedTruncate && outcome.mayRenameOntoWorkspace == false {
            mutable.withLock { $0.blockWorkspaceRename = true }
        }
        guard outcome.committed, let backup = outcome.retainedBackup else { return (false, []) }
        let undo: [PublishUndo] = [.restoreFile(relative, backup: backup, mode: oldMode, stamp: live)]
        return (savedMutation(fchmodWithinCopyClock(dest, mode)), undo)
    }

    /// Copy back onto a saved file that refuses `O_RDWR`, such as the mode-444
    /// files dependency managers ship. Untouched content needs no write at
    /// all; edited content takes a momentary owner-write bit that the final
    /// chmod restores, so the mode survives the round trip. The inode is
    /// never replaced, and every open re-verifies the captured identity, so
    /// the authority check keeps its meaning.
    private func updateReadOnlySaved(
        _ relative: String,
        from source: Int32,
        captured: WorkspaceInodeStamp,
        mode: mode_t
    ) -> StepResult {
        guard let parent = savedParent(relative) else { return (false, []) }
        defer { close(parent.fd) }
        let readOnly = openatWithinCopyClock(
            parent.fd,
            parent.name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard readOnly >= 0 else { return (false, []) }
        defer { close(readOnly) }
        guard let status = fstatWithinCopyClock(readOnly), acceptableSavedInode(captured, status),
            let live = stamp(of: status)
        else {
            return (false, [])
        }
        let oldMode = modeBits(status.st_mode)
        let restoreMode: [PublishUndo] = [.restoreMode(relative, mode: oldMode, stamp: live)]
        guard let same = savedContentsEqual(source, readOnly) else { return (false, []) }
        if same {
            if oldMode == mode { return (true, []) }
            return (savedMutation(fchmodWithinCopyClock(readOnly, mode)), restoreMode)
        }
        guard savedMutation(fchmodWithinCopyClock(readOnly, oldMode | 0o200)) else {
            return (false, restoreMode)
        }
        let dest = openatWithinCopyClock(
            parent.fd,
            parent.name,
            O_RDWR | O_NOFOLLOW | O_CLOEXEC
        )
        guard dest >= 0 else { return (false, restoreMode) }
        defer { close(dest) }
        guard let fresh = fstatWithinCopyClock(dest), acceptableSavedInode(captured, fresh) else {
            return (false, restoreMode)
        }
        guard lseek(source, 0, SEEK_SET) == 0 else { return (false, restoreMode) }
        let outcome = replaceOriginalOnlyAfterStagedCopy(
            source: source,
            original: dest,
            originalPath: (savedPath as NSString).appendingPathComponent(relative),
            retainBackup: true,
            mayContinue: publishCopyMayContinue,
            copyXattr: copyExtendedAttributes
        )
        if outcome.reachedTruncate && outcome.mayRenameOntoWorkspace == false {
            mutable.withLock { $0.blockWorkspaceRename = true }
        }
        guard outcome.committed, let backup = outcome.retainedBackup else { return (false, restoreMode) }
        let undo: [PublishUndo] = [.restoreFile(relative, backup: backup, mode: oldMode, stamp: live)]
        return (savedMutation(fchmodWithinCopyClock(dest, mode)), undo)
    }

    private func undoStep(_ undo: PublishUndo) -> Bool {
        guard let parent = savedParent(undo.relative) else { return false }
        defer { close(parent.fd) }
        switch undo {
        case .removeEmptyDirectory:
            return savedMutation(unlinkatWithinCopyClock(parent.fd, parent.name, AT_REMOVEDIR))
        case .discardStage:
            let stage = workspacePublishStageName(for: parent.name)
            switch fstatatObservingCopyClock(parent.fd, stage) {
            case .stopped:
                mutable.withLock { $0.blockWorkspaceRename = true }
                return false
            case .failed:
                return true
            case .value:
                return savedMutation(unlinkatWithinCopyClock(parent.fd, stage, 0))
            }
        case .restoreFile(_, let backup, let mode, let stamp):
            return restoreSavedFile(parent: parent, backup: backup, mode: mode, stamp: stamp)
        case .restoreMode(_, let mode, let stamp):
            let fd = openatWithinCopyClock(parent.fd, parent.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            guard let status = fstatWithinCopyClock(fd), sameInode(stamp, status) else { return false }
            return savedMutation(fchmodWithinCopyClock(fd, mode))
        case .restoreSymlink(_, let target):
            if let status = fstatatWithinCopyClock(parent.fd, parent.name) {
                guard kind(of: status.st_mode) == .symlink,
                    savedMutation(unlinkatWithinCopyClock(parent.fd, parent.name, 0))
                else { return false }
            }
            return savedMutation(symlinkWithinCopyClock(parent.fd, parent.name, target))
        case .removeCreated(_, let stamp):
            guard let status = fstatatWithinCopyClock(parent.fd, parent.name), sameInode(stamp, status) else {
                return false
            }
            return savedMutation(unlinkatWithinCopyClock(parent.fd, parent.name, 0))
        case .removeLink(_, let target):
            guard readlinkWithinCopyClock(parent.fd, parent.name) == target else { return false }
            return savedMutation(unlinkatWithinCopyClock(parent.fd, parent.name, 0))
        case .unretire(_, let retired):
            let source = (rollbackPath as NSString).appendingPathComponent(retired)
            let name = parent.name
            let renamed = renameatWithinCopyClock(parent.fd) { fd in
                source.withCString { from in
                    name.withCString { to in
                        renameatx_np(AT_FDCWD, from, fd, to, UInt32(RENAME_EXCL))
                    }
                }
            }
            return savedMutation(renamed)
        }
    }

    /// Write retained pre-commit bytes back onto the same inode, then its
    /// mode. Extended attributes the publish changed are not restored.
    private func restoreSavedFile(
        parent: (fd: Int32, name: String),
        backup: String,
        mode: mode_t,
        stamp: WorkspaceInodeStamp
    ) -> Bool {
        let readOnly = openatWithinCopyClock(parent.fd, parent.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard readOnly >= 0 else { return false }
        defer { close(readOnly) }
        guard let status = fstatWithinCopyClock(readOnly), sameInode(stamp, status),
            savedMutation(fchmodWithinCopyClock(readOnly, mode | 0o600))
        else { return false }
        let dest = openatWithinCopyClock(parent.fd, parent.name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard dest >= 0 else { return false }
        defer { close(dest) }
        guard let fresh = fstatWithinCopyClock(dest), sameInode(stamp, fresh) else { return false }
        guard let opened = diskImageOpenPathWithinCopyClock(backup, O_RDONLY | O_NOFOLLOW | O_CLOEXEC),
            opened >= 0
        else { return false }
        defer { close(opened) }
        let outcome = replaceOriginalOnlyAfterStagedCopy(
            source: opened,
            original: dest,
            mayContinue: publishCopyMayContinue,
            copyXattr: { _, _ in true }
        )
        if outcome.reachedTruncate && outcome.mayRenameOntoWorkspace == false {
            mutable.withLock { $0.blockWorkspaceRename = true }
        }
        guard outcome.committed else { return false }
        return savedMutation(fchmodWithinCopyClock(dest, mode))
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
        while true {
            if directoryReadMayContinue(cancelClockAllowsTreeCopy()) == false { return -1 }
            guard let read = diskImageReadWithinCopyClock(fd, maxCount: buffer.count) else {
                return -1
            }
            if read.errnoValue == EINTR {
                if diskImageInterruptedReadMayRetry(
                    errnoValue: read.errnoValue,
                    clockAllowsAnotherCall: cancelClockAllowsTreeCopy()
                ) {
                    continue
                }
                return -1
            }
            if read.count > 0 {
                for index in 0..<read.count {
                    buffer[index] = read.bytes[index]
                }
            }
            return read.count
        }
    }

    private func savedStamp(_ relative: String) -> WorkspaceInodeStamp? {
        guard let parent = savedParent(relative) else { return nil }
        defer { close(parent.fd) }
        guard let status = fstatatWithinCopyClock(parent.fd, parent.name) else { return nil }
        return stamp(of: status)
    }

    /// Walk from the held saved directory. Refuse a symlink or an inode that
    /// is not the captured directory. `~Copyable` is unnecessary: this fd is
    /// closed by the caller, and the held root fd stays open.
    private func savedParent(_ relative: String) -> (fd: Int32, name: String)? {
        let parts = relative.split(separator: "/").map(String.init)
        guard let name = parts.last else { return nil }
        var current = mutable.withLock { dup($0.savedFD) }
        guard current >= 0 else { return nil }
        var walked = ""
        for part in parts.dropLast() {
            walked = walked.isEmpty ? part : walked + "/" + part
            let next = openatWithinCopyClock(
                current,
                part,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            close(current)
            guard next >= 0 else { return nil }
            guard let status = fstatWithinCopyClock(next) else {
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
        let fd = openatWithinCopyClock(parent.fd, parent.name, flags)
        return fd >= 0 ? fd : nil
    }

    private func openVolume(_ relative: String, directory: Bool) -> Int32? {
        guard let parent = volumeParent(relative) else { return nil }
        defer { close(parent.fd) }
        let flags = O_NOFOLLOW | O_CLOEXEC | (directory ? (O_RDONLY | O_DIRECTORY) : O_RDONLY)
        let fd = openatWithinCopyClock(parent.fd, parent.name, flags)
        return fd >= 0 ? fd : nil
    }

    private func volumeParent(_ relative: String) -> (fd: Int32, name: String)? {
        let parts = relative.split(separator: "/").map(String.init)
        guard let name = parts.last else { return nil }
        var current = mutable.withLock { dup($0.volumeFD) }
        guard current >= 0 else { return nil }
        for part in parts.dropLast() {
            let next = openatWithinCopyClock(
                current,
                part,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            close(current)
            guard next >= 0 else { return nil }
            current = next
        }
        return (current, name)
    }

    private func readVolumeLink(_ relative: String) -> String? {
        guard let parent = volumeParent(relative) else { return nil }
        defer { close(parent.fd) }
        return readlinkWithinCopyClock(parent.fd, parent.name)
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
        guard let savedOpened = diskImageOpenPathWithinCopyClock(
            identity.savedPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        ) else {
            return .failure(.workspaceInodeBoundaryFailed)
        }
        guard savedOpened >= 0 else { return .failure(.workspaceInodeBoundaryFailed) }
        let savedFD = savedOpened
        // `nil` is the copy clock. The worker may still be inside `open` of
        // the mount, so this does not close a descriptor it never received
        // and does not remove the path.
        guard let volumeOpened = diskImageOpenPathWithinCopyClock(
            project,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        ) else {
            if savedFD >= 0 { close(savedFD) }
            return .failure(.workspaceInodeBoundaryFailed)
        }
        guard savedFD >= 0, volumeOpened >= 0 else {
            if savedFD >= 0 { close(savedFD) }
            if volumeOpened >= 0 { close(volumeOpened) }
            return .failure(.workspaceInodeBoundaryFailed)
        }
        let volumeFD = volumeOpened
        guard let savedStatus = fstatWithinCopyClock(savedFD),
            let volumeStatus = fstatWithinCopyClock(volumeFD),
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
        switch diskImagePathExists(project) {
        case nil:
            return .failure(.workspaceInodeBoundaryFailed)
        case true:
            switch diskImagePathExists(identity.quarantinePath) {
            case nil, true:
                return .failure(.workspaceInodeBoundaryFailed)
            case false:
                guard renamePath(project, identity.quarantinePath) else {
                    return .failure(.workspaceInodeBoundaryFailed)
                }
            }
        case false:
            break
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
        switch diskImageObservePath(imagePath) {
        case .stopped:
            return .failure(.workspaceInodeBoundaryFailed)
        case .missing:
            return .success(())
        case .value(let snapshot):
            guard snapshot.device == imageDevice,
                snapshot.inode == imageInode,
                (snapshot.mode & S_IFMT) == S_IFREG
            else {
                return .success(())
            }
            guard diskImageUnlinkWithinCopyClock(imagePath) == true else {
                return .failure(.workspaceInodeBoundaryFailed)
            }
            return .success(())
        }
    }
}

private func orphanMarkerPath(forSaved savedPath: String) -> String {
    savedPath + ".rv-orphan"
}

/// Rename the hidden tree back onto the workspace. The `.created`
/// journal record is written only after establish succeeds, so when the
/// rename cannot be confirmed (mount still up, name occupied), record
/// where the tree belongs in a sibling marker. The next establish for
/// that workspace finds it via `recoverOrphanedSavedTree`. Both paths
/// live on the host parent filesystem, like `renamePath` itself.
func restoreSavedOrMarkOrphan(savedPath: String, workspacePath: String) {
    if renamePath(savedPath, workspacePath) { return }
    _ = FileManager.default.createFile(
        atPath: orphanMarkerPath(forSaved: savedPath),
        contents: Data((workspacePath + "\n").utf8)
    )
}

enum OrphanedSavedRecovery: Equatable, Sendable {
    case none
    case restored
    case blocked
}

/// Find a `.rv-saved-*` sibling whose orphan marker names this
/// workspace and put it back. Blocked when the marker is ambiguous, the
/// workspace name now holds a non-empty directory (never clobber), or the
/// parent cannot be listed: an orphan that cannot be ruled out fails closed.
func recoverOrphanedSavedTree(at workspacePath: String) -> OrphanedSavedRecovery {
    let parent = (workspacePath as NSString).deletingLastPathComponent
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent) else {
        return .blocked
    }
    var matches: [String] = []
    for name in names where name.hasPrefix(".rv-saved-") {
        let savedPath = (parent as NSString).appendingPathComponent(name)
        guard let text = try? String(
            contentsOfFile: orphanMarkerPath(forSaved: savedPath),
            encoding: .utf8
        ) else { continue }
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == workspacePath {
            matches.append(savedPath)
        }
    }
    guard let savedPath = matches.first else { return .none }
    guard matches.count == 1 else { return .blocked }
    var occupied = ObjCBool(false)
    if FileManager.default.fileExists(atPath: workspacePath, isDirectory: &occupied) {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: workspacePath)) ?? []
        guard occupied.boolValue, entries.isEmpty else { return .blocked }
    }
    guard renamePath(savedPath, workspacePath) else { return .blocked }
    try? FileManager.default.removeItem(atPath: orphanMarkerPath(forSaved: savedPath))
    return .restored
}

#endif
