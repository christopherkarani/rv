import Dispatch
import RVDomain
import RVIPC
import RVPolicy
import Synchronization

/// Answers `policyStatus` without letting status requests stall hooks.
///
/// The load is synchronous file I/O plus a ceiling containment check that
/// can take seconds over a large repo layer. Run on the cooperative pool
/// (one thread per core), a few concurrent requests would park every pool
/// thread, the same hazard `JudgeOffload` exists for. So the load runs on
/// its own Dispatch queue, and at most `limit` run at once: the route is
/// `.diagnostic` (any local peer may call it), so past the cap it answers
/// `busy` at once instead of queueing more blocked threads. A slot frees
/// when its load returns, not when its caller gives up.
final class PolicyStatusService: Sendable {
    typealias Load = @Sendable (HomeDirectory?, WorkingDirectory?) -> PolicyLoadStatus

    static let defaultLimit = 2

    private let limit: Int
    private let load: Load
    private let running = Mutex(0)
    private let queue = DispatchQueue(label: "rv.policy-status", qos: .utility, attributes: .concurrent)

    init(limit: Int = PolicyStatusService.defaultLimit, load: @escaping Load = PolicyStoreInputs.loadStatus) {
        self.limit = limit
        self.load = load
    }

    func status(home: HomeDirectory?, cwd: WorkingDirectory?) async -> PolicyStatusReply {
        let admitted = running.withLock { count in
            guard count < limit else { return false }
            count += 1
            return true
        }
        guard admitted else { return .busy }
        return await withCheckedContinuation { continuation in
            queue.async {
                let status = self.load(home, cwd)
                self.running.withLock { $0 -= 1 }
                continuation.resume(returning: .status(status))
            }
        }
    }
}
