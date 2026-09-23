#if os(macOS)
import Darwin
import Foundation

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
final class WorkspaceInodeBoundary {
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
    private var volumeFD: Int32
    private var savedFD: Int32
    private let snapshot: [String: WorkspaceInodeStamp]
    private var released = false
    private var didDetach = false

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
        self.volumeFD = volumeFD
        self.savedFD = savedFD
        self.snapshot = snapshot
    }

    deinit {
        if volumeFD >= 0 { close(volumeFD) }
        if savedFD >= 0 { close(savedFD) }
    }

    func remainsEstablished() -> Bool {
        guard volumeFD >= 0 else { return false }
        var status = stat()
        guard fstat(volumeFD, &status) == 0 else { return false }
        return device(of: status) == volumeDevice
    }

    var volumeDeviceIdentifier: UInt64 { volumeDevice }
    var diskIdentifier: String { disk }
    var isReleased: Bool { released }

    /// Directory descriptors RV holds for the mount and the hidden original.
    /// Callers compare these identities with a child's open files.
    func heldDescriptors() -> [Int32] {
        [volumeFD, savedFD].filter { $0 >= 0 }
    }

    /// Move the mount and saved directory descriptors above the granted
    /// stdio and admission slots so a later `dup2` onto 0...5 cannot publish
    /// them into a runtime.
    func relocateHeldDescriptors(atLeast floor: Int32) -> Bool {
        moveDescriptor(&volumeFD, floor) && moveDescriptor(&savedFD, floor)
    }

    /// Bytes of one file in the hidden original tree. Nil when that name is
    /// not there. This does not read the mounted volume.
    func savedFileData(_ relative: String) -> Data? {
        guard released == false, let fd = openSaved(relative, directory: false), fd >= 0 else {
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

    private func moveDescriptor(_ fd: inout Int32, _ floor: Int32) -> Bool {
        guard fd >= 0 else { return false }
        if fd >= floor { return true }
        let moved = fcntl(fd, F_DUPFD_CLOEXEC, floor)
        guard moved >= 0 else { return false }
        close(fd)
        fd = moved
        return true
    }

    /// Copy volume contents onto the original inodes, then put that directory
    /// back at the workspace path and release the volume.
    func publishAndRestore() -> Result<Void, IsolationApplyError> {
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
        publishIntoSaved(writing: true)
    }

    /// Detach this volume only when the mount source and device still match.
    func detachOwnedMount() -> Result<Void, IsolationApplyError> {
        if released || didDetach { return .success(()) }
        guard mountedIdentityMatches() else { return .failure(.workspaceInodeBoundaryFailed) }
        if volumeFD >= 0 {
            close(volumeFD)
            volumeFD = -1
        }
        detachVolume()
        if currentDevice(workspacePath) == volumeDevice {
            return .failure(.workspaceInodeBoundaryFailed)
        }
        didDetach = true
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
        guard remainsEstablished(), savedFD >= 0 else {
            return .failure(.workspaceInodeBoundaryFailed)
        }
        guard let volumeEntries = collectTree(root: volumeFD, checkDevice: volumeDevice) else {
            return .failure(.workspaceInodeBoundaryFailed)
        }
        var rejected = false
        let present = volumeEntries.keys.sorted { pathDepth($0) < pathDepth($1) }
        for relative in present {
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
        if released { return .success(()) }
        if volumeFD >= 0 {
            close(volumeFD)
            volumeFD = -1
        }
        detachVolume()
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
        if savedFD >= 0 {
            close(savedFD)
            savedFD = -1
        }
        released = true
        _ = inodeCheckedDelete(quarantinePath)
        if let imagePath {
            unlink(imagePath)
        }
        return .success(())
    }

    private func detachVolume() {
        for _ in 0..<25 {
            let result = runTool([
                "/usr/bin/hdiutil", "detach", "-force", "-quiet", disk,
            ])
            if result.status == 0 { return }
            usleep(40_000)
        }
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
                return false
            }
            defer { close(dest) }
            var status = stat()
            guard fstat(dest, &status) == 0, acceptableSavedInode(captured, status) else { return false }
            guard ftruncate(dest, 0) == 0 else { return false }
            guard fcopyfile(source, dest, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_XATTR)) == 0
            else { return false }
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
            guard let source = openVolume(relative, directory: false), source >= 0 else { return false }
            defer { close(source) }
            return fcopyfile(source, dest, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_XATTR)) == 0
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
        var current = dup(savedFD)
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
        var current = dup(volumeFD)
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
    if Task.isCancelled || CooperativeLaunchStop.isRequested {
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
    case .failure:
        rmdir(workspacePath)
        _ = renamePath(savedPath, workspacePath)
        return .failure(.workspaceInodeBoundaryFailed)
    case .success(let disk):
        mounted = disk
    }
    _ = workspacePath.withCString { chmod($0, 0o700) }
    guard let volumeDevice = currentDevice(workspacePath), volumeDevice != originalDevice else {
        _ = runTool(["/usr/bin/hdiutil", "detach", "-force", "-quiet", mounted.disk])
        rmdir(workspacePath)
        _ = renamePath(savedPath, workspacePath)
        if let image = mounted.imagePath { unlink(image) }
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
        _ = runTool(["/usr/bin/hdiutil", "detach", "-force", "-quiet", mounted.disk])
        rmdir(workspacePath)
        _ = renamePath(savedPath, workspacePath)
        if let image = mounted.imagePath { unlink(image) }
        return .failure(.workspaceInodeBoundaryFailed)
    }
    var savedStatus = stat()
    guard fstat(savedFD, &savedStatus) == 0, device(of: savedStatus) == originalDevice else {
        close(savedFD)
        close(volumeFD)
        _ = runTool(["/usr/bin/hdiutil", "detach", "-force", "-quiet", mounted.disk])
        rmdir(workspacePath)
        _ = renamePath(savedPath, workspacePath)
        if let image = mounted.imagePath { unlink(image) }
        return .failure(.workspaceInodeBoundaryFailed)
    }
    if copyTree(from: savedFD, to: volumeFD, expectDevice: originalDevice) == false {
        close(savedFD)
        close(volumeFD)
        _ = runTool(["/usr/bin/hdiutil", "detach", "-force", "-quiet", mounted.disk])
        rmdir(workspacePath)
        _ = renamePath(savedPath, workspacePath)
        if let image = mounted.imagePath { unlink(image) }
        return .failure(.workspaceInodeBoundaryFailed)
    }
    var volumeStatus = stat()
    guard fstat(volumeFD, &volumeStatus) == 0, device(of: volumeStatus) == volumeDevice else {
        close(savedFD)
        close(volumeFD)
        _ = runTool(["/usr/bin/hdiutil", "detach", "-force", "-quiet", mounted.disk])
        rmdir(workspacePath)
        _ = renamePath(savedPath, workspacePath)
        if let image = mounted.imagePath { unlink(image) }
        return .failure(.workspaceInodeBoundaryFailed)
    }
    guard let mountSource = workspaceMountSource(workspacePath), mountSource.isEmpty == false else {
        close(savedFD)
        close(volumeFD)
        _ = runTool(["/usr/bin/hdiutil", "detach", "-force", "-quiet", mounted.disk])
        rmdir(workspacePath)
        _ = renamePath(savedPath, workspacePath)
        if let image = mounted.imagePath { unlink(image) }
        return .failure(.workspaceInodeBoundaryFailed)
    }
    let imageIdentity = mounted.imagePath.flatMap(workspacePathIdentity)
    if mounted.imagePath != nil, imageIdentity?.isDirectory != false {
        close(savedFD)
        close(volumeFD)
        _ = runTool(["/usr/bin/hdiutil", "detach", "-force", "-quiet", mounted.disk])
        rmdir(workspacePath)
        _ = renamePath(savedPath, workspacePath)
        if let image = mounted.imagePath { unlink(image) }
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

private struct TreeEntry {
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
    let overhead = byteCount &* 2 &+ (8 * 1024 * 1024)
    let minimum: UInt64 = 8 * 1024 * 1024
    let bytes = max(overhead, minimum)
    // A ram disk is a distinct device without a large image file. Above 256MB
    // of requested space, use a sparse image so launch does not pin that RAM.
    if bytes <= 256 * 1024 * 1024 {
        let sectors = Int((bytes + 511) / 512)
        let attached = runTool([
            "/usr/bin/hdiutil", "attach", "-nomount", "ram://\(sectors)",
        ])
        guard attached.status == 0 else { return .failure(.workspaceInodeBoundaryFailed) }
        guard let disk = attached.stdout.split(whereSeparator: \.isWhitespace).map(String.init).first(where: {
            $0.hasPrefix("/dev/disk")
        }) else {
            return .failure(.workspaceInodeBoundaryFailed)
        }
        let formatted = runTool(["/sbin/newfs_hfs", "-s", "-v", "rv\(token.prefix(8))", disk])
        guard formatted.status == 0 else {
            _ = runTool(["/usr/bin/hdiutil", "detach", "-force", "-quiet", disk])
            return .failure(.workspaceInodeBoundaryFailed)
        }
        let mounted = runTool([
            "/usr/sbin/diskutil", "mount", "-mountPoint", mountPoint, disk,
        ])
        guard mounted.status == 0 else {
            _ = runTool(["/usr/bin/hdiutil", "detach", "-force", "-quiet", disk])
            return .failure(.workspaceInodeBoundaryFailed)
        }
        return .success(MountedDisk(disk: disk, imagePath: nil))
    }
    let image = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-inode-\(token).sparseimage").path
    let megabytes = max(Int(bytes / (1024 * 1024)) + 1, 32)
    let created = runTool([
        "/usr/bin/hdiutil", "create", "-size", "\(megabytes)m",
        "-fs", "Case-sensitive HFS+",
        "-volname", "rv\(token.prefix(8))", "-type", "SPARSE", "-quiet", image,
    ])
    guard created.status == 0 else { return .failure(.workspaceInodeBoundaryFailed) }
    let attached = runTool([
        "/usr/bin/hdiutil", "attach", "-nobrowse", "-owners", "on",
        "-mountpoint", mountPoint, "-plist", image,
    ])
    guard attached.status == 0 else {
        unlink(image)
        return .failure(.workspaceInodeBoundaryFailed)
    }
    guard let disk = diskDevice(inPlist: attached.stdout) else {
        _ = runTool(["/usr/bin/hdiutil", "detach", "-force", "-quiet", mountPoint])
        unlink(image)
        return .failure(.workspaceInodeBoundaryFailed)
    }
    return .success(MountedDisk(disk: disk, imagePath: image))
}

private func diskDevice(inPlist stdout: String) -> String? {
    guard let data = stdout.data(using: .utf8),
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
        let root = plist as? [String: Any],
        let entities = root["system-entities"] as? [[String: Any]]
    else { return nil }
    let devices = entities.compactMap { $0["dev-entry"] as? String }
    return devices.first { $0.contains("disk") && $0.hasSuffix("s1") == false && $0.contains("s") == false }
        ?? devices.first
}

private func collectTree(root: Int32, checkDevice: UInt64) -> [String: TreeEntry]? {
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
    guard let names = directoryNames(fd) else { return false }
    for name in names {
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
private func copyTree(from source: Int32, to destination: Int32, expectDevice: UInt64) -> Bool {
    guard let names = directoryNames(source) else {
        return false
    }
    for name in names {
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
            let copied = copyTree(from: childSource, to: childDest, expectDevice: expectDevice)
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
            let copied = fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_XATTR)) == 0
            let modeOK = copied && fchmod(output, mode) == 0
            close(input)
            close(output)
            if modeOK == false { return false }
        }
    }
    return true
}

private func directoryNames(_ dirfd: Int32) -> [String]? {
    let copy = dup(dirfd)
    guard copy >= 0 else { return nil }
    // `dup` shares the directory offset. A previous listing leaves it at the
    // end, so rewind before reading or the next publish sees an empty tree.
    if lseek(copy, 0, SEEK_SET) < 0 {
        close(copy)
        return nil
    }
    guard let dir = fdopendir(copy) else {
        close(copy)
        return nil
    }
    defer { closedir(dir) }
    var names: [String] = []
    while true {
        errno = 0
        guard let entry = readdir(dir) else {
            if errno != 0 { return nil }
            break
        }
        let name = entryName(entry)
        if name == "." || name == ".." || isFilesystemBookkeeping(name) { continue }
        names.append(name)
    }
    return names
}

private func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
    var value = entry.pointee
    return withUnsafePointer(to: &value.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(value.d_namlen)) { bytes in
            String(cString: bytes)
        }
    }
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

private func kind(of mode: mode_t) -> WorkspaceInodeStamp.Kind? {
    switch mode & S_IFMT {
    case S_IFREG: return .regular
    case S_IFDIR: return .directory
    case S_IFLNK: return .symlink
    default: return nil
    }
}

private func modeBits(_ mode: mode_t) -> mode_t {
    mode & 0o777
}

private func device(of status: stat) -> UInt64 {
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

/// Names a fresh HFS volume creates at its root. They are not workspace
/// content. Copying or publishing them makes the next launch see a directory
/// the volume already owns.
private func isFilesystemBookkeeping(_ name: String) -> Bool {
    switch name {
    case ".fseventsd", ".Trashes", ".Spotlight-V100", ".TemporaryItems",
        ".DocumentRevisions-V100", ".vol", ".HFS+ Private Directory Data",
        ".apdisk", ".metadata_never_index":
        return true
    default:
        return false
    }
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
}

private func runTool(_ arguments: [String]) -> ToolOutput {
    guard let executable = arguments.first else {
        return ToolOutput(status: 1, stdout: "", stderr: "missing executable")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = Array(arguments.dropFirst())
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    process.standardInput = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return ToolOutput(status: 1, stdout: "", stderr: String(describing: error))
    }
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let err = errors.fileHandleForReading.readDataToEndOfFile()
    try? output.fileHandleForReading.close()
    try? errors.fileHandleForReading.close()
    return ToolOutput(
        status: process.terminationStatus,
        stdout: String(data: data, encoding: .utf8) ?? "",
        stderr: String(data: err, encoding: .utf8) ?? ""
    )
}
#endif
