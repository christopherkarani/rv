#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Synchronization

/// One stdio launch's end, as a restart of its server waits for it: set
/// once its process group is reaped (a placeholder server's lease revoked
/// with it).
final class MCPLaunchEnd: Sendable {
    private let ended = Mutex(false)

    /// The launch's group is reaped.
    func end() {
        ended.withLock { $0 = true }
    }

    var hasEnded: Bool {
        ended.withLock { $0 }
    }

    /// How a wait for launches to end came out.
    enum Wait: Equatable {
        /// Every launch has ended.
        case ended
        /// `deadline` passed first.
        case timedOut
        /// Serve is stopping: nothing is planned, ended or not.
        case abandoned
    }

    /// Polls until every one of `ends` has ended, `deadline` passes, or
    /// `abandoned` holds, which is asked first each time. The deadline is
    /// on the monotonic clock: a wall-clock step neither cuts it short nor
    /// stretches it.
    static func wait(
        for ends: [MCPLaunchEnd], until deadline: SuspendingClock.Instant, abandoned: () -> Bool
    ) -> Wait {
        while true {
            if abandoned() { return .abandoned }
            if ends.allSatisfy(\.hasEnded) { return .ended }
            guard SuspendingClock.now < deadline else { return .timedOut }
            usleep(10_000)
        }
    }
}
