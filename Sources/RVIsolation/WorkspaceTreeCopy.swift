#if os(macOS)
import Darwin
import Foundation
import RVDomain
import Synchronization

func collectTree(root: Int32, checkDevice: UInt64) -> [String: TreeEntry]? {
    var entries: [String: TreeEntry] = [:]
    var special: [String]?
    guard readTree(fd: root, prefix: "", expectedDevice: checkDevice, into: &entries, special: &special) else {
        return nil
    }
    return entries
}

/// The volume walk for publish. A FIFO, socket, or device node is listed in
/// `special` (relative names) instead of failing the walk, so publish can
/// refuse that one entry by name.
func collectPublishTree(root: Int32, checkDevice: UInt64) -> (entries: [String: TreeEntry], special: [String])? {
    var entries: [String: TreeEntry] = [:]
    var special: [String]? = []
    guard readTree(fd: root, prefix: "", expectedDevice: checkDevice, into: &entries, special: &special) else {
        return nil
    }
    return (entries, special ?? [])
}

private final class TreeStatBox: @unchecked Sendable {
    var status = stat()
}

private final class TreeFDBox: @unchecked Sendable {
    var fd: Int32 = -1
    deinit {
        if fd >= 0 { close(fd) }
    }

    func take() -> Int32 {
        let value = fd
        fd = -1
        return value
    }
}

private func treeSyscallLiveStop() -> Date? {
    let now = Date()
    if blockingWorkIsCancelled() {
        CooperativeLaunchStop.noteCancel(now: now)
    }
    return diskImageTreeCopyStop(
        deadline: CooperativeLaunchStop.cancelClock?.deadline,
        now: now
    )
}

enum ClockedStat {
    case value(stat)
    case failed
    case stopped
}

func fstatatObservingCopyClock(_ dirfd: Int32, _ name: String) -> ClockedStat {
    let allowance = diskImageTreeSyscallAllowance(
        deadline: CooperativeLaunchStop.cancelClock?.deadline
    )
    if let allowance, allowance <= 0 { return .stopped }
    let box = TreeStatBox()
    let ok = diskImageWaitForStat(
        duplicating: dirfd,
        allowance: allowance,
        liveDeadline: { treeSyscallLiveStop() }
    ) { copy in
        let stated = name.withCString {
            fstatat(copy, $0, &box.status, AT_SYMLINK_NOFOLLOW) == 0
        }
        close(copy)
        return stated
    }
    if ok == nil { return .stopped }
    if ok == false { return .failed }
    return .value(box.status)
}

func fstatatWithinCopyClock(_ dirfd: Int32, _ name: String) -> stat? {
    if case let .value(status) = fstatatObservingCopyClock(dirfd, name) { return status }
    return nil
}

/// Tri-state like every clocked mutator: nil means the clock stopped
/// with the call possibly still in flight on a parked worker. Callers
/// that mutate the saved tree must fence the workspace rename on nil.
func fchmodWithinCopyClock(_ fd: Int32, _ mode: mode_t) -> Bool? {
    let allowance = diskImageTreeSyscallAllowance(
        deadline: CooperativeLaunchStop.cancelClock?.deadline
    )
    if let allowance, allowance <= 0 { return nil }
    return diskImageWaitForStat(
        duplicating: fd,
        allowance: allowance,
        liveDeadline: { treeSyscallLiveStop() }
    ) { copy in
        let changed = fchmod(copy, mode) == 0
        close(copy)
        return changed
    }
}

func fstatWithinCopyClock(_ fd: Int32) -> stat? {
    let allowance = diskImageTreeSyscallAllowance(
        deadline: CooperativeLaunchStop.cancelClock?.deadline
    )
    if let allowance, allowance <= 0 { return nil }
    let box = TreeStatBox()
    let ok = diskImageWaitForStat(
        duplicating: fd,
        allowance: allowance,
        liveDeadline: { treeSyscallLiveStop() }
    ) { copy in
        let stated = fstat(copy, &box.status) == 0
        close(copy)
        return stated
    }
    guard ok == true else { return nil }
    return box.status
}

private func ownersIgnoredWithinCopyClock(_ dirfd: Int32) -> Bool? {
    final class Box: @unchecked Sendable { var ignored = false }
    let box = Box()
    let allowance = diskImageTreeSyscallAllowance(
        deadline: CooperativeLaunchStop.cancelClock?.deadline
    )
    if let allowance, allowance <= 0 { return nil }
    let ok = diskImageWaitForStat(
        duplicating: dirfd,
        allowance: allowance,
        liveDeadline: { treeSyscallLiveStop() }
    ) { copy in
        var status = statfs()
        let stated = fstatfs(copy, &status) == 0
        close(copy)
        if stated {
            box.ignored = status.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0
        }
        return stated
    }
    if ok == nil { return nil }
    if ok == false { return false }
    return box.ignored
}

func readlinkWithinCopyClock(_ dirfd: Int32, _ name: String) -> String? {
    final class Box: @unchecked Sendable { var text: String? }
    let box = Box()
    let allowance = diskImageTreeSyscallAllowance(
        deadline: CooperativeLaunchStop.cancelClock?.deadline
    )
    if let allowance, allowance <= 0 { return nil }
    let ok = diskImageWaitForStat(
        duplicating: dirfd,
        allowance: allowance,
        liveDeadline: { treeSyscallLiveStop() }
    ) { copy in
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = name.withCString { readlinkat(copy, $0, &buffer, buffer.count - 1) }
        close(copy)
        guard count >= 0, count < buffer.count - 1 else { return false }
        box.text = String(
            decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return true
    }
    guard ok == true else { return nil }
    return box.text
}

func symlinkWithinCopyClock(_ dirfd: Int32, _ name: String, _ target: String) -> Bool? {
    let allowance = diskImageTreeSyscallAllowance(
        deadline: CooperativeLaunchStop.cancelClock?.deadline
    )
    if let allowance, allowance <= 0 { return nil }
    return diskImageWaitForStat(
        duplicating: dirfd,
        allowance: allowance,
        liveDeadline: { treeSyscallLiveStop() }
    ) { copy in
        let linked = name.withCString { item in
            target.withCString { link in
                symlinkat(link, copy, item) == 0
            }
        }
        close(copy)
        return linked
    }
}

func mkdiratWithinCopyClock(_ dirfd: Int32, _ name: String, _ mode: mode_t) -> Bool? {
    let allowance = diskImageTreeSyscallAllowance(
        deadline: CooperativeLaunchStop.cancelClock?.deadline
    )
    if let allowance, allowance <= 0 { return nil }
    return diskImageWaitForStat(
        duplicating: dirfd,
        allowance: allowance,
        liveDeadline: { treeSyscallLiveStop() }
    ) { copy in
        let created = name.withCString { mkdirat(copy, $0, mode) == 0 }
        close(copy)
        return created
    }
}

/// `-1` with `stopped == true` means the copy clock returned while the
/// open may still be inside `openat`: with `O_CREAT` the file can still
/// appear after the caller moves on. `-1` with `stopped == false` is a
/// finished failure. A zero allowance never starts the open, so it is
/// a finished failure for fencing purposes: nothing is parked.
func openatOutcomeWithinCopyClock(
    _ dirfd: Int32,
    _ name: String,
    _ flags: Int32,
    _ mode: mode_t = 0
) -> (fd: Int32, stopped: Bool) {
    let allowance = diskImageTreeSyscallAllowance(
        deadline: CooperativeLaunchStop.cancelClock?.deadline
    )
    if let allowance, allowance <= 0 { return (-1, false) }
    let box = TreeFDBox()
    let ok = diskImageWaitForStat(
        duplicating: dirfd,
        allowance: allowance,
        liveDeadline: { treeSyscallLiveStop() }
    ) { copy in
        let fd = name.withCString { openat(copy, $0, flags, mode) }
        close(copy)
        box.fd = fd
        return fd >= 0
    }
    if ok == nil { return (-1, true) }
    if ok == true { return (box.take(), false) }
    return (-1, false)
}

func openatWithinCopyClock(
    _ dirfd: Int32,
    _ name: String,
    _ flags: Int32,
    _ mode: mode_t = 0
) -> Int32 {
    openatOutcomeWithinCopyClock(dirfd, name, flags, mode).fd
}

private func readTree(
    fd: Int32,
    prefix: String,
    expectedDevice: UInt64,
    into entries: inout [String: TreeEntry],
    special: inout [String]?
) -> Bool {
    if directoryReadMayContinue(cancelClockAllowsTreeCopy()) == false { return false }
    guard let names = directoryNames(fd, isWorkspaceRoot: prefix.isEmpty) else { return false }
    for name in names {
        if directoryReadMayContinue(cancelClockAllowsTreeCopy()) == false { return false }
        let relative = prefix.isEmpty ? name : prefix + "/" + name
        guard let status = fstatatWithinCopyClock(fd, name),
            device(of: status) == expectedDevice
        else {
            return false
        }
        guard let stamp = stamp(of: status) else {
            // Not a file, directory, or symlink. Only the publish walk
            // collects it; every other walk fails closed as before.
            guard special != nil else { return false }
            special?.append(relative)
            continue
        }
        let bytes = stamp.kind == .regular ? UInt64(status.st_size) : 0
        entries[relative] = TreeEntry(stamp: stamp, mode: modeBits(status.st_mode), bytes: bytes)
        if stamp.kind == .directory {
            let child = openatWithinCopyClock(
                fd,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard child >= 0 else { return false }
            let ok = readTree(
                fd: child,
                prefix: relative,
                expectedDevice: expectedDevice,
                into: &entries,
                special: &special
            )
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
        guard let status = fstatatWithinCopyClock(source, name),
            device(of: status) == expectDevice,
            let kind = stamp(of: status)?.kind
        else {
            return false
        }
        let mode = modeBits(status.st_mode)
        switch kind {
        case .directory:
            // Owner-only until the children land: a 0555 directory would refuse
            // their creates. The fchmod below sets the real mode (and sidesteps umask).
            guard mkdiratWithinCopyClock(destination, name, 0o700) == true else {
                return false
            }
            let childSource = openatWithinCopyClock(
                source,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            let childDest = openatWithinCopyClock(
                destination,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
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
            let modeOK = copied && fchmodWithinCopyClock(childDest, mode) == true
            close(childSource)
            close(childDest)
            if modeOK == false { return false }
        case .symlink:
            guard let target = readlinkWithinCopyClock(source, name) else {
                return false
            }
            if symlinkWithinCopyClock(destination, name, target) != true {
                return false
            }
        case .regular:
            if status.st_nlink > 1 {
                return false
            }
            let input = openatWithinCopyClock(
                source,
                name,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            guard input >= 0 else {
                return false
            }
            guard let again = fstatWithinCopyClock(input), again.st_nlink <= 1 else {
                close(input)
                return false
            }
            // Owner-only while bytes and xattrs land: `fsetxattr` checks the
            // inode mode, not the descriptor, so a 0444 create cannot take
            // `com.apple.provenance`. The fchmod below sets the real mode.
            let output = openatWithinCopyClock(
                destination,
                name,
                O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_WRONLY,
                0o600
            )
            guard output >= 0 else {
                close(input)
                return false
            }
            let copied = copyFileDataObservingCancelClock(from: input, to: output)
            let modeOK = copied && fchmodWithinCopyClock(output, mode) == true
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
    copyFileDataOutcomeObservingCancelClock(from: source, to: destination) == .finished
}

func copyFileDataOutcomeObservingCancelClock(
    from source: Int32,
    to destination: Int32
) -> DiskImageCopyOutcome {
    copyFileLeavingDetachReserveOutcome(
        from: source,
        to: destination,
        mayContinue: publishCopyMayContinue,
        copyXattr: copyExtendedAttributes
    )
}

func publishCopyMayContinue(_ point: CopyClockPoint) -> Bool {
    _ = point
    return cancelClockAllowsTreeCopy()
}

func copyExtendedAttributes(_ source: Int32, _ destination: Int32) -> Bool {
    copyXattrsObservingClock(from: source, to: destination) {
        cancelClockAllowsTreeCopy()
    }
}



/// A rename relative to `dirfd`, off the caller. `body` gets a duplicate of
/// `dirfd` and returns the syscall's result. Nil is a clock stop with the
/// rename possibly still in flight.
func renameatWithinCopyClock(
    _ dirfd: Int32,
    _ body: @escaping @Sendable (Int32) -> Int32
) -> Bool? {
    let allowance = diskImageTreeSyscallAllowance(
        deadline: CooperativeLaunchStop.cancelClock?.deadline
    )
    if let allowance, allowance <= 0 { return nil }
    return diskImageWaitForStat(
        duplicating: dirfd,
        allowance: allowance,
        liveDeadline: { treeSyscallLiveStop() }
    ) { copy in
        let renamed = body(copy) == 0
        close(copy)
        return renamed
    }
}

/// Same device, inode, and kind. Link count is not compared.
func sameInode(_ stamp: WorkspaceInodeStamp, _ status: stat) -> Bool {
    stamp.device == device(of: status)
        && stamp.inode == UInt64(status.st_ino)
        && kind(of: status.st_mode) == stamp.kind
}

func unlinkatWithinCopyClock(_ dirfd: Int32, _ name: String, _ flags: Int32) -> Bool? {
    let allowance = diskImageTreeSyscallAllowance(
        deadline: CooperativeLaunchStop.cancelClock?.deadline
    )
    if let allowance, allowance <= 0 { return nil }
    return diskImageWaitForStat(
        duplicating: dirfd,
        allowance: allowance,
        liveDeadline: { treeSyscallLiveStop() }
    ) { copy in
        let removed = name.withCString { unlinkat(copy, $0, flags) == 0 }
        close(copy)
        return removed
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
            switch fstatatObservingCopyClock(dirfd, name) {
            case .stopped:
                return nil
            case .failed:
                break
            case let .value(status):
                guard let ownersIgnored = ownersIgnoredWithinCopyClock(dirfd) else {
                    return nil
                }
                if WorkspaceFilesystemMetadata.shouldSkip(
                    name: name,
                    isRootChild: true,
                    isDirectory: kind(of: status.st_mode) == .directory,
                    isSymbolicLink: kind(of: status.st_mode) == .symlink,
                    ownerUid: status.st_uid,
                    ownersIgnored: ownersIgnored
                ) {
                    continue
                }
            }
        }
        names.append(name)
    }
    return names
}

func acceptableSavedInode(_ captured: WorkspaceInodeStamp, _ status: stat) -> Bool {
    guard let live = stamp(of: status) else { return false }
    return workspaceInodeAcceptableForPublish(captured: captured, live: live)
}

func stamp(of status: stat) -> WorkspaceInodeStamp? {
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
#endif
