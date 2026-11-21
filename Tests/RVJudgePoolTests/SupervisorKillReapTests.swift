#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization
import Testing
@testable import RVJudgePool

/// When the supervisor's own kill clears a worker's Core ML marker: only
/// for a worker whose guard had started (its marker is its own) and that
/// was actually ended by SIGKILL (not a real abort racing the kill).
@Suite("Judge pool: clearing the marker after the supervisor's kill")
struct SupervisorKillReapTests {
    /// The primary's first generation reports its guard (or not), then
    /// sends an unreadable frame, which the supervisor kills it for; its
    /// exit carries `signal`. Every later worker is ready at once.
    final class ScriptedSpawner: WorkerSpawning, Sendable {
        let guardStarted: Bool
        let signal: Int32?
        private let spawned = Mutex(0)

        init(guardStarted: Bool, signal: Int32?) {
            self.guardStarted = guardStarted
            self.signal = signal
        }

        func spawn(
            slot: WorkerSlot, compute: WorkerCompute, key: ModelKey, output: @escaping @Sendable (WorkerOutput) -> Void
        ) throws -> any WorkerProcess {
            let first = slot == .primary && spawned.withLock { count in
                defer { count += 1 }
                return count == 0
            }
            let guardStarted = guardStarted
            DispatchQueue.global().async {
                if first {
                    if guardStarted { output(.frame(JudgePoolJSON.encode(WorkerEvent.guardStarted)!)) }
                    output(.frame(Data("not json".utf8)))
                } else {
                    output(.frame(JudgePoolJSON.encode(WorkerEvent.ready(checkpoint: "fake"))!))
                }
            }
            return Worker(signal: signal, output: output)
        }
    }

    final class Worker: WorkerProcess, Sendable {
        let signal: Int32?
        let output: @Sendable (WorkerOutput) -> Void
        let exited = Mutex(false)

        init(signal: Int32?, output: @escaping @Sendable (WorkerOutput) -> Void) {
            self.signal = signal
            self.output = output
        }

        func send(_ frame: Data) {}

        func kill() {
            let first = exited.withLock { done -> Bool in
                defer { done = true }
                return !done
            }
            guard first else { return }
            let signal = signal
            DispatchQueue.global().async { self.output(.exited(description: "test", signal: signal)) }
        }
    }

    final class Reaped: Sendable {
        let slots = Mutex<[WorkerSlot]>([])
    }

    @Test("cleared only for a guarded worker that SIGKILL ended", arguments: [
        (true, SIGKILL, true),
        (false, SIGKILL, false),
        (true, SIGABRT, false),
        (true, nil, false),
    ] as [(Bool, Int32?, Bool)])
    func clearsOnlyAfterGuardedSigkill(guardStarted: Bool, signal: Int32?, cleared: Bool) async throws {
        let reaped = Reaped()
        let supervisor = JudgePoolSupervisor(
            policy: PoolPolicy(backoffBase: .milliseconds(20)),
            spawner: ScriptedSpawner(guardStarted: guardStarted, signal: signal),
            reapedAfterKill: { slot, _ in reaped.slots.withLock { $0.append(slot) } })
        defer { supervisor.stop() }
        supervisor.warm(key: ModelKey(engine: "ft", bundle: "/models/fake"))
        let end = Date().addingTimeInterval(10)
        while Date() < end, (supervisor.status().workers.first { $0.slot == .primary }?.restarts ?? 0) < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        // The decision is made on the queue before the exit is applied, so
        // it is settled once the replacement has been spawned.
        #expect((supervisor.status().workers.first { $0.slot == .primary }?.restarts ?? 0) >= 1)
        #expect(reaped.slots.withLock { $0 } == (cleared ? [.primary] : []))
    }
}
