import Foundation
import RVDomain
import RVHistory
import RVHooks
import RVPolicy

/// Writes each hook decision to the local decision log (`DecisionLog`) for
/// `rv term`. The row is built on the request's task, where its session and
/// deadline are bound, and written on a detached utility task, so the hook
/// reply never waits for the disk. A lost row changes nothing.
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

    /// A shell decision the door made at `time`.
    package func shell(
        _ result: EvaluationResult, command: ShellCommand, cwd: WorkingDirectory?, host: LedgerHost, at time: Date
    ) {
        send(Self.shellRecord(
            result, command: command, cwd: cwd, host: host, home: home, at: time,
            timedOut: HookDeadline.current?.requiresTimeoutReply ?? false))
    }

    /// A file-tool decision the door made at `time`.
    package func file(
        _ result: EvaluationResult, action: FileToolAction, cwd: WorkingDirectory?, host: LedgerHost, at time: Date
    ) {
        send(Self.fileRecord(
            result, action: action, cwd: cwd, host: host, home: home, at: time,
            timedOut: HookDeadline.current?.requiresTimeoutReply ?? false))
    }

    /// The row for a shell decision, redacted, filed under the hook
    /// session bound on this task. rvd and the hook-local evaluator both
    /// build rows here, so a command reads the same whichever decided it.
    static func shellRecord(
        _ result: EvaluationResult, command: ShellCommand, cwd: WorkingDirectory?, host: LedgerHost,
        home: HomeDirectory?, at time: Date, timedOut: Bool
    ) -> DecisionRecord {
        record(
            result, tool: .bash, command: DecisionRedaction.command(command.rawValue, home: home), path: nil,
            cwd: cwd, host: host, home: home, at: time, timedOut: timedOut, session: currentSession)
    }

    /// The row for a file-tool decision; see `shellRecord`.
    static func fileRecord(
        _ result: EvaluationResult, action: FileToolAction, cwd: WorkingDirectory?, host: LedgerHost,
        home: HomeDirectory?, at time: Date, timedOut: Bool
    ) -> DecisionRecord {
        record(
            result, tool: .file(action.kind), command: nil,
            path: DecisionRedaction.path(action.path.rawValue, home: home),
            cwd: cwd, host: host, home: home, at: time, timedOut: timedOut, session: currentSession)
    }

    /// The hook session bound on this task, when it can be attributed.
    private static var currentSession: String? {
        HookSessionAttribution.current.flatMap { DenialLedgerRecord.attributableSession($0.rawValue) }
    }

    /// The rule a timed-out reply is filed under: the door answered with
    /// its timeout deny, whatever the evaluation found.
    static let timeoutRule = "rv.timeout"

    /// The row for one decision. Pure; `shell` and `file` read the
    /// task-locals and pass them in.
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
        session: String?
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
            cwd: shownCwd?.isEmpty == false ? shownCwd : nil, rule: rule, session: session
        )
    }

    private func send(_ record: DecisionRecord) {
        let write = self.write
        Task.detached(priority: .utility) { write(record) }
    }
}
