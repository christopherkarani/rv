import Foundation
import RVDomain
import Synchronization

/// Wall time per phase of one `hookEvaluate`, written to `rvd.log` as one
/// line when the request ran past its `HookDeadline` (the client has then
/// shown the user "RV daemon did not answer in time"). Instrumentation
/// only: nothing here changes a verdict or a deadline.
///
/// The line carries the host, door, rule or reason id and the phase
/// durations; never command text, paths or session ids. A request still
/// running `HookDoor.hungGrace` past its deadline (a stuck judge or read)
/// would never reach the completion line, so a watchdog logs its phases so
/// far once ("still running"); its completion line, if it ever finishes,
/// then usually falls inside `SlowHookLog.interval` and is only counted.
final class HookTiming: Sendable {
    enum Phase: String, CaseIterable, Sendable {
        /// Frame receipt to `HookDoor.run` (transport and actor hops).
        case queue
        /// The whole gated evaluation (shell or file port); the phases
        /// below up to `effects` fall inside it.
        case evaluate
        /// Waiting for a `JudgeOffload` thread.
        case offloadWait = "offload_wait"
        /// Config, store and guard-mode reads.
        case inputs
        /// Pack evaluation (`evaluateWithSemantics`).
        case policy
        /// Script check and judge (`posture`); includes the `judge_*` phases.
        case screen
        /// Waiting for the judge model to finish loading.
        case judgeLoad = "judge_load"
        /// Waiting for the model behind other judged requests.
        case judgeAdmission = "judge_admission"
        /// The judge inference itself.
        case judgePredict = "judge_predict"
        /// Policy gate: allow-once grants and the allowlist.
        case gate
        /// Audit, judge-log and denial-ledger writes.
        case effects
        /// Unlock-code mint, pending row and wire encoding after the verdict.
        case reply
    }

    /// The timing of the hookEvaluate this task (or, rebound by
    /// `JudgeOffload`, this Dispatch thread) is serving. Only `HookDoor.run`
    /// binds it; with none bound every `measure` just runs its body.
    @TaskLocal static var current: HookTiming?

    private struct State {
        var durations: [Phase: Duration] = [:]
        var door: String?
        var rule: String?
    }

    private let state = Mutex(State())

    func add(_ phase: Phase, _ duration: Duration) {
        state.withLock { $0.durations[phase, default: .zero] += duration }
    }

    /// The door (`shell`, `file`) and the rule or indeterminate reason id
    /// the evaluation ended on; nil for an allow.
    func settle(door: String, rule: String?) {
        state.withLock {
            $0.door = door
            $0.rule = rule
        }
    }

    var durations: [Phase: Duration] { state.withLock { $0.durations } }

    /// Runs `body`, adding its wall time to `phase` of the bound timing.
    static func measure<T>(_ phase: Phase, _ body: () throws -> T) rethrows -> T {
        guard let timing = current else { return try body() }
        let start = ContinuousClock.now
        defer { timing.add(phase, ContinuousClock.now - start) }
        return try body()
    }

    /// Async `measure`, for the phases that suspend.
    static func measure<T>(_ phase: Phase, _ body: () async throws -> T) async rethrows -> T {
        guard let timing = current else { return try await body() }
        let start = ContinuousClock.now
        defer { timing.add(phase, ContinuousClock.now - start) }
        return try await body()
    }

    /// The log message for a request that took `total` against `budget`;
    /// nil when it finished in time and tripped no deadline check.
    /// `running`: the request has not finished (`HookDoor`'s watchdog), so
    /// the phases are the ones measured so far.
    func slowMessage(
        host: String,
        total: Duration,
        budget: Duration,
        tripped: Bool,
        running: Bool = false
    ) -> String? {
        guard running || tripped || total >= budget else { return nil }
        let snapshot = state.withLock { $0 }
        var fields = [
            "host=\(host)",
            "door=\(snapshot.door ?? "none")",
            "total_ms=\(Self.milliseconds(total))",
            "budget_ms=\(Self.milliseconds(budget))",
            "tripped=\(tripped)",
        ]
        for phase in Phase.allCases {
            guard let duration = snapshot.durations[phase] else { continue }
            fields.append("\(phase.rawValue)_ms=\(Self.milliseconds(duration))")
        }
        if let rule = snapshot.rule { fields.append("rule=\(rule)") }
        let lead = running ? "rvd: hook still running past its deadline: " : "rvd: hook ran past its deadline: "
        return lead + fields.joined(separator: " ")
    }

    /// The id a result ended on: the deny rule or indeterminate reason; nil
    /// for an allow.
    static func ruleID(of result: EvaluationResult) -> String? {
        switch result.decision {
        case .allow: nil
        case .deny(let deny): deny.ruleID.rawValue
        case .indeterminate(let reason): reason.rawValue
        }
    }

    static func milliseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
    }
}

/// Writes `HookTiming` lines to rvd's stderr (`rvd.log`), at most one per
/// `interval` (`AuditDropLog`'s rate); the next written line carries the
/// count skipped since the last one. A burst of slow hooks must not fill a
/// log that rotates only at start.
final class SlowHookLog: Sendable {
    static let interval: Duration = .seconds(60)
    static let shared = SlowHookLog()

    private struct State {
        var last: ContinuousClock.Instant?
        var skipped = 0
    }

    private let state = Mutex(State())
    private let write: @Sendable (String) -> Void

    /// The default writer ignores write errors, as `AuditDropLog` does.
    init(write: @escaping @Sendable (String) -> Void = { try? FileHandle.standardError.write(contentsOf: Data($0.utf8)) }) {
        self.write = write
    }

    /// Returns whether it wrote.
    @discardableResult
    func report(_ message: String, now: ContinuousClock.Instant = .now) -> Bool {
        let skipped: Int? = state.withLock { state in
            if let last = state.last, now - last < Self.interval {
                state.skipped += 1
                return nil
            }
            state.last = now
            defer { state.skipped = 0 }
            return state.skipped
        }
        guard let skipped else { return false }
        write(RVDLogFile.line(skipped > 0 ? message + " skipped_since_last=\(skipped)" : message))
        return true
    }
}
