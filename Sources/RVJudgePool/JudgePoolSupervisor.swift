import Dispatch
import Foundation

/// What a worker process produces, as seen by the supervisor.
public enum WorkerOutput: Sendable, Equatable {
    /// One complete frame body from the worker's stdout.
    case frame(Data)
    /// The process is gone and reaped; `description` is for the log.
    case exited(description: String)
}

/// One running worker process.
public protocol WorkerProcess: Sendable {
    /// Queues one complete frame for the worker's stdin. Never blocks.
    func send(_ frame: Data)
    /// SIGKILL. The only way to stop a Core ML prediction.
    func kill()
}

/// Starts worker processes. Production: `PosixWorkerSpawner`; tests inject
/// in-memory or scripted workers.
public protocol WorkerSpawning: Sendable {
    /// `output` may be called on any thread, any number of times, ending
    /// with exactly one `.exited`.
    func spawn(
        slot: WorkerSlot, key: ModelKey, output: @escaping @Sendable (WorkerOutput) -> Void
    ) throws -> any WorkerProcess
}

/// Runs `PoolCore` against real processes and a real clock: the imperative
/// shell around the pure state machine. Every mutable field is confined to
/// `queue`; public methods only enqueue.
public final class JudgePoolSupervisor: @unchecked Sendable {
    public typealias Instant = ContinuousClock.Instant

    private struct Running {
        let generation: UInt64
        let process: any WorkerProcess
    }

    private let queue = DispatchQueue(label: "dev.rv.judge.pool")
    private let spawner: any WorkerSpawning
    private let clock: @Sendable () -> Instant
    private let log: @Sendable (String) -> Void
    private var core: PoolCore
    private var running: [WorkerSlot: Running] = [:]
    private var completions: [String: @Sendable (PoolOutcome) -> Void] = [:]
    private var timer: DispatchSourceTimer?
    private var nextID: UInt64 = 0

    public init(
        policy: PoolPolicy = .live,
        spawner: any WorkerSpawning,
        clock: @escaping @Sendable () -> Instant = { ContinuousClock.now },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.core = PoolCore(policy: policy)
        self.spawner = spawner
        self.clock = clock
        self.log = log
    }

    /// Judges `input` with the model `key`; `completion` runs exactly once,
    /// within the pool budget (or `budget`, if shorter) of the call.
    public func submit(
        key: ModelKey, input: JudgeInput, budget: Duration,
        completion: @escaping @Sendable (PoolOutcome) -> Void
    ) {
        queue.async {
            self.nextID += 1
            let id = "j\(self.nextID)"
            self.completions[id] = completion
            self.apply(.submit(id: id, key: key, input: input, budget: budget))
        }
    }

    public func submit(key: ModelKey, input: JudgeInput, budget: Duration) async -> PoolOutcome {
        await withCheckedContinuation { continuation in
            submit(key: key, input: input, budget: budget) { continuation.resume(returning: $0) }
        }
    }

    public func warm(key: ModelKey) {
        queue.async { self.apply(.warm(key)) }
    }

    public func status() -> PoolStatus {
        queue.sync { core.status() }
    }

    /// Kills every worker. For shutdown and tests; the pool is not reused.
    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            for entry in running.values { entry.process.kill() }
        }
    }

    // MARK: - Queue-confined

    private func apply(_ event: PoolEvent) {
        let now = clock()
        for effect in core.handle(event, now: now) { perform(effect) }
        reschedule(after: now)
    }

    private func perform(_ effect: PoolEffect) {
        switch effect {
        case .spawn(let slot, let generation, let key):
            do {
                let process = try spawner.spawn(slot: slot, key: key) { [weak self] output in
                    self?.queue.async { self?.received(output, from: slot, generation: generation) }
                }
                running[slot] = Running(generation: generation, process: process)
                log("worker \(slot.rawValue) (\(slot.computeArgument)) spawned for \(key.engine)")
            } catch {
                log("worker \(slot.rawValue) spawn failed: \(error)")
                queue.async { self.apply(.exited(slot, generation: generation)) }
            }
        case .send(let slot, let generation, let request):
            guard let entry = running[slot], entry.generation == generation else { return }
            guard let frame = FrameStream.frame(json: request) else {
                queue.async { self.apply(.worker(slot, generation: generation, .failed(id: request.id))) }
                return
            }
            entry.process.send(frame)
        case .kill(let slot, let generation):
            guard let entry = running[slot], entry.generation == generation else { return }
            log("worker \(slot.rawValue) killed")
            entry.process.kill()
        case .reply(let id, let outcome):
            completions.removeValue(forKey: id)?(outcome)
        }
    }

    private func received(_ output: WorkerOutput, from slot: WorkerSlot, generation: UInt64) {
        switch output {
        case .frame(let body):
            guard let event = JudgePoolJSON.decode(WorkerEvent.self, from: body) else {
                log("worker \(slot.rawValue) sent an unreadable frame; killing it")
                if let entry = running[slot], entry.generation == generation { entry.process.kill() }
                return
            }
            switch event {
            case .ready(let checkpoint):
                log("worker \(slot.rawValue) ready (\(checkpoint))")
            case .loadFailed(let failure):
                log("worker \(slot.rawValue) could not load the model: \(failure.kind.rawValue)")
            case .verdict, .failed:
                break
            }
            apply(.worker(slot, generation: generation, event))
        case .exited(let description):
            log("worker \(slot.rawValue) exited (\(description))")
            if running[slot]?.generation == generation { running[slot] = nil }
            apply(.exited(slot, generation: generation))
        }
    }

    private func reschedule(after now: Instant) {
        timer?.cancel()
        timer = nil
        guard let wake = core.nextWake(after: now) else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + Self.dispatchInterval(wake - now))
        source.setEventHandler { [weak self] in self?.apply(.tick) }
        timer = source
        source.resume()
    }

    static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
        let parts = duration.components
        let nanos = parts.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !nanos.overflow else { return .seconds(Int(min(parts.seconds, Int64(Int32.max)))) }
        let total = nanos.partialValue + parts.attoseconds / 1_000_000_000
        // Round up so the tick never lands just before the deadline.
        return .nanoseconds(Int(max(1, total + 1)))
    }
}
