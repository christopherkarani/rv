import Foundation
import Synchronization

/// One blocking call handed to a pool worker. The caller waits on
/// `completion`; a caller that stops first marks the call abandoned.
///
/// Concurrency: `phase` only changes while the owning pool's lock is held
/// (pool lock, then this lock), so "finished" and "abandoned" are decided
/// once and wedged accounting cannot miss either side of the race.
final class DiskImageSyscallCall: Sendable {
    private enum Phase {
        case pending
        case abandoned
        case finished(Bool)
    }

    fileprivate let body: @Sendable () -> Bool
    private let phase = Mutex(Phase.pending)
    /// Signalled once by the worker after the result is recorded.
    fileprivate let completion = DispatchSemaphore(value: 0)

    fileprivate init(body: @escaping @Sendable () -> Bool) {
        self.body = body
    }

    var isFinished: Bool {
        phase.withLock {
            if case .finished = $0 { return true }
            return false
        }
    }

    fileprivate var result: Bool? {
        phase.withLock {
            if case let .finished(value) = $0 { return value }
            return nil
        }
    }

    /// Records the result. Returns true when the caller had already
    /// abandoned the call, i.e. this worker was quarantined.
    fileprivate func finish(_ value: Bool) -> Bool {
        phase.withLock {
            let abandoned: Bool
            if case .abandoned = $0 { abandoned = true } else { abandoned = false }
            $0 = .finished(value)
            return abandoned
        }
    }

    /// Marks a still-running call abandoned. Returns the result instead
    /// when the worker finished first.
    fileprivate func abandonUnlessFinished() -> Bool? {
        phase.withLock {
            if case let .finished(value) = $0 { return value }
            $0 = .abandoned
            return nil
        }
    }
}

/// A long-lived thread that runs one call at a time.
///
/// Concurrency: `assigned` is written by the pool (under its lock) before
/// `wake` is signalled, and taken by the worker after `wake` returns, so
/// each assignment is seen exactly once.
private final class DiskImageSyscallWorker: Sendable {
    private let assigned = Mutex<DiskImageSyscallCall?>(nil)
    private let wake = DispatchSemaphore(value: 0)

    func assign(_ call: DiskImageSyscallCall) {
        assigned.withLock { $0 = call }
        wake.signal()
    }

    /// Runs calls until the pool retires this worker. Foundation retains
    /// a started `Thread` (and so this closure and worker) until it
    /// exits, so a worker wedged in a syscall is never released under it.
    func run(in pool: DiskImageSyscallPool) {
        while let call = next(in: pool) {
            let value = call.body()
            guard pool.complete(call, value: value, by: self) else { return }
        }
    }

    private func next(in pool: DiskImageSyscallPool) -> DiskImageSyscallCall? {
        while true {
            if wake.wait(timeout: .now() + pool.idleTimeout) == .timedOut {
                if pool.retire(self) { return nil }
                // The pool took this worker off the idle list to assign a
                // call; `wake` is about to be signalled.
                continue
            }
            if let call = assigned.withLock({ value -> DiskImageSyscallCall? in
                defer { value = nil }
                return value
            }) {
                return call
            }
        }
    }
}

/// Keeps an object alive without touching it. Only the reference count
/// is used, so sharing it across threads is safe.
private struct DiskImageParkedObject: @unchecked Sendable {
    let object: AnyObject
}

/// Bounded, reusable workers for blocking vnode syscalls. A call that
/// outlives its caller's stop quarantines its worker: it is not handed
/// new work until the call returns. A replacement starts for the next
/// call, up to `maxWedged` quarantined workers; past that, calls are
/// refused (fail closed) instead of growing threads without bound.
final class DiskImageSyscallPool: Sendable {
    static let shared = DiskImageSyscallPool()

    private struct State {
        var idle: [DiskImageSyscallWorker] = []
        var wedged: [DiskImageSyscallCall] = []
        var parked: [(object: DiskImageParkedObject, calls: [DiskImageSyscallCall])] = []
        var threadsStarted = 0
    }

    let maxIdle: Int
    let maxWedged: Int
    let idleTimeout: TimeInterval
    private let state = Mutex(State())

    init(maxIdle: Int = 8, maxWedged: Int = 32, idleTimeout: TimeInterval = 10) {
        self.maxIdle = maxIdle
        self.maxWedged = maxWedged
        self.idleTimeout = idleTimeout
    }

    var threadsStarted: Int { state.withLock { $0.threadsStarted } }
    var wedgedCount: Int { state.withLock { $0.wedged.count } }
    var idleCount: Int { state.withLock { $0.idle.count } }

    /// Starts `body` on an idle or new worker. `nil` means `maxWedged`
    /// workers are still inside abandoned calls; nothing was started.
    func submit(_ body: @escaping @Sendable () -> Bool) -> DiskImageSyscallCall? {
        let call = DiskImageSyscallCall(body: body)
        let reused: DiskImageSyscallWorker?? = state.withLock { state in
            guard state.wedged.count < maxWedged else { return .none }
            if let worker = state.idle.popLast() { return .some(worker) }
            state.threadsStarted += 1
            return .some(nil)
        }
        guard let reused else { return nil }
        if let reused {
            reused.assign(call)
        } else {
            let worker = DiskImageSyscallWorker()
            worker.assign(call)
            let thread = Thread { worker.run(in: self) }
            thread.name = "rv.disk-syscall"
            thread.start()
        }
        return call
    }

    /// The caller's stop passed. Returns the result if the worker beat
    /// the stop; otherwise quarantines the worker and returns nil.
    func abandon(_ call: DiskImageSyscallCall) -> Bool? {
        state.withLock { state in
            if let value = call.abandonUnlessFinished() { return value }
            state.wedged.append(call)
            return nil
        }
    }

    /// Worker side. Records the result and returns the worker to the idle
    /// list before waking the caller, so a sequential caller reuses it.
    /// Returns false when the worker should exit.
    fileprivate func complete(
        _ call: DiskImageSyscallCall,
        value: Bool,
        by worker: DiskImageSyscallWorker
    ) -> Bool {
        let keep = state.withLock { state in
            if call.finish(value) {
                state.wedged.removeAll { $0 === call }
                state.parked.removeAll { $0.calls.allSatisfy(\.isFinished) }
            }
            guard state.idle.count < maxIdle else { return false }
            state.idle.append(worker)
            return true
        }
        call.completion.signal()
        return keep
    }

    /// Idle timeout. True when `worker` was still idle and is now removed.
    fileprivate func retire(_ worker: DiskImageSyscallWorker) -> Bool {
        state.withLock { state in
            guard let index = state.idle.firstIndex(where: { $0 === worker }) else { return false }
            state.idle.remove(at: index)
            return true
        }
    }

    /// Keeps `object` alive until every call wedged right now returns.
    func retainAcrossWedged(_ object: AnyObject) {
        let parked = DiskImageParkedObject(object: object)
        state.withLock { state in
            state.parked.removeAll { $0.calls.allSatisfy(\.isFinished) }
            state.parked.append((parked, state.wedged))
        }
    }

    /// Waits for `call` until `stop()` (re-read each wake) passes. A
    /// result recorded before the stop wins over the stop.
    func wait(
        for call: DiskImageSyscallCall,
        recheck: TimeInterval,
        stop: () -> Date?
    ) -> Bool? {
        while true {
            if let value = call.result { return value }
            var slice = recheck
            if let stopAt = stop() {
                let left = stopAt.timeIntervalSinceNow
                if left <= 0 { return abandon(call) }
                slice = min(slice, left)
            }
            if call.completion.wait(timeout: .now() + slice) == .success {
                return call.result
            }
        }
    }
}
