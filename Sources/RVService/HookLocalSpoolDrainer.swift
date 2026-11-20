import Dispatch
import Foundation
import RVDomain
import RVHistory
import RVPolicy
import Synchronization

/// rvd's side of `HookLocalSpool` (docs/architecture/hook-local-decide.md,
/// "The spool rvd drains").
///
/// Exactly one drain runs at a time, on a private serial queue, never on
/// the cooperative pool: `request()` after each evaluation and a 60 s timer
/// only schedule one, and a request while one is queued is folded into it.
/// The drain itself never waits for the spool lock (`HookLocalSpool.drain`
/// takes it with one non-blocking attempt), so an evaluator holding it
/// costs nothing but a later drain.
///
/// Per drain: audit rows the evaluator could not append are appended to
/// `audit.jsonl`, marked `recorded_by: hook-local`; audit rows lost without
/// their fields get one `audit.gap` event with their count; `rvd.log` gets
/// one rate-limited line naming the rules; then `deliver` hands the
/// analytics decisions to rvd's coordinator (and runs its daily flush, so
/// that no longer waits for an evaluation).
package final class HookLocalSpoolDrainer: Sendable {
    package typealias Deliver = @Sendable (HookLocalSpool.Drained) async -> Void

    /// How often rvd drains with nothing else asking.
    package static let timerInterval: Duration = .seconds(60)
    /// At most one `rvd.log` line per this long.
    static let reportInterval: TimeInterval = 60

    private struct State {
        var scheduled = false
        var lastReport: Date?
        var timer: (any DispatchSourceTimer)?
    }

    private let home: HomeDirectory
    private let deliver: Deliver
    private let write: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "dev.rv.hook-local-spool", qos: .utility)
    private let state = Mutex(State())

    /// `write` takes `rvd.log` lines; the default ignores write errors, as
    /// `AuditDropLog` does.
    package init(
        home: HomeDirectory,
        deliver: @escaping Deliver,
        write: @escaping @Sendable (String) -> Void = {
            try? FileHandle.standardError.write(contentsOf: Data($0.utf8))
        }
    ) {
        self.home = home
        self.deliver = deliver
        self.write = write
    }

    deinit {
        state.withLock { $0.timer?.cancel() }
    }

    /// Schedules a drain unless one is already waiting to run. Never
    /// blocks the caller.
    package func request() {
        let schedule = state.withLock { state -> Bool in
            guard state.scheduled == false else { return false }
            state.scheduled = true
            return true
        }
        guard schedule else { return }
        queue.async {
            // Cleared before draining: a request that lands during this
            // drain schedules the next one rather than being lost.
            self.state.withLock { $0.scheduled = false }
            let drained = self.drainOnce()
            let deliver = self.deliver
            Task { await deliver(drained) }
        }
    }

    /// One drain on the drain queue, awaited, with its delivery (tests).
    @discardableResult
    package func drainNow() async -> HookLocalSpool.Drained {
        let drained = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.drainOnce()) }
        }
        await deliver(drained)
        return drained
    }

    /// Starts the periodic drain; a second call does nothing.
    package func startTimer(every interval: Duration = HookLocalSpoolDrainer.timerInterval) {
        state.withLock { state in
            guard state.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let nanoseconds = Int(interval.components.seconds) * 1_000_000_000
                + Int(interval.components.attoseconds / 1_000_000_000)
            timer.schedule(
                deadline: .now() + .nanoseconds(nanoseconds), repeating: .nanoseconds(nanoseconds),
                leeway: .seconds(5))
            timer.setEventHandler { [weak self] in self?.request() }
            timer.resume()
            state.timer = timer
        }
    }

    /// Runs only on `queue`.
    private func drainOnce(now: Date = Date()) -> HookLocalSpool.Drained {
        let drained = HookLocalSpool.drain(home: home)
        guard drained.isEmpty == false else { return drained }
        let configDirectory = RVPolicyPaths.configDirectory(home: home)
        var unappended: [String] = []
        for audit in drained.audits {
            guard let event = audit.event(),
                AuditLog.append(
                    event, configDirectory: configDirectory,
                    wait: AuditLog.LockWait(timeout: AuditLog.defaultLockTimeout))
            else {
                unappended.append(audit.rule)
                continue
            }
        }
        if drained.lostAudits > 0 {
            AuditLog.append(
                AuditEvent(
                    time: now, kind: .auditGap, decision: .failed, subject: "hook-local",
                    reason: "audit rows the hook-local evaluator lost before they reached its spool",
                    source: AuditLedger.Source.audit.rawValue,
                    detail: ["lost": String(drained.lostAudits), "recorded_by": "hook-local"]),
                configDirectory: configDirectory,
                wait: AuditLog.LockWait(timeout: AuditLog.defaultLockTimeout))
        }
        report(drained, unappended: unappended, now: now)
        return drained
    }

    private func report(_ drained: HookLocalSpool.Drained, unappended: [String], now: Date) {
        guard let message = HookLocalSpool.reportMessage(drained, unappended: unappended) else { return }
        let due = state.withLock { state -> Bool in
            if let last = state.lastReport, now >= last, now.timeIntervalSince(last) < Self.reportInterval {
                return false
            }
            state.lastReport = now
            return true
        }
        guard due else { return }
        write(RVDLogFile.line(message + ". Further reports are not logged for a minute", now: now))
    }
}
