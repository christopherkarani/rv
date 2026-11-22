import ArgumentParser
import Foundation
import RVDomain
import RVHistory
import RVPolicy
import RVPresentation
import RVTheme
import RVTUI

/// `rv log`: the denial ledger in fixed columns. Reads what `rv blocks`
/// reads and leaves `rv blocks` as it is.
enum LogRun {
    /// `rv log` text or `--json`, for the ledger under `home`.
    static func output(
        home: HomeDirectory, query: LogQuery, json: Bool, palette: Palette, columns: Int,
        now: Date = Date(), calendar: Calendar = .current
    ) throws -> String {
        let configDirectory = RVPolicyPaths.configDirectory(home: home)
        let records = DenialLedger(configDirectory: configDirectory).records(asOf: now)
        let model = LogViewModel(
            entries: records.map(entry),
            query: query,
            now: now,
            calendar: calendar,
            windowDays: Int(RVHistory.maxAge / 86_400),
            ledgerOff: records.isEmpty && DenialLedgerPreferences.isEnabled(inConfigDirectory: configDirectory) == false
        )
        if json {
            return try RobotJSON.encode(LogRobotPayload(model), options: .compactISO8601) + "\n"
        }
        return PrettyWriter.join(LogRenderer().render(LogFrame(model: model, columns: columns), palette: palette))
    }

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
            code: record.code,
            session: record.session
        )
    }
}

struct Log: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: CommandVocabulary.Command.log.rawValue,
        abstract: "What rv stopped or would stop, newest first."
    )

    @Flag(name: .customLong("all"), help: "Every row, judge notes too.")
    var all = false

    @Option(name: .customLong("rule"), help: "Only rules whose id contains this text (e.g. core.git).")
    var rule: String?

    @Option(name: .customLong("host"), help: "Only this agent (e.g. claude).")
    var host: String?

    @OptionGroup
    var format: FormatFlags

    func run() throws {
        let ctx = CommandContext.current(command: CommandVocabulary.Command.log.rawValue, format: format)
        let home = try ctx.requireHome()
        let palette: Palette
        switch ctx.appearance {
        case .robot:
            palette = colorOffPalette
        case .pretty(let painted):
            palette = painted
        }
        ctx.writeStdout(
            try LogRun.output(
                home: home,
                query: LogQuery(all: all, rule: rule, host: host),
                json: ctx.explicitRobot,
                palette: palette,
                columns: ctx.probe.columns
            )
        )
    }
}
