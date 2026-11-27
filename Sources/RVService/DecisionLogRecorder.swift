import Foundation
import RVDomain
import RVHistory
import RVHooks
import RVPolicy

/// Writes each hook decision to the local decision log (`DecisionLog`) for
/// `rv term`. rvd's rows come from `HookDecisionTap`, the one hook point on
/// its decision path (the capture the live-event bus publishes, with the
/// reply's final timeout state), and are written on a detached utility
/// task, so the hook reply never waits for the disk. The hook-local
/// evaluator builds the same rows (`shellRecord` / `fileRecord`) for the
/// calls it answers itself. A lost row changes nothing.
package struct DecisionLogRecorder: Sendable {
    let home: HomeDirectory?
    let write: @Sendable (DecisionRecord) -> Void

    package init(home: HomeDirectory?, write: @escaping @Sendable (DecisionRecord) -> Void) {
        self.home = home
        self.write = write
    }

    /// The recorder rvd uses: `decisions.enabled` is read per row, so
    /// turning the log off takes effect without restarting rvd. Nil without
    /// a home (no config directory to write in).
    package static func live(home: HomeDirectory?, clock: @escaping @Sendable () -> Date) -> DecisionLogRecorder? {
        guard let home else { return nil }
        let configDirectory = RVPolicyPaths.configDirectory(home: home)
        return DecisionLogRecorder(home: home) { record in
            guard DecisionLog.isEnabled(inConfigDirectory: configDirectory) else { return }
            DecisionLog(configDirectory: configDirectory).append(record, now: clock())
        }
    }

    /// The decision `HookDecisionTap` captured for one hookEvaluate, with
    /// the reply's final timeout state and the call's `DecisionStamp` (its
    /// id, shared with the ledger row, and any watch-mode would-be).
    /// Called once, after the reply is built; the write runs detached.
    func record(_ capture: HookDecisionTap.Capture, timedOut: Bool, stamp: DecisionStamp?) {
        let host = LedgerHost.hook(capture.host)
        let row: DecisionRecord
        switch capture.subject {
        case .shell(let command):
            row = Self.shellRecord(
                capture.result, command: command, cwd: capture.cwd, host: host, home: home,
                at: capture.startedAt, timedOut: timedOut, session: capture.session, stamp: stamp)
        case .file(let action):
            row = Self.fileRecord(
                capture.result, action: action, cwd: capture.cwd, host: host, home: home,
                at: capture.startedAt, timedOut: timedOut, session: capture.session, stamp: stamp)
        }
        send(row)
    }

    /// The row for a shell decision, redacted. rvd (through the tap) and
    /// the hook-local evaluator both build rows here, so a command reads
    /// the same whichever decided it. `stamp` gives the row the call's id
    /// (the one its denial-ledger row carries) and, for an allow, what
    /// watch mode let run; it defaults to the stamp bound on this task.
    static func shellRecord(
        _ result: EvaluationResult, command: ShellCommand, cwd: WorkingDirectory?, host: LedgerHost,
        home: HomeDirectory?, at time: Date, timedOut: Bool, session: String?,
        stamp: DecisionStamp? = DecisionStamp.current
    ) -> DecisionRecord {
        record(
            result, tool: .bash, command: DecisionRedaction.command(command.rawValue, home: home), path: nil,
            cwd: cwd, host: host, home: home, at: time, timedOut: timedOut, session: session, stamp: stamp)
    }

    /// The row for a file-tool decision; see `shellRecord`.
    static func fileRecord(
        _ result: EvaluationResult, action: FileToolAction, cwd: WorkingDirectory?, host: LedgerHost,
        home: HomeDirectory?, at time: Date, timedOut: Bool, session: String?,
        stamp: DecisionStamp? = DecisionStamp.current
    ) -> DecisionRecord {
        record(
            result, tool: .file(action.kind), command: nil,
            path: DecisionRedaction.path(action.path.rawValue, home: home),
            cwd: cwd, host: host, home: home, at: time, timedOut: timedOut, session: session, stamp: stamp)
    }

    /// The hook session bound on this task, when it can be attributed
    /// (the hook-local evaluator reads it inside `hookWire`).
    static var currentSession: String? {
        HookSessionAttribution.current.flatMap { DenialLedgerRecord.attributableSession($0.rawValue) }
    }

    /// The rule a timed-out reply is filed under (the live event's too).
    static let timeoutRule = HookDecisionTap.Capture.timeoutRule

    /// The row for one decision. Pure.
    static func record(
        _ result: EvaluationResult,
        tool: LedgerTool,
        command: String?,
        path: String?,
        cwd: WorkingDirectory?,
        host: LedgerHost,
        home: HomeDirectory?,
        at time: Date,
        timedOut: Bool,
        session: String?,
        stamp: DecisionStamp? = nil
    ) -> DecisionRecord {
        let verdict: DecisionVerdict
        let rule: String?
        if timedOut {
            verdict = .refused
            rule = timeoutRule
        } else {
            switch result.decision {
            case .allow:
                verdict = .allowed
                rule = nil
            case .deny(let deny):
                verdict = .denied
                rule = deny.ruleID.rawValue
            case .indeterminate(let reason):
                verdict = .refused
                rule = GatedEvaluate.indeterminateRuleID(reason).rawValue
            }
        }
        let shownCwd = cwd.map { DecisionRedaction.path($0.rawValue, home: home) }
        return DecisionRecord(
            time: time, verdict: verdict, host: host, tool: tool, command: command, path: path,
            cwd: shownCwd?.isEmpty == false ? shownCwd : nil, rule: rule, session: session,
            id: stamp?.id, wouldBe: verdict == .allowed ? stamp?.wouldBe : nil
        )
    }

    private func send(_ record: DecisionRecord) {
        let write = self.write
        Task.detached(priority: .utility) { write(record) }
    }
}
