#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization

/// Retains `object` until every call wedged at retain time has
/// returned. Used when a clock stop returns while a worker may still be
/// inside a call that uses `object`: releasing a directory enumerator
/// while `nextObject` is inside `getattrlistbulk` would free it under
/// the call.
func diskImageRetainAcrossPark(_ object: AnyObject) {
    DiskImageSyscallPool.shared.retainAcrossWedged(object)
}

/// How quickly a stop that arms during a call (the shared cancel clock
/// has no wake-up of its own) is noticed. Completion wakes the waiter at
/// once; this only bounds the wait for a stop that arrives mid-call.
private let diskImageLiveStopRecheck: TimeInterval = 0.005

/// Wait for one blocking call. `nil` allowance is the non-cancelled path:
/// the call still runs off the caller, and a shared clock that arms during
/// it makes this return. A positive allowance returns nil once that time is
/// gone. `stat`, `statfs`, `fstatat`, `mkdir`, `readdir`, `read`, and
/// `write` blocked on a vnode lock do not fail with `EINTR`, so this does
/// not wait for the call to return. The caller is back by the stop. The
/// worker may still be inside the call; it is quarantined, not joined.
/// Zero does not start the call. A pool already holding its cap of
/// wedged workers starts nothing and returns nil (fail closed).
func diskImageWaitForStat(
    allowance: TimeInterval?,
    liveDeadline: @escaping @Sendable () -> Date? = { diskImageLiveCancelDeadline() },
    pool: DiskImageSyscallPool = .shared,
    stat: @escaping @Sendable () -> Bool
) -> Bool? {
    if let allowance, allowance <= 0 { return nil }
    let started = Date()
    guard let call = pool.submit(stat) else { return nil }
    return pool.wait(for: call, recheck: diskImageLiveStopRecheck) {
        diskImageWaitStop(started: started, allowance: allowance, liveDeadline: liveDeadline())
    }
}

/// `diskImageWaitForStat` on a duplicate of `fd` taken here, on the caller.
/// A worker that duplicated `fd` itself could start after the caller
/// stopped waiting and closed it, then act on whatever reused that number.
/// `body` owns the copy and must close it. A failed duplicate is a finished
/// failure; zero allowance takes no duplicate and starts nothing.
func diskImageWaitForStat(
    duplicating fd: Int32,
    allowance: TimeInterval?,
    liveDeadline: @escaping @Sendable () -> Date? = { diskImageLiveCancelDeadline() },
    pool: DiskImageSyscallPool = .shared,
    _ body: @escaping @Sendable (Int32) -> Bool
) -> Bool? {
    if let allowance, allowance <= 0 { return nil }
    let copy = diskImageDuplicateDescriptor(fd)
    guard copy >= 0 else { return false }
    let started = Date()
    // A refused call never reaches `body`, so the copy is still ours.
    guard let call = pool.submit({ body(copy) }) else {
        close(copy)
        return nil
    }
    return pool.wait(for: call, recheck: diskImageLiveStopRecheck) {
        diskImageWaitStop(started: started, allowance: allowance, liveDeadline: liveDeadline())
    }
}

/// Tree and publish syscalls use the copy budget, which reserves `detachCap`.
/// `nil` means the call did not finish before that stop.
func diskImagePerformWithinCopyClock(_ body: @escaping @Sendable () -> Bool) -> Bool? {
    diskImageWaitForStat(
        allowance: diskImageCopyClockAllowance(),
        liveDeadline: diskImageCopyClockLiveStop,
        stat: body
    )
}

/// `diskImagePerformWithinCopyClock` on a caller-side duplicate of `fd`;
/// see `diskImageWaitForStat(duplicating:)`. `body` owns the copy.
func diskImagePerformWithinCopyClock(
    duplicating fd: Int32,
    _ body: @escaping @Sendable (Int32) -> Bool
) -> Bool? {
    diskImageWaitForStat(
        duplicating: fd,
        allowance: diskImageCopyClockAllowance(),
        liveDeadline: diskImageCopyClockLiveStop,
        body
    )
}

private func diskImageCopyClockAllowance() -> TimeInterval? {
    diskImageTreeSyscallAllowance(deadline: CooperativeLaunchStop.cancelClock?.deadline)
}

@Sendable private func diskImageCopyClockLiveStop() -> Date? {
    if blockingWorkIsCancelled() { CooperativeLaunchStop.noteCancel() }
    return diskImageTreeCopyStop(
        deadline: CooperativeLaunchStop.cancelClock?.deadline,
        now: Date()
    )
}

/// A proof or image unlink after detach. The copy budget may already be
/// zero; the detach reserve is what this call is for. It stops at the
/// cancel clock, not `detachCap` earlier. Zero remaining does not start
/// the call. No clock waits for the syscall, same as the copy helper.
func diskImagePerformWithinCancelClock(_ body: @escaping @Sendable () -> Bool) -> Bool? {
    let allowance: TimeInterval?
    if let deadline = CooperativeLaunchStop.cancelClock?.deadline {
        allowance = max(0, deadline.timeIntervalSinceNow)
    } else {
        allowance = nil
    }
    return diskImageWaitForStat(
        allowance: allowance,
        liveDeadline: {
            if blockingWorkIsCancelled() { CooperativeLaunchStop.noteCancel() }
            return CooperativeLaunchStop.cancelClock?.deadline
        },
        stat: body
    )
}

/// Duplicates `fd` at or above 256 so a worker thread does not take a low
/// number the spawn floor still probes. `dup` would reuse the descriptor
/// `relocateDescriptor` just closed.
func diskImageDuplicateDescriptor(_ fd: Int32) -> Int32 {
    fcntl(fd, F_DUPFD_CLOEXEC, 256)
}

struct DiskImagePathSnapshot {
    var device: UInt64
    var inode: UInt64
    var mode: mode_t
}

/// `lstat` of one path. `.stopped` means the copy clock returned before the
/// call finished. `.missing` is a finished failure. A stopped read is not
/// evidence the path is gone.
enum DiskImagePathObservation {
    case value(DiskImagePathSnapshot)
    case missing
    case stopped
}

func diskImageObservePath(_ path: String) -> DiskImagePathObservation {
    diskImageObservePath(path, perform: diskImagePerformWithinCopyClock)
}

/// Post-detach identity check. A copy budget of zero must not skip this
/// `lstat`: the detach reserve is still on the cancel clock. `.stopped`
/// is still not proof the mount is gone.
func diskImageObservePathWithinCancelClock(_ path: String) -> DiskImagePathObservation {
    diskImageObservePath(path, perform: diskImagePerformWithinCancelClock)
}

private func diskImageObservePath(
    _ path: String,
    perform: (@escaping @Sendable () -> Bool) -> Bool?
) -> DiskImagePathObservation {
    final class Box: @unchecked Sendable {
        var status = stat()
        var found = false
    }
    let box = Box()
    let ok = perform {
        box.found = path.withCString { lstat($0, &box.status) == 0 }
        return true
    }
    if ok == nil { return .stopped }
    guard box.found else { return .missing }
    return .value(
        DiskImagePathSnapshot(
            device: UInt64(box.status.st_dev),
            inode: UInt64(box.status.st_ino),
            mode: box.status.st_mode
        )
    )
}

/// `stat` (follows symlinks), for the directory check `fileExists` used to
/// make on the caller. A stopped call is not "missing".
enum DiskImageDirectoryPresence {
    case directory
    case notDirectory
    case missing
    case stopped
}

func diskImageDirectoryPresence(_ path: String) -> DiskImageDirectoryPresence {
    diskImageDirectoryPresence(path, perform: diskImagePerformWithinCopyClock)
}

func diskImageDirectoryPresenceWithinCancelClock(_ path: String) -> DiskImageDirectoryPresence {
    diskImageDirectoryPresence(path, perform: diskImagePerformWithinCancelClock)
}

private func diskImageDirectoryPresence(
    _ path: String,
    perform: (@escaping @Sendable () -> Bool) -> Bool?
) -> DiskImageDirectoryPresence {
    final class Box: @unchecked Sendable {
        var status = stat()
        var found = false
    }
    let box = Box()
    let ok = perform {
        box.found = path.withCString { stat($0, &box.status) == 0 }
        return true
    }
    if ok == nil { return .stopped }
    guard box.found else { return .missing }
    if (box.status.st_mode & S_IFMT) == S_IFDIR { return .directory }
    return .notDirectory
}

/// One `open` of a path. `nil` is the copy clock: the caller does not close
/// a descriptor the worker may still be creating. `-1` is a finished failure.
func diskImageOpenPathWithinCopyClock(
    _ path: String,
    _ flags: Int32,
    _ mode: mode_t = 0
) -> Int32? {
    let hold = DiskImageOpenedFD()
    let ok = diskImagePerformWithinCopyClock {
        let opened = path.withCString { open($0, flags, mode) }
        hold.store(opened)
        return true
    }
    if ok == nil {
        hold.leak()
        return nil
    }
    return hold.take()
}

/// `ftruncate` on a duplicate of `fd`. The duplicate shares the open file
/// description, so the caller's offset and size change with it. A clock
/// stop returns nil and does not close the duplicate out from under the
/// call: the parked worker can still truncate afterwards, so nil must be
/// treated as "may have truncated", never as a finished failure.
func diskImageFtruncateWithinCopyClock(_ fd: Int32, _ length: off_t) -> Bool? {
    diskImagePerformWithinCopyClock(duplicating: fd) { copy in
        let truncated = ftruncate(copy, length) == 0
        close(copy)
        return truncated
    }
}

/// `chmod` off the caller. `nil` is the copy clock: the mode is unchanged
/// because the call did not start, or had not finished. `false` is a
/// finished failure.
func diskImageChmodWithinCopyClock(_ path: String, _ mode: mode_t) -> Bool? {
    let target = path
    return diskImagePerformWithinCopyClock {
        target.withCString { chmod($0, mode) == 0 }
    }
}

/// `rmdir` off the caller. `nil` means the directory is still there as far
/// as this thread knows: the clock returned first.
func diskImageRmdirWithinCopyClock(_ path: String) -> Bool? {
    let target = path
    return diskImagePerformWithinCopyClock {
        target.withCString { rmdir($0) == 0 }
    }
}

/// `mkdir` off the caller. `nil` means this thread does not know whether
/// the directory was created: the clock returned first, so the caller must
/// not rename another tree onto that path.
func diskImageMkdirWithinCopyClock(_ path: String, _ mode: mode_t) -> Bool? {
    let target = path
    return diskImagePerformWithinCopyClock {
        target.withCString { mkdir($0, mode) == 0 }
    }
}

/// `fileExists` off the caller. `nil` is the copy clock, not a missing path.
func diskImagePathExists(_ path: String) -> Bool? {
    diskImagePathExists(diskImageDirectoryPresence(path))
}

/// Existence after detach. Uses the cancel clock, including the detach
/// reserve the copy budget has already given up.
func diskImagePathExistsWithinCancelClock(_ path: String) -> Bool? {
    diskImagePathExists(diskImageDirectoryPresenceWithinCancelClock(path))
}

private func diskImagePathExists(_ presence: DiskImageDirectoryPresence) -> Bool? {
    switch presence {
    case .directory, .notDirectory:
        return true
    case .missing:
        return false
    case .stopped:
        return nil
    }
}

struct DiskImageNodeSnapshot {
    var mode: mode_t
    var nlink: UInt64
}

enum DiskImageNodeObservation {
    case value(DiskImageNodeSnapshot)
    case missing
    case stopped
}

/// `lstat` including link count. `.stopped` is not a missing path.
func diskImageLstatNode(_ path: String) -> DiskImageNodeObservation {
    final class Box: @unchecked Sendable {
        var status = stat()
        var found = false
    }
    let box = Box()
    let ok = diskImagePerformWithinCopyClock {
        box.found = path.withCString { lstat($0, &box.status) == 0 }
        return true
    }
    if ok == nil { return .stopped }
    guard box.found else { return .missing }
    return .value(
        DiskImageNodeSnapshot(
            mode: box.status.st_mode,
            nlink: UInt64(box.status.st_nlink)
        )
    )
}

/// Read an already-open descriptor until EOF. `nil` is the copy clock or a
/// finished error. It is not an empty file. `EINTR` is retried only after
/// `errno` is `EINTR` and the copy clock still allows another call.
func diskImageReadFDToEndWithinCopyClock(_ fd: Int32) -> Data? {
    var data = Data()
    while true {
        guard let chunk = diskImageReadWithinCopyClock(fd, maxCount: 65_536) else {
            return nil
        }
        if chunk.count > 0 {
            data.append(contentsOf: chunk.bytes)
            continue
        }
        if chunk.count == 0 { return data }
        if chunk.errnoValue == EINTR {
            let allowance = diskImageTreeSyscallAllowance(
                deadline: CooperativeLaunchStop.cancelClock?.deadline
            )
            if allowance == nil || (allowance ?? 0) > 0 { continue }
        }
        return nil
    }
}

/// `open` plus read of one path. `nil` from the open does not close a
/// descriptor the worker may still be creating and does not unlink the path.
/// A stop during `read` is `nil`, not the bytes gathered so far.
func diskImageReadWholeFileWithinCopyClock(_ path: String) -> Data? {
    guard let opened = diskImageOpenPathWithinCopyClock(path, O_RDONLY | O_CLOEXEC) else {
        return nil
    }
    guard opened >= 0 else { return nil }
    defer { close(opened) }
    return diskImageReadFDToEndWithinCopyClock(opened)
}

/// `unlink` off the caller. `nil` is not a missing file. A finished `false`
/// is the syscall's own failure, including `ENOENT` after the call returned.
func diskImageUnlinkWithinCopyClock(_ path: String) -> Bool? {
    diskImageUnlink(path, perform: diskImagePerformWithinCopyClock)
}

/// Image unlink after the volume is gone. A spent copy budget must not
/// skip it while the cancel clock still has the detach reserve.
func diskImageUnlinkWithinCancelClock(_ path: String) -> Bool? {
    diskImageUnlink(path, perform: diskImagePerformWithinCancelClock)
}

private func diskImageUnlink(
    _ path: String,
    perform: (@escaping @Sendable () -> Bool) -> Bool?
) -> Bool? {
    let target = path
    return perform {
        target.withCString { unlink($0) == 0 }
    }
}

/// `lstat` then `unlink` of one regular file this process recorded.
/// `.stopped` is not gone: the caller must fail the restore instead of
/// marking the original restored. A finished miss, or a different inode,
/// is success and does not unlink. A finished unlink failure is failure.
func diskImageRemoveOwnedRegular(path: String, device: UInt64, inode: UInt64) -> Bool {
    switch diskImageObservePath(path) {
    case .stopped:
        return false
    case .missing:
        return true
    case .value(let snapshot):
        guard snapshot.device == device,
            snapshot.inode == inode,
            (snapshot.mode & S_IFMT) == S_IFREG
        else {
            return true
        }
        return diskImageUnlinkWithinCopyClock(path) == true
    }
}

/// `rename` off the caller. `nil` does not set `EXDEV`: a stopped rename is
/// not a cross-device failure, and the caller must not start the other
/// install path while this one is still inside the syscall. A finished
/// failure copies the worker's `errno` back.
func diskImageRenameWithinCopyClock(_ from: String, _ to: String) -> Bool? {
    final class Box: @unchecked Sendable { var err: Int32 = 0 }
    let box = Box()
    let source = from
    let destination = to
    let ok = diskImagePerformWithinCopyClock {
        let renamed = source.withCString { src in
            destination.withCString { dst in
                rename(src, dst) == 0
            }
        }
        if renamed == false { box.err = errno }
        return renamed
    }
    if ok == nil {
        errno = EIO
        return nil
    }
    if ok == false {
        errno = box.err == 0 ? EIO : box.err
        return false
    }
    return true
}

/// `stat` size off the caller. `nil` is a clock stop or a finished miss,
/// not a zero-length file.
func diskImageFileSizeWithinCopyClock(_ path: String) -> off_t? {
    final class Box: @unchecked Sendable {
        var size: off_t = 0
        var found = false
    }
    let box = Box()
    let target = path
    let ok = diskImagePerformWithinCopyClock {
        var status = stat()
        let found = target.withCString { stat($0, &status) == 0 }
        if found { box.size = status.st_size }
        box.found = found
        return true
    }
    guard ok == true, box.found else { return nil }
    return box.size
}

/// An fd opened on a worker. A clock stop leaks it instead of closing a
/// number `open` may not have stored yet, or may store after the caller left.
private final class DiskImageOpenedFD: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var leaked = false

    func store(_ opened: Int32) {
        lock.lock()
        if leaked == false {
            fd = opened
        }
        lock.unlock()
    }

    func take() -> Int32 {
        lock.lock()
        let opened = fd
        fd = -1
        lock.unlock()
        return opened
    }

    func leak() {
        lock.lock()
        leaked = true
        fd = -1
        lock.unlock()
    }
}

/// An `EINTR` from `read` or `write` may be retried only while the copy
/// clock still allows another call. A due clock does not spin.
func diskImageInterruptedReadMayRetry(errnoValue: Int32, clockAllowsAnotherCall: Bool) -> Bool {
    errnoValue == EINTR && clockAllowsAnotherCall
}

struct DiskImageIOResult: Sendable {
    var count: Int
    var errnoValue: Int32
    var bytes: [UInt8]
}

private final class DiskImageReadBox: @unchecked Sendable {
    var count = -1
    var errnoValue: Int32 = 0
    var bytes: [UInt8]
    init(size: Int) { bytes = [UInt8](repeating: 0, count: max(size, 1)) }
}

/// One `read`, on a duplicate fd, off the caller. `nil` is the copy clock.
/// `EINTR` is returned to the caller so the retry can see the clock.
func diskImageReadWithinCopyClock(_ fd: Int32, maxCount: Int) -> DiskImageIOResult? {
    let box = DiskImageReadBox(size: maxCount)
    let ok = diskImagePerformWithinCopyClock(duplicating: fd) { copy in
        let count = box.bytes.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return read(copy, base, raw.count)
        }
        box.count = count
        box.errnoValue = count < 0 ? errno : 0
        close(copy)
        return true
    }
    guard ok == true else { return nil }
    let kept = box.count > 0 ? Array(box.bytes.prefix(box.count)) : []
    return DiskImageIOResult(count: box.count, errnoValue: box.errnoValue, bytes: kept)
}

/// One `write`, on a duplicate fd, off the caller. The bytes live in the
/// worker until `write` returns, including when the caller has already left.
func diskImageWriteWithinCopyClock(
    _ fd: Int32,
    bytes: [UInt8],
    offset: Int,
    count: Int
) -> DiskImageIOResult? {
    let box = DiskImageReadBox(size: 1)
    let payload = bytes
    let ok = diskImagePerformWithinCopyClock(duplicating: fd) { copy in
        let wrote = payload.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            let start = base.advanced(by: offset)
            return write(copy, start, count)
        }
        box.count = wrote
        box.errnoValue = wrote < 0 ? errno : 0
        close(copy)
        return true
    }
    guard ok == true else { return nil }
    return DiskImageIOResult(count: box.count, errnoValue: box.errnoValue, bytes: [])
}

/// One publication stat on the cancel clock. `nil` means the clock was
/// already due, or the stat was still blocked when the allowance ended, so
/// the caller must not clear. A nil local deadline still sees the shared
/// clock. Both nil still starts the stat, and a cancel that arms during
/// that stat stops it. The stat does not run on the caller.
func diskImageStatObservingCancelClock(
    localDeadline: Date?,
    sharedDeadline: Date?,
    now: Date = Date(),
    liveDeadline: @escaping @Sendable () -> Date? = { diskImageLiveCancelDeadline() },
    stat: @escaping @Sendable () -> Bool
) -> Bool? {
    let end = diskImageRecheckStatDeadline(local: localDeadline, shared: sharedDeadline)
    switch diskImageRecheckStatBudget(cancelDeadline: end, now: now) {
    case .skip:
        return nil
    case .uncancelled:
        return diskImageWaitForStat(allowance: nil, liveDeadline: liveDeadline, stat: stat)
    case .limited(let allowance):
        return diskImageWaitForStat(allowance: allowance, liveDeadline: liveDeadline, stat: stat)
    }
}
