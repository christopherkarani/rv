import Foundation

/// Everything that can happen to the pool.
public enum PoolEvent: Sendable, Equatable {
    case submit(id: String, key: ModelKey, input: JudgeInput, budget: Duration)
    case warm(ModelKey)
    case worker(WorkerSlot, generation: UInt64, WorkerEvent)
    /// The worker process is gone (exited, killed, or its pipe broke).
    case exited(WorkerSlot, generation: UInt64)
    /// Time passed; the driver calls this at `nextWake`.
    case tick
}

/// What the driver must do. `generation` names one worker process: effects
/// and events for an older process of the same slot are ignored.
public enum PoolEffect: Sendable, Equatable {
    case spawn(WorkerSlot, generation: UInt64, key: ModelKey)
    case send(WorkerSlot, generation: UInt64, WorkerRequest)
    case kill(WorkerSlot, generation: UInt64)
    case reply(id: String, PoolOutcome)
}

/// The pool's decisions as a pure state machine: events in, effects out, no
/// processes, threads or clocks. `JudgePoolSupervisor` drives it.
///
/// Routing: a request goes to the primary worker when it is idle. When the
/// primary is busy it waits up to `primaryBusyWait` for it, then goes to the
/// hedge; when the primary is down, loading or degraded it goes to the hedge
/// at once. If the first worker has not answered after `hedgeAfter`,
/// the other worker gets it too; the first verdict wins. A worker still
/// busy `budget` after it was handed a request is killed and respawned
/// (backoff), and its request moves to the other worker if that one has not
/// tried it. A prediction failure moves the request the same way. A worker
/// that faults `faultsToDegrade` times inside `faultWindow` is degraded:
/// everything routes to the other worker until `degradeCooldown` passes.
/// One prediction per worker; at most one worker loads at a time (primary
/// first), so the two never compile the model cache concurrently.
public struct PoolCore: Sendable {
    public typealias Instant = ContinuousClock.Instant

    enum Phase: Sendable, Equatable {
        case down(retryAt: Instant?)
        case loading(generation: UInt64, since: Instant)
        case idle(generation: UInt64)
        case busy(generation: UInt64, request: String, sentAt: Instant)
        case stopping(generation: UInt64, fault: Bool)

        var generation: UInt64? {
            switch self {
            case .down: nil
            case .loading(let g, _), .idle(let g), .busy(let g, _, _), .stopping(let g, _): g
            }
        }

        var name: String {
            switch self {
            case .down: "down"
            case .loading: "loading"
            case .idle: "ready"
            case .busy: "busy"
            case .stopping: "stopping"
            }
        }
    }

    struct Worker: Sendable {
        var phase: Phase = .down(retryAt: nil)
        var faults: [Instant] = []
        var restarts = 0
        var backoffStep = 0
        var degradedUntil: Instant?
        var loadFailure: LoadFailure?
        var spawnedOnce = false

        var isDegraded: Bool { degradedUntil != nil }
        var hasLoaded: Bool {
            switch phase {
            case .idle, .busy: true
            default: false
            }
        }
    }

    struct Pending: Sendable {
        let input: JudgeInput
        let answerBy: Instant
        let queuedAt: Instant
        /// Workers computing it now, and when each got it.
        var active: [WorkerSlot: Instant] = [:]
        /// Workers that have been handed it (computing, answered, or died).
        var tried: Set<WorkerSlot> = []
        var first: WorkerSlot?
    }

    struct Counters: Sendable, Equatable {
        var served = 0
        var hedged = 0
        var hedgeWins = 0
        var killed = 0
        var late = 0
        var refusedBusy = 0
    }

    public let policy: PoolPolicy
    public private(set) var key: ModelKey?
    private(set) var workers: [WorkerSlot: Worker] = [.primary: Worker(), .hedge: Worker()]
    private var queue: [String] = []
    private var pending: [String: Pending] = [:]
    private var nextGeneration: UInt64 = 1
    private var keyChangedAt: Instant?
    private(set) var counters = Counters()
    private var effects: [PoolEffect] = []

    public init(policy: PoolPolicy = .live) {
        self.policy = policy
    }

    /// Applies one event at `now` and returns the effects, in order.
    public mutating func handle(_ event: PoolEvent, now: Instant) -> [PoolEffect] {
        effects = []
        switch event {
        case .submit(let id, let key, let input, let budget):
            submit(id: id, key: key, input: input, budget: budget, now: now)
        case .warm(let key):
            if key.isWellFormed, mayAdopt(key, now: now) { adopt(key, now: now) }
        case .worker(let slot, let generation, let event):
            workerEvent(slot, generation: generation, event, now: now)
        case .exited(let slot, let generation):
            exited(slot, generation: generation, now: now)
        case .tick:
            break
        }
        pump(now: now)
        return effects
    }

    /// The next instant after `now` at which time alone changes something.
    /// Work that is due but blocked (a hedge with no idle worker, a spawn
    /// behind a loading worker) waits for an event instead, so the driver
    /// never spins.
    public func nextWake(after now: Instant) -> Instant? {
        var times: [Instant] = []
        for request in pending.values {
            times.append(request.answerBy)
            if request.active.count == 1, let (slot, sentAt) = request.active.first,
               !request.tried.contains(slot.other) {
                times.append(sentAt + policy.hedgeAfter)
            }
            if request.active.isEmpty, waitsForPrimary(request) {
                times.append(request.queuedAt + policy.primaryBusyWait)
            }
        }
        for worker in workers.values {
            switch worker.phase {
            case .busy(_, _, let sentAt): times.append(sentAt + policy.budget)
            case .loading(_, let since): times.append(since + policy.loadTimeout)
            case .down(let retryAt?) where key != nil: times.append(retryAt)
            default: break
            }
            if let until = worker.degradedUntil { times.append(until) }
        }
        return times.filter { $0 > now }.min()
    }

    public func status() -> PoolStatus {
        PoolStatus(
            protocolVersion: JudgePoolWire.protocolVersion,
            engine: key?.engine,
            workers: WorkerSlot.allCases.map { slot in
                let worker = workers[slot] ?? Worker()
                return PoolStatus.Worker(
                    slot: slot, compute: policy.compute(for: slot).rawValue, phase: worker.phase.name,
                    restarts: worker.restarts, recentFaults: worker.faults.count,
                    degraded: worker.isDegraded, loadFailure: worker.loadFailure)
            },
            queued: queue.count,
            served: counters.served,
            hedged: counters.hedged,
            hedgeWins: counters.hedgeWins,
            killed: counters.killed,
            late: counters.late,
            refusedBusy: counters.refusedBusy
        )
    }

    // MARK: - Events

    private mutating func submit(id: String, key: ModelKey, input: JudgeInput, budget: Duration, now: Instant) {
        guard key.isWellFormed, pending[id] == nil else {
            reply(id, .failed("malformed judge request"))
            return
        }
        guard mayAdopt(key, now: now) else {
            reply(id, .failed("judge model changed too recently"))
            return
        }
        adopt(key, now: now)
        let window = min(policy.budget, budget)
        guard window > .zero else {
            counters.late += 1
            reply(id, .late)
            return
        }
        if let refusal = unservable() {
            reply(id, refusal)
            return
        }
        guard queue.count < policy.queueLimit else {
            counters.refusedBusy += 1
            reply(id, .busy)
            return
        }
        pending[id] = Pending(input: input, answerBy: now + window, queuedAt: now)
        queue.append(id)
    }

    /// A change of model is allowed once per `keyChangeInterval`; the first
    /// key is always taken.
    private func mayAdopt(_ key: ModelKey, now: Instant) -> Bool {
        guard let current = self.key, current != key, let changedAt = keyChangedAt else { return true }
        return now >= changedAt + policy.keyChangeInterval
    }

    /// Binds the workers to `key`, restarting them when it changes. Requests
    /// for the previous key cannot be served by the new model: they get
    /// `warming`, which the client treats as review. Fault history,
    /// degradation and backoff stay with each slot: a key change must not
    /// launder a crash-looping worker back into rotation.
    private mutating func adopt(_ key: ModelKey, now: Instant) {
        guard self.key != key else { return }
        if self.key != nil { keyChangedAt = now }
        self.key = key
        for id in Array(pending.keys) { reply(id, .warming) }
        pending.removeAll()
        queue.removeAll()
        for slot in WorkerSlot.allCases {
            var worker = workers[slot] ?? Worker()
            // A load failure was about the old bundle; a fault backoff stays.
            let hadLoadFailure = worker.loadFailure != nil
            worker.loadFailure = nil
            switch worker.phase {
            case .down(let retryAt):
                worker.phase = .down(retryAt: hadLoadFailure ? nil : retryAt)
            case .loading(let g, _), .idle(let g), .busy(let g, _, _):
                effects.append(.kill(slot, generation: g))
                worker.phase = .stopping(generation: g, fault: false)
            case .stopping:
                break
            }
            workers[slot] = worker
        }
    }

    private mutating func workerEvent(_ slot: WorkerSlot, generation: UInt64, _ event: WorkerEvent, now: Instant) {
        guard var worker = workers[slot], worker.phase.generation == generation else { return }
        switch (event, worker.phase) {
        case (.ready, .loading):
            worker.phase = .idle(generation: generation)
            worker.backoffStep = 0
            worker.loadFailure = nil
            workers[slot] = worker
        case (.loadFailed(let failure), .loading):
            worker.loadFailure = failure
            worker.phase = .stopping(generation: generation, fault: false)
            workers[slot] = worker
            effects.append(.kill(slot, generation: generation))
        case (.verdict(let id, let verdict), .busy(_, let running, _)) where id == running:
            worker.phase = .idle(generation: generation)
            workers[slot] = worker
            guard let request = pending.removeValue(forKey: id) else { return }
            queue.removeAll { $0 == id }
            counters.served += 1
            if let first = request.first, first != slot { counters.hedgeWins += 1 }
            reply(id, .verdict(verdict, slot: slot))
        case (.failed(let id), .busy(_, let running, _)) where id == running:
            worker.phase = .idle(generation: generation)
            workers[slot] = worker
            release(id, from: slot, reason: "judge prediction failed")
        case (.ready, .stopping), (.loadFailed, .stopping), (.verdict, .stopping), (.failed, .stopping):
            // Already being stopped; its output no longer matters.
            break
        default:
            // Out of protocol: a worker that answers what it was not asked
            // is not trusted with the next request.
            let original = worker.phase
            worker.phase = .stopping(generation: generation, fault: true)
            workers[slot] = worker
            effects.append(.kill(slot, generation: generation))
            if case .busy(_, let running, _) = original {
                release(running, from: slot, reason: "judge worker misbehaved")
            }
        }
    }

    private mutating func exited(_ slot: WorkerSlot, generation: UInt64, now: Instant) {
        guard var worker = workers[slot], worker.phase.generation == generation else { return }
        let fault: Bool
        switch worker.phase {
        case .stopping(_, let wasFault):
            fault = wasFault
        case .busy(_, let running, _):
            fault = true
            release(running, from: slot, reason: "judge worker crashed")
        default:
            fault = true
        }
        if fault {
            recordFault(&worker, now: now)
            worker.phase = .down(retryAt: now + policy.backoff(step: worker.backoffStep))
            worker.backoffStep += 1
        } else if worker.loadFailure != nil {
            worker.phase = .down(retryAt: now + policy.loadFailureRetry)
        } else {
            worker.phase = .down(retryAt: nil)
        }
        workers[slot] = worker
    }

    /// `slot` stopped computing request `id`. If no worker is left on it,
    /// it goes back to the head of the queue for a worker that has not tried
    /// it, or fails when both have.
    private mutating func release(_ id: String, from slot: WorkerSlot, reason: String) {
        guard var request = pending[id] else { return }
        request.active[slot] = nil
        pending[id] = request
        guard request.active.isEmpty else { return }
        if request.tried.contains(slot.other) {
            pending[id] = nil
            queue.removeAll { $0 == id }
            reply(id, .failed(reason))
        } else if !queue.contains(id) {
            queue.insert(id, at: 0)
        }
    }

    private mutating func recordFault(_ worker: inout Worker, now: Instant) {
        worker.faults.append(now)
        worker.faults.removeAll { $0 + policy.faultWindow <= now }
        if worker.faults.count >= policy.faultsToDegrade {
            worker.degradedUntil = now + policy.degradeCooldown
            worker.faults = []
        }
    }

    // MARK: - Pump

    private mutating func pump(now: Instant) {
        restoreDegraded(now: now)
        expire(now: now)
        killOverruns(now: now)
        if let refusal = unservable() {
            for id in queue {
                pending[id] = nil
                reply(id, refusal)
            }
            queue.removeAll()
        }
        spawn(now: now)
        dispatch(now: now)
        hedge(now: now)
    }

    private mutating func restoreDegraded(now: Instant) {
        for slot in WorkerSlot.allCases {
            guard var worker = workers[slot], let until = worker.degradedUntil, until <= now else { continue }
            worker.degradedUntil = nil
            worker.backoffStep = 0
            if case .down = worker.phase { worker.phase = .down(retryAt: nil) }
            workers[slot] = worker
        }
    }

    private mutating func expire(now: Instant) {
        let due = pending.filter { $0.value.answerBy <= now }
        for (id, request) in due.sorted(by: { $0.value.answerBy < $1.value.answerBy }) {
            pending[id] = nil
            queue.removeAll { $0 == id }
            if !request.tried.isEmpty {
                counters.late += 1
                reply(id, .late)
            } else if workers.values.contains(where: \.hasLoaded) {
                // Workers were up but busy for the whole window.
                counters.refusedBusy += 1
                reply(id, .busy)
            } else {
                reply(id, .warming)
            }
        }
    }

    private mutating func killOverruns(now: Instant) {
        for slot in WorkerSlot.allCases {
            guard var worker = workers[slot] else { continue }
            switch worker.phase {
            case .busy(let g, let running, let sentAt) where sentAt + policy.budget <= now:
                counters.killed += 1
                worker.phase = .stopping(generation: g, fault: true)
                workers[slot] = worker
                effects.append(.kill(slot, generation: g))
                release(running, from: slot, reason: "judge worker overran its budget")
            case .loading(let g, let since) where since + policy.loadTimeout <= now:
                worker.phase = .stopping(generation: g, fault: true)
                workers[slot] = worker
                effects.append(.kill(slot, generation: g))
            default:
                break
            }
        }
    }

    /// A refusal for any new request when no worker can serve it: both
    /// degraded (crash-looping: fail closed), or every usable worker reported
    /// the bundle unloadable and is waiting out its retry (broken install).
    private func unservable() -> PoolOutcome? {
        // A slot that never ran counts as usable with no failure: the other
        // worker's load failure must not answer before it had its own try.
        let usable = WorkerSlot.allCases.compactMap { slot -> Worker? in
            let worker = workers[slot] ?? Worker()
            return worker.isDegraded ? nil : worker
        }
        if usable.isEmpty { return .failed("judge workers are crash-looping") }
        let failures = usable.compactMap { worker -> LoadFailure? in
            guard let failure = worker.loadFailure else { return nil }
            switch worker.phase {
            case .down, .stopping: return failure
            default: return nil
            }
        }
        guard failures.count == usable.count, let first = failures.first else { return nil }
        return .loadFailed(first)
    }

    private mutating func spawn(now: Instant) {
        guard let key else { return }
        guard !workers.values.contains(where: { if case .loading = $0.phase { true } else { false } }) else {
            return
        }
        for slot in WorkerSlot.allCases {
            guard var worker = workers[slot], !worker.isDegraded,
                  case .down(let retryAt) = worker.phase, (retryAt ?? now) <= now else { continue }
            let generation = nextGeneration
            nextGeneration += 1
            if worker.spawnedOnce { worker.restarts += 1 }
            worker.spawnedOnce = true
            worker.phase = .loading(generation: generation, since: now)
            workers[slot] = worker
            effects.append(.spawn(slot, generation: generation, key: key))
            return
        }
    }

    private mutating func dispatch(now: Instant) {
        for id in queue {
            guard let request = pending[id], let slot = target(for: request, now: now) else { continue }
            send(id, to: slot, now: now)
        }
        queue.removeAll { id in pending[id].map { !$0.active.isEmpty } ?? true }
    }

    /// The worker a queued request goes to now, if any.
    private func target(for request: Pending, now: Instant) -> WorkerSlot? {
        if canTake(.primary, request) { return .primary }
        guard canTake(.hedge, request) else { return nil }
        if waitsForPrimary(request), now < request.queuedAt + policy.primaryBusyWait { return nil }
        return .hedge
    }

    private func canTake(_ slot: WorkerSlot, _ request: Pending) -> Bool {
        guard !request.tried.contains(slot), let worker = workers[slot], !worker.isDegraded,
              case .idle = worker.phase else { return false }
        return true
    }

    /// The primary is healthy and only busy: worth a short wait before the
    /// request goes to the slower hedge.
    private func waitsForPrimary(_ request: Pending) -> Bool {
        guard !request.tried.contains(.primary), let primary = workers[.primary], !primary.isDegraded,
              case .busy = primary.phase else { return false }
        return true
    }

    private mutating func hedge(now: Instant) {
        for (id, request) in pending {
            guard request.active.count == 1, let (slot, sentAt) = request.active.first,
                  sentAt + policy.hedgeAfter <= now else { continue }
            let other = slot.other
            guard !request.tried.contains(other), let worker = workers[other], !worker.isDegraded,
                  case .idle = worker.phase else { continue }
            counters.hedged += 1
            send(id, to: other, now: now)
        }
    }

    private mutating func send(_ id: String, to slot: WorkerSlot, now: Instant) {
        guard var request = pending[id], var worker = workers[slot],
              case .idle(let generation) = worker.phase else { return }
        request.active[slot] = now
        request.tried.insert(slot)
        if request.first == nil { request.first = slot }
        pending[id] = request
        worker.phase = .busy(generation: generation, request: id, sentAt: now)
        workers[slot] = worker
        effects.append(.send(slot, generation: generation, WorkerRequest(id: id, input: request.input)))
    }

    private mutating func reply(_ id: String, _ outcome: PoolOutcome) {
        effects.append(.reply(id: id, outcome))
    }
}
