import Foundation
import RVDomain
import RVHistory
import RVPresentation

/// Where `rv log` gets its rows: the denial ledger (every stop and
/// would-stop, no command text) joined with rvd's decision log (every
/// hook decision, its command redacted when written). Pure: the CLI
/// reads both files and hands the rows in.
enum LogSources {
    /// How far a decision-log row's time may sit from its ledger row's.
    /// The decision is timed before evaluation and the ledger row after it,
    /// and the ledger keeps whole seconds.
    static let stopWindow: ClosedRange<TimeInterval> = -2...10
    /// Tighter for a would-stop: its decision row is an allow, with no rule
    /// to match, so only a row this close and alone in the window counts.
    static let wouldStopWindow: ClosedRange<TimeInterval> = -1...3

    /// `ledger` rows as log entries, each with its command when exactly one
    /// decision-log row matches it, plus the decision log's stops that have
    /// no ledger row (the ledger is off, or pruned past its cap). `decisions`
    /// nil means there was no decision log to read.
    static func entries(ledger: [DenialLedgerRecord], decisions: [DecisionRecord]?) -> [LogEntry] {
        guard let decisions else { return ledger.map { entry($0, command: nil) } }
        var used = Set<Int>()
        var entries: [LogEntry] = []
        for record in ledger {
            let match = self.match(record, in: decisions, excluding: used)
            if let match { used.insert(match) }
            entries.append(entry(record, command: match.flatMap { decisions[$0].command }))
        }
        for (index, decision) in decisions.enumerated() where used.contains(index) == false {
            if let stop = entry(decision) { entries.append(stop) }
        }
        return entries
    }

    /// The index of the one decision-log row that is `record`'s decision:
    /// same host, tool and session, the same path for a file tool, and
    /// either the same rule on a deny (a stop) or an allow (a would-stop,
    /// which watch mode let run), inside the window. Nil when none is, or
    /// when a would-stop has more than one candidate with different
    /// commands: a wrong command is worse than none.
    static func match(_ record: DenialLedgerRecord, in decisions: [DecisionRecord], excluding used: Set<Int>) -> Int? {
        let window = record.observed ? wouldStopWindow : stopWindow
        let candidates = decisions.indices.filter { index in
            let decision = decisions[index]
            guard used.contains(index) == false,
                  decision.host == record.host, decision.tool == record.tool, decision.session == record.session,
                  window.contains(record.timestamp.timeIntervalSince(decision.time))
            else { return false }
            if case .file = record.tool, decision.path != record.path { return false }
            return record.observed
                ? decision.verdict == .allowed
                : decision.verdict == .denied && decision.rule == record.ruleID.rawValue
        }
        if record.observed, Set(candidates.map { decisions[$0].command ?? decisions[$0].path ?? "" }).count > 1 {
            return nil
        }
        return candidates.min { a, b in
            abs(record.timestamp.timeIntervalSince(decisions[a].time))
                < abs(record.timestamp.timeIntervalSince(decisions[b].time))
        }
    }

    static func entry(_ record: DenialLedgerRecord, command: String?) -> LogEntry {
        LogEntry(
            time: record.timestamp,
            agent: record.host.rawValue,
            stopped: record.observed == false,
            wouldAsk: record.observed && record.wouldBe == .ask,
            rule: record.ruleID.rawValue,
            isJudge: record.ruleID.pack == .coreJudge,
            tool: record.tool.rawValue,
            target: record.path,
            command: record.tool == .bash ? command : nil,
            code: record.code,
            session: record.session
        )
    }

    /// A stop only the decision log has: a deny, or a refusal (rv could
    /// not finish deciding, or ran out of time). Allows are not log rows.
    static func entry(_ decision: DecisionRecord) -> LogEntry? {
        guard decision.verdict != .allowed else { return nil }
        let rule = decision.rule ?? ""
        return LogEntry(
            time: decision.time,
            agent: decision.host.rawValue,
            stopped: true,
            rule: rule,
            isJudge: rule.hasPrefix(PackID.coreJudge.rawValue + ":"),
            tool: decision.tool.rawValue,
            target: decision.path ?? "",
            command: decision.command,
            code: decision.code,
            session: decision.session
        )
    }
}
