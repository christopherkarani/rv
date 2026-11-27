import Foundation
import RVDomain
import RVHistory
import RVPresentation

/// Where `rv log` gets its rows. Pure: the CLI reads the files and hands
/// the rows in.
///
/// When rvd's decision log is there it is the one source: a stop is a
/// denied or refused row, a would-stop an allowed row with a would-be. Its
/// commands are redacted again on read, so a row written by an older
/// redactor is held to today's. The denial ledger adds only what the log
/// lacks, matched on the call's id and never on time: a row whose id the
/// log does not have (its write was lost), and a row with no id from
/// before the log began. With no decision log (an older rvd, or
/// `decisions.enabled: false`) the ledger is the source, without commands.
enum LogSources {
    static func entries(
        ledger: [DenialLedgerRecord], decisions: DecisionLogStops?, home: HomePath?
    ) -> [LogEntry] {
        guard let decisions else { return ledger.map { entry($0) } }
        let listed = decisions.records.compactMap { entry($0, home: home) }
        let ids = Set(decisions.records.compactMap(\.id))
        let missing = ledger.filter { record in
            if let id = record.id { return ids.contains(id) == false }
            guard let startedAt = decisions.startedAt else { return false }
            return record.timestamp < startedAt
        }
        return listed + missing.map { entry($0) }
    }

    /// A ledger row: no command text.
    static func entry(_ record: DenialLedgerRecord) -> LogEntry {
        LogEntry(
            time: record.timestamp,
            agent: record.host.rawValue,
            stopped: record.observed == false,
            wouldAsk: record.observed && record.wouldBe == .ask,
            rule: record.ruleID.rawValue,
            isJudge: record.ruleID.pack == .coreJudge,
            tool: record.tool.rawValue,
            target: record.path,
            command: nil,
            code: record.code,
            session: record.session
        )
    }

    /// A decision-log row as a stop or a would-stop, or nil for a plain
    /// allow. The command and path are redacted again.
    static func entry(_ decision: DecisionRecord, home: HomePath?) -> LogEntry? {
        let stopped: Bool
        let rule: String
        let wouldAsk: Bool
        switch (decision.verdict, decision.wouldBe) {
        case (.denied, _), (.refused, _):
            stopped = true
            rule = decision.rule ?? ""
            wouldAsk = false
        case (.allowed, let wouldBe?) where wouldBe.verdict != .allowed:
            stopped = false
            rule = wouldBe.rule
            wouldAsk = wouldBe.ask
        case (.allowed, _):
            return nil
        }
        return LogEntry(
            time: decision.time,
            agent: decision.host.rawValue,
            stopped: stopped,
            wouldAsk: wouldAsk,
            rule: rule,
            isJudge: rule.hasPrefix(PackID.coreJudge.rawValue + ":"),
            tool: decision.tool.rawValue,
            target: decision.path.map { DecisionRedaction.path($0, home: home) } ?? "",
            command: decision.command.map { DecisionRedaction.command($0, home: home) },
            code: decision.code,
            session: decision.session
        )
    }
}
