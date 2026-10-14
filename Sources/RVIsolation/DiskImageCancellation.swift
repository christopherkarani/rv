import Foundation

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

    /// Deadline for an `umount` or `hdiutil detach` once cancellation is
    /// visible. Create, attach, and mount keep the caller's deadline:
    /// they are not the cancelled detach sequence. A nil result means
    /// this helper is not part of that sequence.
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
    cleanup: PreemptedDiskHelperCleanup,
    cleanupFinished: Bool
) -> Bool {
    if helperStillAlive { return false }
    switch cleanup {
    case .none:
        return true
    case .unlinkSparseImage, .detachImage, .unmount:
        return cleanupFinished
    }
}
