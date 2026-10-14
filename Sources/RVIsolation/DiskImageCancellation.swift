#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization

/// Budgets for a cancelled workspace-volume teardown.
///
/// `cancellationTerminatesOwnedProcessesBeforeReturn` requires the executor
/// to return within 8 seconds. That bound is not raised here. The detach
/// cap stays 5 seconds. One preempted helper is reaped, and a preempted
/// attach or mount is detached or unmounted, before the next helper starts.
/// Those two costs plus both cancelled `umount`s plus the detach stay
/// under 8 seconds even when they do not overlap.
enum DiskImageCancelBudget {
    /// Existing cancellation return bound. Do not raise.
    static let returnBound: TimeInterval = 8
    /// Expected reap of one SIGKILL'd non-urgent helper. The serialization
    /// lock is not released while that process is still alive; this is the
    /// time the 8-second bound allots for a helper that can actually die.
    static let preemptReap: TimeInterval = 0.25
    /// `reapLeaderStatus` after the session leader is SIGKILL'd. Same
    /// quarter-second the sequence budget already counts. It is not added
    /// again in front of a fresh detach clock.
    static let leaderReap: TimeInterval = preemptReap
    /// `waitUntilSessionIsDead` when cancel is not set. On the cancel path
    /// this cap is shortened by time already spent, so a wedged leader
    /// cannot run two seconds and then start a new 7.75s detach.
    static let sessionDeathWait: TimeInterval = 2
    /// Detach or forced unmount of a preempted attach or mount, still
    /// inside the serialization lock, before the next helper starts.
    static let preemptCleanup: TimeInterval = 0.5
    /// `hdiutil detach` on the cancelled path. Do not raise.
    static let detachCap: TimeInterval = 5
    /// How long a non-cancelled waiter may queue for the disk lock before
    /// the boundary fails. Longer than the 45-second slice that starts
    /// after the lock is taken, shorter than the 30-minute job cap.
    static let peerAcquireWait: TimeInterval = 120
    /// Plain `umount` and `umount -f` together, on the cancelled path only.
    /// Short enough that both, the 5-second detach, and the existing
    /// half-second SIGTERM grace on each of those three helpers still
    /// return inside 8 seconds.
    static let unmountWindow: TimeInterval = 1

    struct Helpers: Equatable, Sendable {
        var plainUnmount: TimeInterval
        var forceUnmount: TimeInterval
        var detach: TimeInterval
    }

    static func cancelledDetachHelpers() -> Helpers {
        Helpers(
            plainUnmount: unmountWindow / 2,
            forceUnmount: unmountWindow / 2,
            detach: detachCap
        )
    }

    /// SIGTERM-to-SIGKILL grace already in `runToolBody`. Counted so a
    /// peer that dies on schedule is not treated as shorter than it is.
    static let signalGrace: TimeInterval = 0.5

    /// One cancelled teardown, including the mutex wait. Strictly inside
    /// `returnBound`. Longer than plain+grace, force+grace, and detach+grace
    /// (7.5s), so a waiter behind that peer is still inside its budget when
    /// the peer releases, and still returns before 8 seconds.
    static var cancelledSequenceBudget: TimeInterval {
        let peer = (unmountWindow / 2) + signalGrace
            + (unmountWindow / 2) + signalGrace
            + detachCap + signalGrace
        return peer + preemptReap
    }

    /// Mutex wait once cancellation is visible. `nil` and `45` are the
    /// historical default; neither is returned. A shorter per-helper slice
    /// does not expire the wait either. Elapsed time since cancel counts
    /// inside this budget, so the waiter returns before `returnBound`.
    static func lockWait(elapsedSinceCancel: TimeInterval, callerDeadline: TimeInterval?) -> TimeInterval {
        let remaining = cancelledSequenceBudget - max(0, elapsedSinceCancel)
        let capped = max(0, remaining)
        if let callerDeadline, callerDeadline >= 45 {
            return min(capped, callerDeadline)
        }
        return capped
    }

    /// An urgent holder yields when another waiter is queued, unless this
    /// acquire was granted a turn after it already waited or was preempted.
    /// That turn is one helper, so two cancelled teardowns do not livelock.
    /// A non-urgent holder always yields. One missed lock must not let a
    /// 45-second create or attach ignore a cancelled waiter; that waiter
    /// still has to unmount its volume.
    static func yieldsToWaiter(
        otherWaiters: Int,
        protectThisAcquire: Bool,
        holderIsUrgent: Bool = true
    ) -> Bool {
        guard otherWaiters > 0 else { return false }
        if holderIsUrgent == false { return true }
        return protectThisAcquire == false
    }

    /// Time left on the one cancel clock after `spentSinceCancel`. A later
    /// helper does not receive a fresh `cancelledSequenceBudget` on top of
    /// time the in-flight tool, the leader reap, or the session-death poll
    /// already used after the flag flipped.
    static func sequenceRemaining(spentSinceCancel: TimeInterval) -> TimeInterval {
        max(0, cancelledSequenceBudget - max(0, spentSinceCancel))
    }

    /// Leader reap and the session-death poll stop at what the one clock
    /// still has. `cap` is `leaderReap` or `sessionDeathWait`.
    static func boundedWait(spentSinceCancel: TimeInterval, cap: TimeInterval) -> TimeInterval {
        min(max(0, cap), sequenceRemaining(spentSinceCancel: spentSinceCancel))
    }

    /// Wall time from cancel through the leader reap, the session-death
    /// poll, and a detach that uses only the remainder. Stacking a fresh
    /// `cancelledSequenceBudget` after those waits is not under `returnBound`.
    static func wholeSequenceWallTime(reap: TimeInterval, sessionWait: TimeInterval) -> TimeInterval {
        let spent = max(0, reap) + max(0, sessionWait)
        return spent + sequenceRemaining(spentSinceCancel: spent)
    }

    static func wholeSequenceStaysUnderReturnBound(
        reap: TimeInterval,
        sessionWait: TimeInterval
    ) -> Bool {
        wholeSequenceWallTime(reap: reap, sessionWait: sessionWait) < returnBound
    }

    /// How long a tree copy may run on the one cancel clock. The detach
    /// slice is reserved first, so a copy cannot spend the time `hdiutil
    /// detach` still needs. `nil` means no clock is armed and the copy is
    /// not clipped. `returnBound` and `detachCap` are not raised.
    static func copyBudget(timeLeft: TimeInterval?) -> TimeInterval? {
        guard let timeLeft else { return nil }
        let left = max(0, timeLeft)
        let reserve = min(detachCap, left)
        return max(0, left - reserve)
    }

    /// Wall time when `copySeconds` is clipped to `copyBudget` and detach
    /// then uses the reserved remainder. A copy longer than the clock does
    /// not push the return to `returnBound`.
    static func cancelReturnWithClippedCopy(
        copySeconds: TimeInterval,
        timeLeft: TimeInterval
    ) -> TimeInterval {
        let budget = copyBudget(timeLeft: timeLeft) ?? 0
        let ran = min(max(0, copySeconds), budget)
        let afterCopy = max(0, timeLeft - ran)
        return ran + min(detachCap, afterCopy)
    }

    /// True while the copy still has time that is not reserved for detach.
    static func copyMayContinue(deadline: Date?, now: Date = Date()) -> Bool {
        guard let deadline else { return true }
        let budget = copyBudget(timeLeft: deadline.timeIntervalSince(now)) ?? 0
        return budget > 0
    }

    /// Detach still has a positive slice after a copy that used `budget`.
    static func detachStillFits(afterCopy budget: TimeInterval, timeLeft: TimeInterval) -> Bool {
        let after = max(0, timeLeft) - max(0, budget)
        return after > 0
    }

    /// Cap for an umount or detach that is already running when cancel
    /// flips. `callerDeadline` of 45 or 8 is the snapshot the helper
    /// started with. The result is the urgent slice, and it also shrinks
    /// by time already spent after cancel, so the caller is back inside
    /// `returnBound` from the flag. Create, attach, and mount return nil
    /// from `urgentDeadline` and are not passed here.
    static func inFlightLimit(
        callerDeadline: TimeInterval?,
        spentSinceCancel: TimeInterval,
        arguments: [String]
    ) -> TimeInterval {
        let left = sequenceRemaining(spentSinceCancel: spentSinceCancel)
        let urgent = urgentDeadline(arguments: arguments) ?? left
        var cap = min(urgent, left)
        if let callerDeadline {
            cap = min(cap, max(0, callerDeadline))
        }
        return max(0, cap)
    }

    /// Force `umount` once cancellation is visible. This is the 0.5s the
    /// sequence budget already counts, not `remaining - 1`. A longer slice
    /// lets one protected holder run until the other teardown's clock
    /// expires, and that volume stays mounted.
    static func cancelledForceSlice(remaining: TimeInterval) -> TimeInterval {
        min(cancelledDetachHelpers().forceUnmount, max(0, remaining))
    }

    /// True when a waiter whose peer has already held the lock for
    /// `peerHold` still has both cancelled umount slices left. The
    /// accounted peer is force plus one signal grace. A multi-second
    /// force hold is not.
    static func waiterCanUnmount(peerHold: TimeInterval) -> Bool {
        let helpers = cancelledDetachHelpers()
        let need = helpers.plainUnmount + helpers.forceUnmount
        return sequenceRemaining(spentSinceCancel: peerHold) >= need
    }

    /// Reap after SIGKILL. Never open-ended. Also stops at the teardown's
    /// return deadline so a D-state helper cannot hold the caller past 8s.
    static func reapSlice(until returnDeadline: Date, now: Date) -> TimeInterval {
        min(preemptReap, max(0, returnDeadline.timeIntervalSince(now)))
    }

    /// Follow-up detach or unmount counts only when it exits 0 before its
    /// deadline. A timeout or nonzero status is not cleanup.
    static func preemptCleanupSucceeded(status: Int32, timedOut: Bool) -> Bool {
        status == 0 && timedOut == false
    }

    /// Plist parse missed the device. Detach a `/dev/disk*` in the text,
    /// otherwise the image. Never the mount point: that is not the disk
    /// `hdiutil attach` published.
    static func detachTargetWhenPlistMissesDisk(
        image: String,
        plistStdout: String,
        mountPoint: String
    ) -> String {
        if let disk = plistStdout.split(whereSeparator: \.isWhitespace).map(String.init).first(where: {
            $0.hasPrefix("/dev/disk")
        }) {
            return disk
        }
        // `mountPoint` is the workspace path, not the disk attach published.
        if image == mountPoint, image.hasPrefix("/dev/disk") {
            return image
        }
        return image
    }

    /// Deadline for an `umount` or `hdiutil detach` once cancellation is
    /// visible. Create, attach, and mount keep the caller's deadline for
    /// the running helper. The mutex wait uses `lockWait`, not this slice
    /// and not the 45-second default.
    static func urgentDeadline(arguments: [String]) -> TimeInterval? {
        guard let executable = arguments.first else { return nil }
        let helpers = cancelledDetachHelpers()
        switch executable {
        case "/sbin/umount":
            if arguments.dropFirst().contains("-f") {
                return helpers.forceUnmount
            }
            return helpers.plainUnmount
        case "/usr/bin/hdiutil":
            if arguments.dropFirst().first == "detach" {
                return helpers.detach
            }
            return nil
        default:
            return nil
        }
    }

    /// True when the cancelled detach helpers, one preempt reap, and one
    /// preempt cleanup fit in the existing return bound without raising
    /// the detach cap.
    static func withinReturnBound(_ helpers: Helpers = cancelledDetachHelpers()) -> Bool {
        let sum = helpers.plainUnmount
            + helpers.forceUnmount
            + helpers.detach
            + preemptReap
            + preemptCleanup
        return sum < returnBound
            && helpers.detach <= detachCap
            && helpers.plainUnmount > 0
            && helpers.forceUnmount > 0
            && helpers.plainUnmount + helpers.forceUnmount <= unmountWindow
    }
}

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
    var followUpArguments: [String]? {
        switch self {
        case .none, .unlinkSparseImage:
            return nil
        case .detachImage(let image):
            return ["/usr/bin/hdiutil", "detach", "-force", "-quiet", image]
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
    parsedImageCount: Int = 0
) -> Bool {
    if helperStillAlive { return false }
    if imageListed == true { return false }
    // Timeout before the nil keep. ENOENT while diskimagesd is still
    // publishing must not clear, including when a finished empty plist
    // with that same ENOENT would.
    if infoTimedOut { return false }
    // `imageListed == true` is not the only keep. hdiutil does not see
    // the kernel mount table. An attached sparseimage, a pre-mount
    // directory, and EIO/ESTALE/EACCES are not a gone volume.
    if identityIsImage == false { return false }
    if listingUnparsed || imageListed == false || parsedImageCount > 0 { return false }
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

private final class DiskImageStatResult: @unchecked Sendable {
    private let state = Mutex<Bool?>(nil)

    func store(_ gone: Bool) {
        state.withLock { $0 = gone }
    }

    func current() -> Bool? {
        state.withLock { $0 }
    }
}

/// Wait for one stat. `nil` allowance is the non-cancelled path. A positive
/// allowance returns nil once that time is gone, even if the stat has not
/// returned. Zero does not start the stat.
func diskImageWaitForStat(
    allowance: TimeInterval?,
    stat: @escaping @Sendable () -> Bool
) -> Bool? {
    if let allowance, allowance <= 0 { return nil }
    let box = DiskImageStatResult()
    let worker = Thread {
        box.store(stat())
    }
    let started = Date()
    worker.start()
    while true {
        if let gone = box.current() { return gone }
        if let allowance, Date().timeIntervalSince(started) >= allowance {
            return nil
        }
        usleep(1_000)
    }
}

/// One publication stat on the cancel clock. `nil` means the clock was
/// already due, or the stat was still blocked when the allowance ended, so
/// the caller must not clear. A nil local deadline still sees the shared
/// clock. Both nil runs the stat with no cancel clip.
func diskImageStatObservingCancelClock(
    localDeadline: Date?,
    sharedDeadline: Date?,
    now: Date = Date(),
    stat: @escaping @Sendable () -> Bool
) -> Bool? {
    let end = diskImageRecheckStatDeadline(local: localDeadline, shared: sharedDeadline)
    switch diskImageRecheckStatBudget(cancelDeadline: end, now: now) {
    case .skip:
        return nil
    case .uncancelled:
        return stat()
    case .limited(let allowance):
        return diskImageWaitForStat(allowance: allowance, stat: stat)
    }
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

/// `/var` and `/private/var` are the same image, and so are `/tmp` and
/// `/private/tmp`, and a `/System/Volumes/Data` firmlink of either. A
/// symlink that does not resolve still matches the same `rv-inode-` file
/// name. Exact string equality is not what `hdiutil info` returns.
func diskImageCanonicalPath(_ path: String) -> String {
    let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
    let resolved = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().standardizedFileURL.path
    let foldedResolved = diskImageFoldVolumeAlias(resolved)
    if foldedResolved != resolved { return foldedResolved }
    return diskImageFoldVolumeAlias(standardized)
}

func diskImageFoldVolumeAlias(_ path: String) -> String {
    let data = "/System/Volumes/Data"
    var text = path
    if text == data {
        text = "/"
    } else if text.hasPrefix(data + "/") {
        text = String(text.dropFirst(data.count))
        if text.isEmpty { text = "/" }
    }
    return diskImageFoldPrivatePrefix(text)
}

func diskImageFoldPrivatePrefix(_ path: String) -> String {
    if path == "/private/var" { return "/var" }
    if path == "/private/tmp" { return "/tmp" }
    let variable = "/private/var/"
    if path.hasPrefix(variable) {
        return "/var/" + path.dropFirst(variable.count)
    }
    let temporary = "/private/tmp/"
    if path.hasPrefix(temporary) {
        return "/tmp/" + path.dropFirst(temporary.count)
    }
    return path
}

func diskImageFoldPrivateVar(_ path: String) -> String {
    diskImageFoldPrivatePrefix(path)
}

func diskImageSameWorkspaceImageName(_ lhs: String, _ rhs: String) -> Bool {
    let left = URL(fileURLWithPath: lhs).standardizedFileURL.lastPathComponent
    let right = URL(fileURLWithPath: rhs).standardizedFileURL.lastPathComponent
    guard left == right, left.hasPrefix("rv-inode-"), left.hasSuffix(".sparseimage") else {
        return false
    }
    return left.count > "rv-inode-.sparseimage".count
}

func diskImageSamePath(_ lhs: String, _ rhs: String) -> Bool {
    if lhs == rhs { return true }
    if diskImageCanonicalPath(lhs) == diskImageCanonicalPath(rhs) { return true }
    return diskImageSameWorkspaceImageName(lhs, rhs)
}

func diskImageSameDevice(_ lhs: String, _ rhs: String) -> Bool {
    var left = stat()
    var right = stat()
    let statedLeft = lhs.withCString { stat($0, &left) == 0 }
    let statedRight = rhs.withCString { stat($0, &right) == 0 }
    guard statedLeft, statedRight else { return false }
    return left.st_dev == right.st_dev
}

/// An empty `hdiutil info`, or a mount point hdiutil does not report, is
/// not proof the disk is gone. `nil` keeps `diskImageCanStillAppear` true.
/// A non-empty listing that omits an image path is the only false result.
/// The same image under `/var` and `/private/var` is still listed.
func diskImageInfoListingShowsImage(
    parsedImageCount: Int,
    identity: String,
    imagePaths: [String],
    mountPoints: [String] = []
) -> Bool? {
    if parsedImageCount == 0 { return nil }
    let isImage = identity.contains("rv-inode-") && identity.hasSuffix(".sparseimage")
    if isImage {
        return imagePaths.contains { diskImageSamePath($0, identity) }
    }
    if mountPoints.contains(where: { diskImageSamePath($0, identity) }) { return true }
    if imagePaths.contains(where: { diskImageSamePath($0, identity) }) { return true }
    return nil
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

func directoryReadMayContinue(_ mayContinue: Bool) -> Bool {
    mayContinue
}

/// `readdir` stops while detach time is still left. A partial listing is
/// not a snapshot: the caller fails the copy instead of publishing it.
func readDirectoryNamesStoppingForDetachReserve(
    _ path: String,
    mayContinue: () -> Bool
) -> [String]? {
    if directoryReadMayContinue(mayContinue()) == false { return nil }
    guard let dir = opendir(path) else { return nil }
    defer { closedir(dir) }
    var names: [String] = []
    while true {
        if directoryReadMayContinue(mayContinue()) == false { return nil }
        errno = 0
        guard let entry = readdir(dir) else {
            if errno != 0 { return nil }
            break
        }
        let name = directoryEntryName(entry)
        if name == "." || name == ".." { continue }
        names.append(name)
    }
    return names
}

/// Same stop, on a directory fd. `fdopendir` consumes a duplicate so the
/// caller's fd stays open.
func readDirectoryNames(
    _ dirfd: Int32,
    mayContinue: () -> Bool
) -> [String]? {
    if directoryReadMayContinue(mayContinue()) == false { return nil }
    let copy = dup(dirfd)
    guard copy >= 0 else { return nil }
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
        if directoryReadMayContinue(mayContinue()) == false { return nil }
        errno = 0
        guard let entry = readdir(dir) else {
            if errno != 0 { return nil }
            break
        }
        let name = directoryEntryName(entry)
        if name == "." || name == ".." { continue }
        names.append(name)
    }
    return names
}

private func directoryEntryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
    withUnsafePointer(to: &entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: 1024) {
            String(cString: $0)
        }
    }
}

/// File bytes in `chunkBytes` slices. The xattr copy runs only after the
/// bytes finish and the same clock still allows it, so it cannot spend the
/// detach reserve. A stop returns false and does not call `copyXattr`.
func copyFileLeavingDetachReserve(
    from source: Int32,
    to destination: Int32,
    chunkBytes: Int = 64 * 1024,
    mayContinue: (CopyClockPoint) -> Bool,
    copyXattr: (_ source: Int32, _ destination: Int32) -> Bool
) -> Bool {
    let size = chunkBytes > 0 ? chunkBytes : 64 * 1024
    var buffer = [UInt8](repeating: 0, count: size)
    while true {
        if mayContinue(.bytes) == false { return false }
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            while true {
                let readCount = read(source, base, raw.count)
                if readCount < 0, errno == EINTR { continue }
                return readCount
            }
        }
        if count == 0 { break }
        if count < 0 { return false }
        if mayContinue(.bytes) == false { return false }
        var written = 0
        while written < count {
            let chunk = buffer.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                while true {
                    let wrote = write(destination, base.advanced(by: written), count - written)
                    if wrote < 0, errno == EINTR { continue }
                    return wrote
                }
            }
            if chunk <= 0 { return false }
            written += chunk
        }
    }
    if mayContinue(.xattr) == false { return false }
    return copyXattr(source, destination)
}

/// A clock stop is not a successful publish, including when a row was
/// already rejected or a staged copy wrote only part of a file.
enum SavedTreePublish: Equatable, Sendable {
    case success
    case failed
}

func savedTreePublishOutcome(
    clockAllowsCopy: Bool,
    rejected: Bool,
    stagedCopyFinished: Bool
) -> SavedTreePublish {
    if clockAllowsCopy == false || rejected || stagedCopyFinished == false {
        return .failed
    }
    return .success
}

/// The original inode is replaced only after the staged copy finished and
/// the clock still leaves the detach reserve. Otherwise the original stays.
func mayReplaceSavedFile(stagedCopyFinished: Bool, clockAllowsCopy: Bool) -> Bool {
    stagedCopyFinished && clockAllowsCopy
}

/// Result of replacing one saved inode from a staged copy.
///
/// `mayRenameOntoWorkspace` is false when `ftruncate` already ran and the
/// backup could not be written back under the clock. That file must not be
/// renamed onto the workspace. A stop before `ftruncate` leaves the original
/// bytes in place, so the saved tree may still be restored.
struct SavedReplaceOutcome: Equatable, Sendable {
    var committed: Bool
    var reachedTruncate: Bool
    var originalIntact: Bool
    var mayRenameOntoWorkspace: Bool
}

func savedTreeMayRenameOntoWorkspace(originalIntact: Bool, restoreFinished: Bool) -> Bool {
    originalIntact && restoreFinished
}

/// Stage `source` onto a temp file. `ftruncate` of `original` runs only
/// when that stage finished and the clock still allows the commit. A clock
/// stop before that leaves `original` untouched. A stop after `ftruncate`
/// restores from the backup under the same clock. It does not force the
/// clock on. A short restore puts the backup file back at `originalPath`
/// and reports that the tree must not be renamed onto the workspace.
func replaceOriginalOnlyAfterStagedCopy(
    source: Int32,
    original: Int32,
    originalPath: String? = nil,
    mayContinue: (CopyClockPoint) -> Bool,
    copyXattr: (_ source: Int32, _ destination: Int32) -> Bool
) -> SavedReplaceOutcome {
    func untouched() -> SavedReplaceOutcome {
        SavedReplaceOutcome(
            committed: false,
            reachedTruncate: false,
            originalIntact: true,
            mayRenameOntoWorkspace: true
        )
    }
    if mayContinue(.bytes) == false { return untouched() }
    let stagedURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-stage-\(UUID().uuidString)")
    let staged = stagedURL.path.withCString { path in
        open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
    }
    guard staged >= 0 else { return untouched() }
    defer {
        close(staged)
        unlink(stagedURL.path)
    }
    guard copyFileLeavingDetachReserve(
        from: source,
        to: staged,
        mayContinue: mayContinue,
        copyXattr: copyXattr
    ) else { return untouched() }
    guard mayReplaceSavedFile(
        stagedCopyFinished: true,
        clockAllowsCopy: mayContinue(.bytes)
    ) else { return untouched() }
    let backupURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-backup-\(UUID().uuidString)")
    let backup = backupURL.path.withCString { path in
        open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
    }
    guard backup >= 0 else { return untouched() }
    var consumedBackup = false
    defer {
        close(backup)
        if consumedBackup == false { unlink(backupURL.path) }
    }
    guard lseek(original, 0, SEEK_SET) == 0 else { return untouched() }
    guard copyFileLeavingDetachReserve(
        from: original,
        to: backup,
        mayContinue: mayContinue,
        copyXattr: { _, _ in true }
    ) else { return untouched() }
    guard mayReplaceSavedFile(
        stagedCopyFinished: true,
        clockAllowsCopy: mayContinue(.bytes)
    ) else { return untouched() }
    guard lseek(staged, 0, SEEK_SET) == 0, lseek(original, 0, SEEK_SET) == 0 else {
        return untouched()
    }
    guard ftruncate(original, 0) == 0 else { return untouched() }
    let committed = copyFileLeavingDetachReserve(
        from: staged,
        to: original,
        mayContinue: mayContinue,
        copyXattr: copyXattr
    )
    if committed {
        return SavedReplaceOutcome(
            committed: true,
            reachedTruncate: true,
            originalIntact: true,
            mayRenameOntoWorkspace: true
        )
    }
    return restoreBackupAfterTruncate(
        original: original,
        originalPath: originalPath,
        backup: backup,
        backupURL: backupURL,
        mayContinue: mayContinue,
        consumedBackup: &consumedBackup
    )
}

func restoreBackupAfterTruncate(
    original: Int32,
    originalPath: String?,
    backup: Int32,
    backupURL: URL,
    mayContinue: (CopyClockPoint) -> Bool,
    consumedBackup: inout Bool
) -> SavedReplaceOutcome {
    let backupSize = descriptorSize(backup)
    if mayContinue(.bytes) {
        _ = lseek(backup, 0, SEEK_SET)
        _ = lseek(original, 0, SEEK_SET)
        let restored = copyFileLeavingDetachReserve(
            from: backup,
            to: original,
            mayContinue: mayContinue,
            copyXattr: { _, _ in true }
        )
        if restored, let backupSize, descriptorSize(original) == backupSize {
            return SavedReplaceOutcome(
                committed: false,
                reachedTruncate: true,
                originalIntact: true,
                mayRenameOntoWorkspace: true
            )
        }
    }
    if let originalPath {
        switch installBackupFile(
            backupURL,
            over: originalPath,
            backup: backup,
            mayContinue: mayContinue
        ) {
        case .restored:
            consumedBackup = true
            return SavedReplaceOutcome(
                committed: false,
                reachedTruncate: true,
                originalIntact: true,
                mayRenameOntoWorkspace: false
            )
        case .preservedBackup:
            consumedBackup = true
            return SavedReplaceOutcome(
                committed: false,
                reachedTruncate: true,
                originalIntact: false,
                mayRenameOntoWorkspace: false
            )
        case .failed:
            break
        }
    }
    return SavedReplaceOutcome(
        committed: false,
        reachedTruncate: true,
        originalIntact: false,
        mayRenameOntoWorkspace: false
    )
}

enum BackupInstall: Equatable, Sendable {
    case restored
    case preservedBackup
    case failed
}

func descriptorSize(_ fd: Int32) -> off_t? {
    var status = stat()
    guard fstat(fd, &status) == 0 else { return nil }
    return status.st_size
}

func installBackupFile(
    _ backupURL: URL,
    over path: String,
    backup: Int32,
    mayContinue: (CopyClockPoint) -> Bool
) -> BackupInstall {
    if diskImageSameDevice(backupURL.path, path) {
        let renamed = installBackupByRename(backupURL, over: path, backup: backup)
        if renamed { return .restored }
        if errno == EXDEV {
            return installBackupAcrossDevices(
                backupURL,
                over: path,
                backup: backup,
                mayContinue: mayContinue
            )
        }
        return .failed
    }
    return installBackupAcrossDevices(
        backupURL,
        over: path,
        backup: backup,
        mayContinue: mayContinue
    )
}

func installBackupByRename(_ backupURL: URL, over path: String, backup: Int32) -> Bool {
    let aside = path + ".rv-truncated"
    let moved: Bool = path.withCString { original in
        aside.withCString { asidePath in
            unlink(asidePath)
            return rename(original, asidePath) == 0
        }
    }
    guard moved else { return false }
    let installed: Bool = backupURL.path.withCString { backupPath in
        path.withCString { original in
            rename(backupPath, original) == 0
        }
    }
    guard installed else {
        let renameError = errno
        _ = aside.withCString { asidePath in
            path.withCString { original in
                rename(asidePath, original)
            }
        }
        errno = renameError
        return false
    }
    _ = aside.withCString { unlink($0) }
    var restored = stat()
    let stated = path.withCString { stat($0, &restored) == 0 }
    guard stated else { return false }
    guard let backupSize = descriptorSize(backup) else { return false }
    return restored.st_size == backupSize
}

/// `rename` from `temporaryDirectory` onto a saved tree on another volume
/// is `EXDEV`. Copy under the same clock onto a sibling on the destination
/// volume, then rename that sibling. A short copy removes the truncated
/// inode and leaves the backup in place.
func installBackupAcrossDevices(
    _ backupURL: URL,
    over path: String,
    backup: Int32,
    mayContinue: (CopyClockPoint) -> Bool
) -> BackupInstall {
    let staging = path + ".rv-restore"
    let staged = staging.withCString { open($0, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, mode_t(0o600)) }
    guard staged >= 0 else {
        unlinkTruncatedSaved(path)
        return .preservedBackup
    }
    defer {
        close(staged)
        unlink(staging)
    }
    _ = lseek(backup, 0, SEEK_SET)
    let copied = copyFileLeavingDetachReserve(
        from: backup,
        to: staged,
        mayContinue: mayContinue,
        copyXattr: { _, _ in true }
    )
    let stagedSize = descriptorSize(staged)
    let backupSize = descriptorSize(backup)
    let complete = copied && stagedSize == backupSize && stagedSize != nil
    guard complete else {
        unlinkTruncatedSaved(path)
        return .preservedBackup
    }
    let replaced = staging.withCString { stage in
        path.withCString { destination in
            rename(stage, destination) == 0
        }
    }
    if replaced { return .restored }
    unlinkTruncatedSaved(path)
    return .preservedBackup
}

func unlinkTruncatedSaved(_ path: String) {
    _ = path.withCString { unlink($0) }
}

/// Records how large a single xattr get or set was. A user attribute is
/// transferred in `chunkBytes` windows. One `fgetxattr` or `fsetxattr` of
/// the whole value is not a chunked copy.
final class XattrCopyTrace: @unchecked Sendable {
    var largestRead = 0
    var largestWrite = 0
    var forkBytesWritten = 0
    var fcopyfileInvoked = false

    func noteRead(_ count: Int) {
        if count > largestRead { largestRead = count }
    }

    func noteWrite(_ count: Int) {
        if count > largestWrite { largestWrite = count }
    }

    func noteFork(_ count: Int) {
        if count > forkBytesWritten { forkBytesWritten = count }
    }

    func noteFcopyfile() {
        fcopyfileInvoked = true
    }
}

/// A failed path lookup must not skip the named fork. That skip is what
/// lets one unbounded copy of `..namedfork/rsrc` run with no further clock
/// check. No resolved path means the copy stops.
func namedForkCopyStarts(pathResolved: Bool) -> Bool {
    pathResolved
}

/// Copy extended attributes in slices that keep checking the clock.
/// A false return stops before the detach reserve is spent. A name other
/// than `com.apple.ResourceFork` is read and written in `chunkBytes`
/// windows, not one get and one set of the whole value. A Darwin resource
/// fork is read in 64KB slices.
func copyXattrsObservingClock(
    from source: Int32,
    to destination: Int32,
    chunkBytes: Int = 64 * 1024,
    trace: XattrCopyTrace = XattrCopyTrace(),
    mayContinue: () -> Bool
) -> Bool {
    if mayContinue() == false { return false }
    #if canImport(Darwin)
    if copyResourceForkObservingClock(from: source, to: destination, mayContinue: mayContinue) == false {
        return false
    }
    #endif
    let names = listXattrNames(source)
    for name in names where name != "com.apple.ResourceFork" {
        if copyOneXattrObservingClock(
            from: source,
            to: destination,
            name: name,
            chunkBytes: chunkBytes,
            trace: trace,
            mayContinue: mayContinue
        ) == false {
            return false
        }
    }
    return true
}

/// One user attribute. Each window checks the clock, then gets or sets only
/// that many bytes. A value the kernel will not return in one window stops
/// the copy instead of falling back to a single read of the whole value.
func copyOneXattrObservingClock(
    from source: Int32,
    to destination: Int32,
    name: String,
    chunkBytes: Int,
    trace: XattrCopyTrace,
    mayContinue: () -> Bool
) -> Bool {
    let needed = name.withCString { xattrValueSize(source, $0) }
    guard needed >= 0 else { return false }
    if needed == 0 { return mayContinue() }
    let step = max(1, chunkBytes)
    var offset = 0
    var gathered = [UInt8]()
    gathered.reserveCapacity(min(needed, step))
    while offset < needed {
        if mayContinue() == false { return false }
        let length = min(step, needed - offset)
        guard let window = readXattrWindow(source, name, offset: offset, length: length) else {
            return false
        }
        if window.count != length { return false }
        trace.noteRead(window.count)
        // The get can finish inside the budget. That is not the set.
        if mayContinue() == false { return false }
        gathered.append(contentsOf: window)
        offset += window.count
    }
    if gathered.count > step { return false }
    if mayContinue() == false { return false }
    // Immediately before `fsetxattr`. The detach reserve can be gone
    // even though the get finished inside the budget.
    if xattrSetKeepsDetachReserve(mayContinue: mayContinue) == false { return false }
    trace.noteWrite(gathered.count)
    return writeXattr(destination, name, gathered)
}

/// The clock read that sits on the set itself. A true result from the
/// post-get check does not skip this one.
func xattrSetKeepsDetachReserve(mayContinue: () -> Bool) -> Bool {
    mayContinue()
}

/// Gets at most `length` bytes and only from `offset` zero. A larger value
/// returns nil instead of one `fgetxattr` of the whole attribute. Darwin's
/// position argument is not used for names other than the resource fork.
func readXattrWindow(_ fd: Int32, _ name: String, offset: Int, length: Int) -> [UInt8]? {
    if offset != 0 || length <= 0 { return nil }
    let needed = name.withCString { xattrValueSize(fd, $0) }
    if needed < 0 || needed > length { return nil }
    var buffer = [UInt8](repeating: 0, count: length)
    let got = buffer.withUnsafeMutableBytes { raw in
        name.withCString { item in
            xattrValue(fd, item, raw.baseAddress, length)
        }
    }
    guard got == needed, got >= 0 else { return nil }
    return Array(buffer.prefix(got))
}

/// Walk `byteCount` in chunks. Each chunk checks the clock before it counts.
/// A large resource fork that starts with budget left stops while detach
/// time remains.
func copyXattrBytesObservingClock(
    byteCount: Int,
    chunkBytes: Int = 64 * 1024,
    mayContinue: () -> Bool
) -> Bool {
    if byteCount == 0 { return mayContinue() }
    let step = max(1, chunkBytes)
    var offset = 0
    while offset < byteCount {
        if mayContinue() == false { return false }
        offset += min(step, byteCount - offset)
    }
    return mayContinue()
}

func listXattrNames(_ fd: Int32) -> [String] {
    let needed = xattrListSize(fd)
    guard needed > 0 else { return [] }
    var buffer = [CChar](repeating: 0, count: needed)
    let listed = buffer.withUnsafeMutableBufferPointer { raw in
        xattrList(fd, raw.baseAddress, needed)
    }
    guard listed > 0 else { return [] }
    var names: [String] = []
    var start = 0
    let bytes = buffer.map { UInt8(bitPattern: $0) }
    let count = min(listed, bytes.count)
    var index = 0
    while index < count {
        if bytes[index] == 0 {
            if index > start {
                let slice = bytes[start..<index]
                names.append(String(decoding: slice, as: UTF8.self))
            }
            start = index + 1
        }
        index += 1
    }
    return names
}

func readXattr(_ fd: Int32, _ name: String) -> [UInt8]? {
    let needed = name.withCString { xattrValueSize(fd, $0) }
    guard needed >= 0 else { return nil }
    if needed == 0 { return [] }
    var buffer = [UInt8](repeating: 0, count: needed)
    let read = buffer.withUnsafeMutableBytes { raw in
        name.withCString { item in
            xattrValue(fd, item, raw.baseAddress, needed)
        }
    }
    guard read == needed else { return nil }
    return buffer
}

func writeXattr(_ fd: Int32, _ name: String, _ value: [UInt8]) -> Bool {
    value.withUnsafeBytes { raw in
        name.withCString { item in
            xattrWrite(fd, item, raw.baseAddress, value.count) == 0
        }
    }
}

#if canImport(Darwin)
func copyResourceForkObservingClock(
    from source: Int32,
    to destination: Int32,
    trace: XattrCopyTrace = XattrCopyTrace(),
    mayContinue: () -> Bool
) -> Bool {
    guard let sourcePath = pathForFileDescriptor(source),
        let destinationPath = pathForFileDescriptor(destination)
    else { return namedForkCopyStarts(pathResolved: false) }
    let sourceFork = sourcePath + "/..namedfork/rsrc"
    let destinationFork = destinationPath + "/..namedfork/rsrc"
    let src = sourceFork.withCString { open($0, O_RDONLY | O_CLOEXEC) }
    if src < 0 { return true }
    defer { close(src) }
    let dst = destinationFork.withCString { open($0, O_RDWR | O_CREAT | O_CLOEXEC, mode_t(0o600)) }
    guard dst >= 0 else { return false }
    defer { close(dst) }
    let copied = copyFileLeavingDetachReserve(
        from: src,
        to: dst,
        mayContinue: { _ in mayContinue() },
        copyXattr: { _, _ in true }
    )
    trace.noteFork(Int(descriptorSize(dst) ?? 0))
    return copied
}

func pathForFileDescriptor(_ fd: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    // Darwin's pointer overlay. The variadic C `fcntl` is unavailable in Swift.
    guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
    let count = buffer.firstIndex(of: 0) ?? buffer.count
    return String(decoding: buffer[..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func copyXattrsWithFcopyfile(
    from source: Int32,
    to destination: Int32,
    trace: XattrCopyTrace = XattrCopyTrace(),
    mayContinue: @escaping () -> Bool
) -> Bool {
    if mayContinue() == false { return false }
    // `fcopyfile` copies the other attributes. The named fork is skipped
    // there and copied in 64KB slices so a short clock stops during it.
    // A status callback that quits does not skip that slice copy.
    let attributesCopied = copyXattrsByFcopyfile(
        from: source,
        to: destination,
        trace: trace,
        mayContinue: mayContinue
    )
    let forkCopied = copyResourceForkObservingClock(
        from: source,
        to: destination,
        trace: trace,
        mayContinue: mayContinue
    )
    return attributesCopied && forkCopied
}

private final class FcopyfileClockBox {
    let mayContinue: () -> Bool
    var statusQuit = false
    var skippedNames: [String] = []
    init(_ mayContinue: @escaping () -> Bool) {
        self.mayContinue = mayContinue
    }
}

private func xattrFcopyfileStatus(
    _ what: Int32,
    _ stage: Int32,
    _ state: copyfile_state_t?,
    _ src: UnsafePointer<CChar>?,
    _ dst: UnsafePointer<CChar>?,
    _ ctx: UnsafeMutableRawPointer?
) -> Int32 {
    _ = what
    _ = stage
    _ = src
    _ = dst
    guard let ctx else { return COPYFILE_QUIT }
    let box = Unmanaged<FcopyfileClockBox>.fromOpaque(ctx).takeUnretainedValue()
    var attributeName: String?
    if let state {
        var name: UnsafePointer<CChar>?
        let read = withUnsafeMutablePointer(to: &name) { pointer in
            copyfile_state_get(
                state,
                UInt32(COPYFILE_STATE_XATTRNAME),
                UnsafeMutableRawPointer(pointer)
            )
        }
        if read == 0, let name {
            if strcmp(name, "com.apple.ResourceFork") == 0 { return COPYFILE_SKIP }
            attributeName = String(cString: name)
        }
    }
    if box.mayContinue() == false {
        box.statusQuit = true
        return COPYFILE_QUIT
    }
    // A true clock at `COPYFILE_START` is not permission to `fsetxattr`
    // the whole value. Skip it here and copy it with a check on the set.
    if let attributeName {
        box.skippedNames.append(attributeName)
    }
    return COPYFILE_SKIP
}

private func copyXattrsByFcopyfile(
    from source: Int32,
    to destination: Int32,
    trace: XattrCopyTrace,
    mayContinue: @escaping () -> Bool
) -> Bool {
    guard let state = copyfile_state_alloc() else { return false }
    defer { copyfile_state_free(state) }
    let box = FcopyfileClockBox(mayContinue)
    let context = Unmanaged.passUnretained(box).toOpaque()
    // `copyfile_state_set` stores the pointer bits as the callback and the
    // context. The address of a local that holds those pointers is not
    // `xattrFcopyfileStatus`, so the status function would never run.
    let callback = xattrFcopyfileStatus as copyfile_callback_t
    let callbackBits = unsafeBitCast(callback, to: UInt.self)
    guard let callbackPointer = UnsafeRawPointer(bitPattern: callbackBits) else { return false }
    let contextSet = copyfile_state_set(
        state,
        UInt32(COPYFILE_STATE_STATUS_CTX),
        UnsafeRawPointer(context)
    )
    let callbackSet = copyfile_state_set(
        state,
        UInt32(COPYFILE_STATE_STATUS_CB),
        callbackPointer
    )
    guard contextSet == 0, callbackSet == 0 else { return false }
    trace.noteFcopyfile()
    let status = fcopyfile(source, destination, state, copyfile_flags_t(COPYFILE_XATTR))
    // `COPYFILE_QUIT` sets `ECANCELED` and still returns 0. That is not success.
    guard fcopyfileAttributeCopySucceeded(toolStatus: status, statusQuit: box.statusQuit) else {
        return false
    }
    for name in box.skippedNames where name != "com.apple.ResourceFork" {
        if copyOneXattrObservingClock(
            from: source,
            to: destination,
            name: name,
            chunkBytes: 64 * 1024,
            trace: trace,
            mayContinue: mayContinue
        ) == false {
            return false
        }
    }
    return true
}

private func xattrListSize(_ fd: Int32) -> Int {
    flistxattr(fd, nil, 0, 0)
}

private func xattrList(_ fd: Int32, _ buffer: UnsafeMutablePointer<CChar>?, _ size: Int) -> Int {
    flistxattr(fd, buffer, size, 0)
}

private func xattrValueSize(_ fd: Int32, _ name: UnsafePointer<CChar>) -> Int {
    fgetxattr(fd, name, nil, 0, 0, 0)
}

private func xattrValue(
    _ fd: Int32,
    _ name: UnsafePointer<CChar>,
    _ buffer: UnsafeMutableRawPointer?,
    _ size: Int
) -> Int {
    fgetxattr(fd, name, buffer, size, 0, 0)
}

private func xattrWrite(
    _ fd: Int32,
    _ name: UnsafePointer<CChar>,
    _ buffer: UnsafeRawPointer?,
    _ size: Int
) -> Int32 {
    fsetxattr(fd, name, buffer, size, 0, 0)
}
#else
@_silgen_name("flistxattr")
private func rv_flistxattr(_ fd: Int32, _ list: UnsafeMutableRawPointer?, _ size: Int) -> Int

@_silgen_name("fgetxattr")
private func rv_fgetxattr(
    _ fd: Int32,
    _ name: UnsafePointer<CChar>,
    _ value: UnsafeMutableRawPointer?,
    _ size: Int
) -> Int

@_silgen_name("fsetxattr")
private func rv_fsetxattr(
    _ fd: Int32,
    _ name: UnsafePointer<CChar>,
    _ value: UnsafeRawPointer?,
    _ size: Int,
    _ flags: Int32
) -> Int32

private func xattrListSize(_ fd: Int32) -> Int {
    rv_flistxattr(fd, nil, 0)
}

private func xattrList(_ fd: Int32, _ buffer: UnsafeMutablePointer<CChar>?, _ size: Int) -> Int {
    guard let buffer else { return rv_flistxattr(fd, nil, size) }
    return buffer.withMemoryRebound(to: UInt8.self, capacity: size) { raw in
        rv_flistxattr(fd, raw, size)
    }
}

private func xattrValueSize(_ fd: Int32, _ name: UnsafePointer<CChar>) -> Int {
    rv_fgetxattr(fd, name, nil, 0)
}

private func xattrValue(
    _ fd: Int32,
    _ name: UnsafePointer<CChar>,
    _ buffer: UnsafeMutableRawPointer?,
    _ size: Int
) -> Int {
    rv_fgetxattr(fd, name, buffer, size)
}

private func xattrWrite(
    _ fd: Int32,
    _ name: UnsafePointer<CChar>,
    _ buffer: UnsafeRawPointer?,
    _ size: Int
) -> Int32 {
    rv_fsetxattr(fd, name, buffer, size, 0)
}
#endif

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
final class DiskImageCancelClock: @unchecked Sendable {
    private let state = Mutex<Date?>(nil)

    /// First call wins. `spentSinceCancel` shortens that end so a helper
    /// that already ran after the flag does not grant the next helper a
    /// fresh 7.75s on top of that time.
    func arm(now: Date = Date(), spentSinceCancel: TimeInterval = 0) {
        state.withLock { end in
            if end == nil {
                let budget = DiskImageCancelBudget.sequenceRemaining(spentSinceCancel: spentSinceCancel)
                end = now.addingTimeInterval(budget)
            }
        }
    }

    var deadline: Date? {
        state.withLock { $0 }
    }

    var remaining: TimeInterval {
        guard let deadline else { return 0 }
        return max(0, deadline.timeIntervalSinceNow)
    }
}
