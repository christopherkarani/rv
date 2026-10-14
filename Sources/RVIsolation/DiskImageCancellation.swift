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
