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

    /// The publication recheck (sleep + `hdiutil info` + stat) is
    /// optional work inside the serialization lock, and
    /// `cancelledSequenceBudget` does not count it. While a priority
    /// waiter is queued on the cancel clock, running it spends that
    /// waiter's umount slices, so the holder skips it and releases
    /// sooner; the hold simply clears on a later unhurried acquire.
    static func mayRunPublicationRecheck(
        priorityWaiterQueued: Bool,
        cancelClockArmed: Bool
    ) -> Bool {
        priorityWaiterQueued && cancelClockArmed ? false : true
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

    /// Plist parse missed the device. Find a `/dev/disk*` in the text,
    /// including inside plist XML (`<string>/dev/disk4</string>`).
    /// `hdiutil detach` accepts only a devname or mount point, so the
    /// image path is never a valid target: no device in the text means
    /// nil, and the caller must fail closed instead of detaching by image.
    static func detachTargetWhenPlistMissesDisk(
        image: String,
        plistStdout: String,
        mountPoint: String
    ) -> String? {
        _ = image
        _ = mountPoint
        return firstDiskDevice(in: plistStdout)
    }

    /// First `/dev/diskN` (whole disk, slice suffix stripped) in `text`.
    static func firstDiskDevice(in text: String) -> String? {
        var search = text[...]
        while let range = search.range(of: "/dev/disk") {
            let rest = search[range.lowerBound...]
            var end = rest.startIndex
            while end < rest.endIndex,
                rest[end].isNumber || rest[end].isLetter || rest[end] == "/"
            {
                end = rest.index(after: end)
            }
            if let device = wholeDiskDevice(String(rest[..<end])) {
                return device
            }
            search = search[range.upperBound...]
        }
        return nil
    }

    /// `/dev/disk4s1` → `/dev/disk4`. Nil for anything that is not a
    /// `/dev/disk<digits>` optionally followed by `s<digits>`.
    static func wholeDiskDevice(_ candidate: String) -> String? {
        guard candidate.hasPrefix("/dev/disk") else { return nil }
        var rest = candidate.dropFirst("/dev/disk".count)
        var digits = ""
        while let first = rest.first, first.isNumber {
            digits.append(first)
            rest = rest.dropFirst()
        }
        guard digits.isEmpty == false else { return nil }
        if rest.isEmpty { return "/dev/disk" + digits }
        guard rest.first == "s" else { return nil }
        let slice = rest.dropFirst()
        guard slice.isEmpty == false, slice.allSatisfy(\.isNumber) else { return nil }
        return "/dev/disk" + digits
    }

    /// `hdiutil detach` argv for a resolved device.
    static func detachArguments(device: String) -> [String] {
        ["/usr/bin/hdiutil", "detach", "-force", "-quiet", device]
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
