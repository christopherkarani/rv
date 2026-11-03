#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization

/// What a preempted diskimage helper may have left behind. Create images
/// are unlinked. An attach is detached and a mount is unmounted before
/// the serialization lock is released. A preempted `umount` or `hdiutil
/// detach` has no follow-up helper: the cancelled caller is that helper,
/// and starting another one would stack a second copy on diskimagesd.
enum PreemptedDiskHelperCleanup: Equatable, Sendable {
    case unlinkSparseImage(String)
    case detachImage(String)
    case unmount(String)
    case none

    static func plan(arguments: [String]) -> PreemptedDiskHelperCleanup {
        guard let executable = arguments.first, arguments.count >= 2 else { return .none }
        switch executable {
        case "/usr/bin/hdiutil":
            let image = arguments[arguments.count - 1]
            guard image.contains("rv-inode-"), image.hasSuffix(".sparseimage") else {
                return .none
            }
            switch arguments[1] {
            case "create":
                return .unlinkSparseImage(image)
            case "attach":
                return .detachImage(image)
            default:
                return .none
            }
        case "/sbin/mount_hfs":
            guard let mountPoint = arguments.last, mountPoint.hasPrefix("/") else { return .none }
            return .unmount(mountPoint)
        default:
            return .none
        }
    }

    /// Helper to run before the lock is released. Unlink is not a helper.
    /// A detached image has no static argv: `hdiutil detach` takes a
    /// devname or mount point, never the image path, so the execution
    /// site must resolve the device (attach plist or `hdiutil info`)
    /// and use `DiskImageCancelBudget.detachArguments(device:)`.
    var followUpArguments: [String]? {
        switch self {
        case .none, .unlinkSparseImage, .detachImage:
            return nil
        case .unmount(let mountPoint):
            return ["/sbin/umount", "-f", mountPoint]
        }
    }
}

/// The serialization lock may drop only after the preempted helper has
/// exited and its attach, mount, or partial image has been cleaned up.
/// A still-running helper, or a cleanup that has not finished, keeps the
/// lock so the next `hdiutil` / `mount_hfs` / `umount` cannot start.
func diskImageMayDropSerializationLock(
    helperStillAlive: Bool,
    reapExpired: Bool = false,
    cleanup: PreemptedDiskHelperCleanup,
    cleanupFinished: Bool,
    cleanupAttempted: Bool = false,
    diskCanStillAppear: Bool = false
) -> Bool {
    switch cleanup {
    case .none:
        // The helper is the umount or detach. After the reap, park it and
        // return. There is no second device to detach.
        if helperStillAlive && reapExpired == false { return false }
        return true
    case .unlinkSparseImage, .detachImage, .unmount:
        // A live helper can still publish `/dev/diskN`. A busy detach means
        // that disk is still published. Neither case drops the lock. A
        // cleanup attempt does not count while the helper can publish.
        _ = cleanupAttempted
        if helperStillAlive { return false }
        if diskCanStillAppear { return false }
        return cleanupFinished
    }
}

/// `hdiutil detach` exited busy. The disk is still published. That is not
/// cleanup success, and it is not "nothing was attached".
func diskImageDetachIsBusy(status: Int32, timedOut: Bool, output: String) -> Bool {
    if status == 0 && timedOut == false { return false }
    let text = output.lowercased()
    return text.contains("resource busy") || text.contains("busy")
}

/// A reaped attach or mount that timed out can already have published a
/// disk. Detach it before the lock drops. A helper that is still alive is
/// not detached here: it can still publish.
func diskImageMustDetachBeforeUnlock(
    cleanup: PreemptedDiskHelperCleanup,
    helperStillAlive: Bool,
    preempted: Bool,
    timedOut: Bool,
    status: Int32
) -> Bool {
    switch cleanup {
    case .none:
        return false
    case .unlinkSparseImage:
        return false
    case .detachImage, .unmount:
        if helperStillAlive { return false }
        return preempted || timedOut || status != 0
    }
}

/// Process exit plus detach 0 is not enough. The disk can still appear
/// until a later listing shows it is gone and that listing was taken after
/// waiting out the publish race. An unknown listing (`nil`) can still appear.
func diskImageCanStillAppear(
    helperStillAlive: Bool,
    detachStatus: Int32,
    detachTimedOut: Bool,
    detachOutput: String,
    imageListedAfterDetach: Bool?,
    waitedForPublication: Bool
) -> Bool {
    if helperStillAlive || detachTimedOut { return true }
    if diskImageDetachIsBusy(status: detachStatus, timedOut: detachTimedOut, output: detachOutput) {
        return true
    }
    if imageListedAfterDetach != false { return true }
    if waitedForPublication == false { return true }
    _ = detachStatus
    return false
}

/// The image file is the path a later detach uses. Remove it only after
/// `hdiutil detach` exits 0. A skipped or failed detach leaves the file.
func diskImageMayRemoveImage(detachSucceeded: Bool) -> Bool {
    detachSucceeded
}

/// A second `hdiutil attach` is safe only when the first disk is gone.
/// A fast mount or slice failure must not retry while that disk is still
/// attached, even when the mount helper itself did not time out.
func diskImageMayRetryCreate(
    publishedDisk: Bool,
    detachSucceeded: Bool,
    timedOut: Bool
) -> Bool {
    if timedOut { return false }
    if publishedDisk { return detachSucceeded }
    return true
}

/// Unlink only when the helper that could publish the disk has exited
/// and the detach of that disk exited 0. A detach that wins the race
/// while the parked attach is still in diskimagesd does not count.
func diskImageMayUnlinkPublishedImage(
    helperStillAlive: Bool,
    detachSucceeded: Bool,
    diskCanStillAppear: Bool = true
) -> Bool {
    if helperStillAlive || detachSucceeded == false || diskCanStillAppear { return false }
    return true
}

/// Retrying the preempted helper is safe only after its attach or mount
/// was actually removed, or the follow-up found nothing attached. A failed
/// detach of a disk that is still published must not retry into a second
/// disk. A peer that only needed the lock must not turn that miss into a
/// timed-out workspace setup: the preempted caller retries its own image.
/// A helper that is still alive can still publish, so it is not retried.
func diskImageMayRetryPreemptedHelper(
    cleanup: PreemptedDiskHelperCleanup,
    cleanupSucceeded: Bool,
    helperStillAlive: Bool = false,
    targetWasAbsent: Bool = false,
    diskCanStillAppear: Bool = false
) -> Bool {
    if helperStillAlive || diskCanStillAppear { return false }
    switch cleanup {
    case .none, .unlinkSparseImage:
        return true
    case .detachImage, .unmount:
        if cleanupSucceeded { return true }
        return targetWasAbsent
    }
}

/// Preempt cleanup may touch only the image or mount the preempted helper
/// itself was using. A `/dev/diskN` or another workspace path is not that
/// image: detaching it would take down a volume some other caller still owns.
func diskImageCleanupConfinedToCaller(_ plan: PreemptedDiskHelperCleanup) -> Bool {
    switch plan {
    case .none:
        return true
    case .unlinkSparseImage(let path), .detachImage(let path):
        return path.contains("rv-inode-") && path.hasSuffix(".sparseimage")
    case .unmount(let mount):
        return mount.hasPrefix("/") && mount.contains("\0") == false
    }
}

/// `hdiutil detach` / `umount` failed because the preempted helper had not
/// published a device. That is not "resource busy". The same caller can
/// run the helper again. A timeout is not absence.
func diskImageCleanupTargetWasAbsent(status: Int32, timedOut: Bool, output: String) -> Bool {
    if status == 0 || timedOut { return false }
    let text = output.lowercased()
    // "No such file" is not absence. diskimagesd can still publish the disk
    // the preempted attach handed it. "Not currently attached" is hdiutil
    // saying this image has no device.
    return text.contains("not currently attached")
        || text.contains("not attached")
        || text.contains("not currently mounted")
        || text.contains("not mounted")
}

/// The mutex closure always returns. A live helper, a disk that can still
/// appear, or a detach whose output contains "busy" keeps a publication
/// hold that blocks the next attach, create, or mount. Umount and detach
/// still proceed, so a cancelled peer can unmount. "busy" is not a reason
/// to stay inside `withLockIfAvailable`.
struct DiskImageSerializationExit: Equatable, Sendable {
    var closureReturned: Bool
    var publicationHeld: Bool
    var teardownMayProceed: Bool
    var mayStartNextAttach: Bool
}

func diskImageSerializationExit(
    helperStillAlive: Bool,
    diskCanStillAppear: Bool,
    detachOutputContainsBusy: Bool
) -> DiskImageSerializationExit {
    let held = helperStillAlive || diskCanStillAppear || detachOutputContainsBusy
    return DiskImageSerializationExit(
        closureReturned: true,
        publicationHeld: held,
        teardownMayProceed: true,
        mayStartNextAttach: held == false
    )
}

/// True keeps the publication hold. False clears it. A live helper, a busy
/// detach, or a disk that can still appear keeps the hold, including a hold
/// parked by an earlier attach. Umount and `hdiutil detach` are plan `.none`
/// and clear that hold only once the parked helper is dead and its disk
/// cannot appear. `returnBound` and `detachCap` are not involved.
func diskImagePublicationGateUpdate(
    plan: PreemptedDiskHelperCleanup,
    helperStillAlive: Bool,
    diskCanStillAppear: Bool,
    busy: Bool,
    parkedHelperStillAlive: Bool = false,
    parkedDiskCanStillAppear: Bool = false,
    publicationAlreadyHeld: Bool = false
) -> Bool {
    _ = plan
    if helperStillAlive || diskCanStillAppear || busy { return true }
    if publicationAlreadyHeld && (parkedHelperStillAlive || parkedDiskCanStillAppear) {
        return true
    }
    return false
}

/// One bounded recheck after the helper is dead. A listing that shows this
/// image keeps the hold. A sibling omission keeps it too: `ENOENT` after
/// the attach handed diskimagesd the fd is not absence, and a plist row
/// with no `image-path` is not this image being missing. An info timeout
/// is a nil listing and does not return `imageFileGone`. A successful
/// `images: []` (`parsedImageCount == 0`, parse succeeded) does clear an
/// image file that is actually gone, when nothing is attached. An
/// unparsed listing does not. A mount-point identity does not clear while
/// `/dev/diskN` can still appear: hdiutil omits `mount_hfs` paths, so an
/// attached sparseimage keeps that hold, and `st_dev` matching the parent
/// is the directory before the mount. This is not a spin out to the
/// 30-minute cap.
func diskImagePublicationRecheckCanClear(
    helperStillAlive: Bool,
    imageListed: Bool?,
    infoTimedOut: Bool = false,
    imageFileGone: Bool = false,
    identityIsImage: Bool = true,
    listingUnparsed: Bool = false,
    parsedImageCount: Int = 0,
    waitedForPublication: Bool = false,
    mountNotMounted: Bool = false
) -> Bool {
    if helperStillAlive { return false }
    if imageListed == true { return false }
    // Timeout before the nil keep. ENOENT while diskimagesd is still
    // publishing must not clear, including when a finished empty plist
    // with that same ENOENT would.
    if infoTimedOut { return false }
    if listingUnparsed { return false }
    if identityIsImage == false {
        // hdiutil does not see the kernel mount table, so a mount
        // identity clears only with stat proof nothing is mounted at
        // the path, after the publication wait, with the helper dead.
        return waitedForPublication && mountNotMounted
    }
    if waitedForPublication {
        // After the full publication wait with the helper dead, a
        // parsed listing that omits this image is absence: the device
        // cannot still appear, whether a sibling stays attached or a
        // leftover sparseimage file remains on disk. This matches
        // `diskImageCanStillAppear` with `waitedForPublication`.
        if imageListed == false { return true }
        if imageListed == nil && parsedImageCount == 0 { return true }
        return false
    }
    if imageListed == false || parsedImageCount > 0 { return false }
    // Parsed `images: []` only. A failed stat leaves `imageFileGone` false.
    if imageListed == nil { return imageFileGone }
    return false
}

/// How long the publication recheck may sleep or run `hdiutil info` without
/// pushing a cancelled waiter past the cancel clock. A nil deadline is the
/// full budget. `returnBound` and `detachCap` are not raised.
func diskImageRecheckAllowance(
    budget: TimeInterval,
    cancelDeadline: Date?,
    now: Date
) -> TimeInterval {
    let capped = max(0, budget)
    guard let cancelDeadline else { return capped }
    return min(capped, max(0, cancelDeadline.timeIntervalSince(now)))
}

/// `stat` failure is not absence. Only `ENOENT` means the sparseimage is
/// gone. `EIO` and `ESTALE` leave the hold, because the file can still exist.
func diskImageSparseFileIsDefinitivelyGone(_ path: String) -> Bool {
    var status = stat()
    if path.withCString({ stat($0, &status) }) == 0 { return false }
    return errno == ENOENT
}

/// A mount directory that shares its parent's device is not a gone volume:
/// that is the path before `mount_hfs`, and the path after `umount` while
/// `/dev/diskN` can still be attached. `EIO`, `ESTALE`, and `EACCES` are
/// not absence either. Only a missing path is.
func diskImageMountStatIsGone(statSucceeded: Bool, errnoValue: Int32) -> Bool {
    if statSucceeded { return false }
    return errnoValue == ENOENT
}

func diskImageMountPointIsGone(_ path: String) -> Bool {
    var here = stat()
    if path.withCString({ stat($0, &here) }) != 0 {
        return diskImageMountStatIsGone(statSucceeded: false, errnoValue: errno)
    }
    return diskImageMountStatIsGone(statSucceeded: true, errnoValue: 0)
}

/// Stat proof nothing is mounted at `path`: it is missing (`ENOENT`
/// only), or it shares its parent's device, so it is the plain
/// directory before `mount_hfs` or after `umount`. A mounted volume
/// has its own device. Any other stat failure is not proof.
func diskImageMountIsNotMounted(_ path: String) -> Bool {
    var here = stat()
    if path.withCString({ stat($0, &here) }) != 0 {
        return errno == ENOENT
    }
    let parent = (path as NSString).deletingLastPathComponent
    guard parent.isEmpty == false else { return false }
    var up = stat()
    guard parent.withCString({ stat($0, &up) }) == 0 else { return false }
    return here.st_dev == up.st_dev
}

/// The cancel clock the publication stat must stop on. A nil local deadline
/// still sees the shared clock `Flag.cancel()` armed. Both nil is a
/// non-cancelled acquire.
func diskImageRecheckStatDeadline(local: Date?, shared: Date?) -> Date? {
    switch (local, shared) {
    case let (local?, shared?):
        return min(local, shared)
    case let (local?, nil):
        return local
    case let (nil, shared?):
        return shared
    case (nil, nil):
        return nil
    }
}

enum DiskImageRecheckStatBudget: Equatable {
    /// Not cancelled. The stat is not clipped to a cancel clock.
    case uncancelled
    /// Time left on the cancel clock. Stop waiting when it is gone.
    case limited(TimeInterval)
    /// The clock is already due. Do not stat and do not clear.
    case skip
}

/// How long the publication stat may block. This is not a sample taken
/// only before the call: a stat that is still inside diskimagesd stops
/// at the end of `.limited`. `returnBound` and `detachCap` are not raised.
func diskImageRecheckStatBudget(cancelDeadline: Date?, now: Date) -> DiskImageRecheckStatBudget {
    guard let cancelDeadline else { return .uncancelled }
    let left = cancelDeadline.timeIntervalSince(now)
    if left <= 0 { return .skip }
    return .limited(left)
}

func diskImageRecheckMayStat(
    cancelDeadline: Date?,
    sharedCancelDeadline: Date? = nil,
    now: Date
) -> Bool {
    switch diskImageRecheckStatBudget(
        cancelDeadline: diskImageRecheckStatDeadline(
            local: cancelDeadline,
            shared: sharedCancelDeadline
        ),
        now: now
    ) {
    case .skip:
        return false
    case .uncancelled, .limited:
        return true
    }
}

/// The shared clock `Flag.cancel()` armed on this thread. A nil result is a
/// non-cancelled acquire. Polling this during a syscall is what stops the
/// call when cancel arms after the syscall has already started.
func diskImageLiveCancelDeadline(now: Date = Date()) -> Date? {
    if blockingWorkIsCancelled() {
        CooperativeLaunchStop.noteCancel(now: now)
    }
    return CooperativeLaunchStop.cancelClock?.deadline
}

/// When a blocking call must return. A live deadline that appears after the
/// call started still counts. `nil` means keep waiting.
func diskImageWaitStop(
    started: Date,
    allowance: TimeInterval?,
    liveDeadline: Date?
) -> Date? {
    let fromAllowance = allowance.map { started.addingTimeInterval($0) }
    switch (fromAllowance, liveDeadline) {
    case let (allowanceEnd?, live?):
        return min(allowanceEnd, live)
    case let (allowanceEnd?, nil):
        return allowanceEnd
    case let (nil, live?):
        return live
    case (nil, nil):
        return nil
    }
}

/// `hdiutil info` after a detach. The 1s cap is not the budget when the
/// shared cancel clock is sooner than the 45s slice. Zero does not start
/// the helper.
func diskImageListedInfoBudget(
    sliceDeadline: Date,
    localDeadline: Date?,
    sharedDeadline: Date?,
    now: Date = Date(),
    cap: TimeInterval = 1
) -> TimeInterval {
    let sliceLeft = max(0, sliceDeadline.timeIntervalSince(now))
    let cancelEnd = diskImageRecheckStatDeadline(local: localDeadline, shared: sharedDeadline)
    guard let cancelEnd else { return min(max(0, cap), sliceLeft) }
    let cancelLeft = max(0, cancelEnd.timeIntervalSince(now))
    return min(max(0, cap), sliceLeft, cancelLeft)
}

/// How long one tree-copy syscall may block. `nil` means no clock is armed.
/// Zero means the detach reserve is all that is left, so the call must not
/// start. The stop is before `returnBound`.
func diskImageTreeSyscallAllowance(deadline: Date?, now: Date = Date()) -> TimeInterval? {
    guard let deadline else { return nil }
    return DiskImageCancelBudget.copyBudget(timeLeft: deadline.timeIntervalSince(now)) ?? 0
}

/// Absolute stop for a tree syscall, reserving `detachCap`. `nil` means no
/// clock. A due copy budget returns `now` so the waiter does not stay in
/// the syscall.
func diskImageTreeCopyStop(deadline: Date?, now: Date = Date()) -> Date? {
    guard let deadline else { return nil }
    let budget = DiskImageCancelBudget.copyBudget(timeLeft: deadline.timeIntervalSince(now)) ?? 0
    if budget <= 0 { return now }
    return now.addingTimeInterval(budget)
}

/// `statfs` before `umount` uses the same cancel clock as the publication
/// stat. `.skip` does not call `statfs`. `.uncancelled` still calls it and
/// watches the shared clock while the call is in progress.
func diskImageMountStatAllowance(sharedDeadline: Date?, now: Date) -> DiskImageRecheckStatBudget {
    diskImageRecheckStatBudget(
        cancelDeadline: diskImageRecheckStatDeadline(local: nil, shared: sharedDeadline),
        now: now
    )
}

/// The detach follow-up after the publication wait. `diskImageCanStillAppear`
/// treats `imageListed == false` as gone once the wait has happened. The
/// recheck does not. A sibling omission, a row with no `image-path`, and a
/// file that is still on disk stay able to appear, including on `ENOENT`.
/// `imageFileGone` is that stat. A nil listing is unchanged.
func diskImageDetachFollowUpCanStillAppear(
    listingCanAppear: Bool,
    imageListed: Bool?,
    imageFileGone: Bool,
    parsedImageCount: Int = 0
) -> Bool {
    if imageListed == false {
        // Present file and ENOENT are the same keep. A pathless row is
        // this `false` with `parsedImageCount > 0`, not `images: []`.
        // The next acquire's recheck clears a parsed `images: []`.
        if imageFileGone == false { return true }
        return parsedImageCount >= 0
    }
    return listingCanAppear
}

/// Stat TOKEN only when the detach listing omitted it. A due clock does
/// not stat and does not report the file gone. A nil listing, including a
/// mount, does not take this stat.
func diskImageDetachFollowUpFileIsGone(
    identity: String,
    imageListed: Bool?,
    localDeadline: Date?,
    sharedDeadline: Date?,
    now: Date = Date()
) -> Bool {
    if imageListed != false { return false }
    let identityIsImage = identity.contains("rv-inode-") && identity.hasSuffix(".sparseimage")
    return diskImageStatObservingCancelClock(
        localDeadline: localDeadline,
        sharedDeadline: sharedDeadline,
        now: now
    ) {
        diskImageParkedPathIsGone(identity, identityIsImage: identityIsImage)
    } ?? false
}

func diskImageParkedPathIsGone(_ path: String, identityIsImage: Bool) -> Bool {
    if identityIsImage { return diskImageSparseFileIsDefinitivelyGone(path) }
    return diskImageMountPointIsGone(path)
}

/// `fcopyfile` returns 0 after `COPYFILE_QUIT`. That is not a copied attribute.
func fcopyfileAttributeCopySucceeded(toolStatus: Int32, statusQuit: Bool) -> Bool {
    statusQuit == false && toolStatus == 0
}

/// Drop the publication hold only when this helper is dead and the image
/// can no longer appear. `diskImageCanStillAppear` is that second fact:
/// a nil listing, or a non-empty listing that merely omitted this image
/// before the publication wait, stays true and must not clear. The gate's
/// bounded recheck is `diskImagePublicationRecheckCanClear`: a sibling
/// omission and an info timeout do not clear on `ENOENT`, and a parsed
/// `images: []` clears only an image file that is actually gone. A plan
/// `.none` umount or detach stores no image; once its helper is dead the
/// latch cannot publish and does drop. `returnBound` and `detachCap` are
/// not involved.
func diskImagePublicationCanClear(
    helperStillAlive: Bool,
    diskCanStillAppear: Bool,
    imageKnown: Bool = true
) -> Bool {
    if helperStillAlive { return false }
    if imageKnown == false { return true }
    return diskCanStillAppear == false
}

/// `diskImagePublicationGateUpdate` returning false does not by itself
/// forget a parked image. A `.none` call has no image of its own, so it
/// must not clear a parked path whose disk can still appear. It does drop
/// a hold that never stored an image once the helper is dead.
func diskImagePublicationHoldAfterUpdate(
    updateKeepsHold: Bool,
    planHasImage: Bool,
    parkedImageKnown: Bool,
    helperStillAlive: Bool,
    diskCanStillAppear: Bool
) -> Bool {
    if updateKeepsHold || helperStillAlive { return true }
    if planHasImage == false && parkedImageKnown == false { return false }
    if planHasImage == false { return true }
    return diskImagePublicationCanClear(
        helperStillAlive: false,
        diskCanStillAppear: diskCanStillAppear,
        imageKnown: true
    ) == false
}

/// One 45-second slice starts when this waiter begins acquiring the lock.
/// A later poll does not move that end. A cancelled waiter ignores it and
/// stops on the shared cancel clock instead. `returnBound` and `detachCap`
/// stay where they are.
func diskImageNextWaitDeadline(
    current: Date,
    now: Date,
    cancelled: Bool,
    cancelDeadline: Date?
) -> Date {
    _ = now
    if cancelled, let cancelDeadline { return cancelDeadline }
    return current
}

/// The 45-second slice starts once, when this waiter takes the lock. A
/// later poll does not move that end. While a peer still holds the lock
/// the slice stays unarmed, so queue time is not the boundary.
func diskImageAcquireSliceDeadline(
    armed: Date?,
    now: Date,
    slice: TimeInterval,
    peerHoldsLock: Bool
) -> Date? {
    if peerHoldsLock { return armed }
    if let armed { return armed }
    return now.addingTimeInterval(slice)
}

/// A non-cancelled establish that is only waiting on a peer does not fail
/// on the 45-second slice. That wait stops at `peerAcquireWait` (120s),
/// which is shorter than the 30-minute job cap. A waiter that holds the
/// lock still stops when its own 45-second slice is spent.
func diskImagePeerWaitFailsBoundary(
    peerHoldsLock: Bool,
    acquireSliceSpent: Bool,
    peerWaitSpent: Bool = false
) -> Bool {
    if peerHoldsLock { return peerWaitSpent }
    return acquireSliceSpent
}

func diskImageLockWaitIsExpired(
    cancelled: Bool,
    cancelClockSpent: Bool,
    acquireSliceSpent: Bool = false
) -> Bool {
    if cancelled { return cancelClockSpent }
    return acquireSliceSpent
}

/// The next helper may start when nothing is published, or when this call
/// is the umount / detach a cancelled peer needs. Attach, create, and
/// `mount_hfs` wait until the hold drops.
func diskImageMayStartHelper(publicationHeld: Bool, arguments: [String]) -> Bool {
    if publicationHeld == false { return true }
    switch PreemptedDiskHelperCleanup.plan(arguments: arguments) {
    case .none:
        return true
    case .unlinkSparseImage, .detachImage, .unmount:
        return false
    }
}

/// Detach exit 0 during establish is not the disk being gone, and it is
/// not `.cancelled`.
func establishCancelReportsCancelled(detachExitedZero: Bool) -> Bool {
    _ = detachExitedZero
    return false
}

/// Where a tree copy consults the one cancel clock. Bytes and xattrs share
/// it. A false xattr check must not call the xattr copy.
enum CopyClockPoint: Equatable, Sendable {
    case bytes
    case xattr
}

/// What `watchSeatbeltProcess` reports. `.cancelled` is only a dead leader.
/// A leader that is still alive at the end of the budget is not a finished
/// cancel and is not a lifetime miss. A real lifetime miss, with cancel
/// unset, stays a lifetime failure.
enum SeatbeltWatchDisposition: Equatable, Sendable {
    case cancelled
    case leaderStillAlive
    case lifetimeBoundaryFailed
    case proceed
}

func seatbeltWatchDisposition(cancelled: Bool, leaderDead: Bool) -> SeatbeltWatchDisposition {
    if cancelled && leaderDead == false { return .leaderStillAlive }
    if cancelled { return .cancelled }
    if leaderDead == false { return .lifetimeBoundaryFailed }
    return .proceed
}

/// Shared end for one cancelled teardown. The first `arm` wins. Later
/// helpers and the mutex wait consume what is left. Not armed until
/// cancellation is visible, so a non-cancel helper keeps its own deadline.
/// The end is monotonic: a wall-clock step during teardown must not
/// stretch the stop past `returnBound` or abort it early. `deadline`
/// is re-derived from that end on every read, so `Date`-based
/// consumers still observe the monotonic remainder.
final class DiskImageCancelClock: @unchecked Sendable {
    private let state = Mutex<ContinuousClock.Instant?>(nil)
    private let base = ContinuousClock()

    /// First call wins. `spentSinceCancel` shortens that end so a helper
    /// that already ran after the flag does not grant the next helper a
    /// fresh 7.75s on top of that time. `now` is the wall instant cancel
    /// was requested; only the elapsed interval at arm time is taken
    /// from it, never the absolute end.
    func arm(now: Date = Date(), spentSinceCancel: TimeInterval = 0) {
        state.withLock { end in
            if end == nil {
                let elapsed = max(0, Date().timeIntervalSince(now))
                let budget = DiskImageCancelBudget.sequenceRemaining(
                    spentSinceCancel: spentSinceCancel + elapsed
                )
                end = base.now.advanced(by: .seconds(budget))
            }
        }
    }

    private var monotonicRemaining: TimeInterval? {
        state.withLock { end in
            guard let end else { return nil }
            let left = base.now.duration(to: end)
            return max(
                0,
                TimeInterval(left.components.seconds)
                    + TimeInterval(left.components.attoseconds) / 1e18
            )
        }
    }

    var deadline: Date? {
        monotonicRemaining.map { Date().addingTimeInterval($0) }
    }

    var remaining: TimeInterval {
        monotonicRemaining ?? 0
    }
}
