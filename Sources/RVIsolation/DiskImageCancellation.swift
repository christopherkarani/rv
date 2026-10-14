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
    /// That turn is one helper, so two cancelled teardowns do not livelock
    /// and the second is not left waiting out the first's full sequence.
    static func yieldsToWaiter(otherWaiters: Int, protectThisAcquire: Bool) -> Bool {
        otherWaiters > 0 && protectThisAcquire == false
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
    cleanupFinished: Bool
) -> Bool {
    if helperStillAlive && reapExpired == false { return false }
    // The reap deadline passed and the helper is still alive (D-state).
    // Park it and return. Waiting for it to exit misses the 8-second bound.
    if helperStillAlive && reapExpired { return true }
    switch cleanup {
    case .none:
        return true
    case .unlinkSparseImage, .detachImage, .unmount:
        return cleanupFinished
    }
}

/// Retrying the preempted helper is safe only after its attach or mount
/// was actually removed. A failed detach must not retry into a second disk,
/// and must not unlink the image that is still the detach path.
func diskImageMayRetryPreemptedHelper(
    cleanup: PreemptedDiskHelperCleanup,
    cleanupSucceeded: Bool
) -> Bool {
    switch cleanup {
    case .none, .unlinkSparseImage:
        return true
    case .detachImage, .unmount:
        return cleanupSucceeded
    }
}

/// Shared end for one cancelled teardown. The first `arm` wins. Later
/// helpers and the mutex wait consume what is left. Not armed until
/// cancellation is visible, so a non-cancel helper keeps its own deadline.
final class DiskImageCancelClock: @unchecked Sendable {
    private let state = Mutex<Date?>(nil)

    func arm(now: Date = Date()) {
        state.withLock { end in
            if end == nil {
                end = now.addingTimeInterval(DiskImageCancelBudget.cancelledSequenceBudget)
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
