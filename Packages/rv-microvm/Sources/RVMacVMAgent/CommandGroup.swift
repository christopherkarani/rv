import Darwin
import Synchronization

/// The process group the command's first process leads. Its id belongs to
/// the group until the leader is reaped, so the group is signalled only
/// before `reap`, under the same lock: a recycled pid is never signalled.
final class CommandGroup: Sendable {
    let leader: pid_t
    private let state = Mutex((exited: false, reaped: false))

    init(leader: pid_t) {
        self.leader = leader
    }

    /// True once the leader has exited (reaped or not).
    var hasExited: Bool { state.withLock { $0.exited } }

    /// Sends `number` to the group unless the leader was already reaped.
    func signal(_ number: Int32) {
        state.withLock { if !$0.reaped { _ = kill(-leader, number) } }
    }

    /// Blocks until the leader exits, leaving it unreaped (a zombie).
    func waitForExit() {
        var info = siginfo_t()
        while waitid(P_PID, id_t(leader), &info, WEXITED | WNOWAIT) < 0, errno == EINTR {}
        state.withLock { $0.exited = true }
    }

    /// Reaps the leader; returns its wait status. No signal is sent after.
    func reap() -> Int32 {
        state.withLock { state in
            var status: Int32 = 0
            while waitpid(leader, &status, 0) < 0, errno == EINTR {}
            state = (true, true)
            return status
        }
    }
}
