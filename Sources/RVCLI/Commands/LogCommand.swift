import ArgumentParser
import Foundation
import RVDomain
import RVHistory
import RVPolicy
import RVPresentation
import RVTheme
import RVTUI

/// `rv log`: rvd's decision log in fixed columns, or the denial ledger
/// when there is no decision log. `rv blocks` is left as it is.
enum LogRun {
    /// `rv log` text or `--json`, for the files under `home`. `columns`
    /// nil keeps every cell whole (piped output).
    static func output(
        home: HomeDirectory, query: LogQuery, json: Bool, palette: Palette, columns: Int?,
        now: Date = Date(), calendar: Calendar = .current
    ) throws -> String {
        let configDirectory = RVPolicyPaths.configDirectory(home: home)
        let records = DenialLedger(configDirectory: configDirectory).records(asOf: now)
        let decisions = decisionLog(configDirectory: configDirectory, now: now)
        let entries = LogSources.entries(ledger: records, decisions: decisions, home: home)
        let model = LogViewModel(
            entries: entries,
            query: query,
            now: now,
            calendar: calendar,
            windowDays: Int(RVHistory.maxAge / 86_400),
            // Without the decision log the ledger is the source, and at
            // its row cap it holds less than the window.
            coveredFrom: decisions == nil && records.count >= RVHistory.maxRows ? records.map(\.timestamp).min() : nil,
            ledgerOff: entries.isEmpty && DenialLedgerPreferences.isEnabled(inConfigDirectory: configDirectory) == false,
            commandsRecorded: decisions != nil,
            skippedDays: decisions?.skippedDays ?? []
        )
        if json {
            return try RobotJSON.encode(LogRobotPayload(model), options: .compactISO8601) + "\n"
        }
        return PrettyWriter.join(LogRenderer().render(LogFrame(model: model, columns: columns), palette: palette))
    }

    /// rvd's stops and would-stops from the window, or nil when there is
    /// no log to read: `decisions.enabled` is false, or this rvd never
    /// wrote one (its directory is missing).
    static func decisionLog(configDirectory: URL, now: Date) -> DecisionLogStops? {
        guard DecisionLog.isEnabled(inConfigDirectory: configDirectory) else { return nil }
        let log = DecisionLog(configDirectory: configDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: log.directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return log.stops(since: now.addingTimeInterval(-RVHistory.maxAge), now: now)
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
                columns: ctx.tty.stdoutIsTTY ? ctx.probe.columns : nil
            )
        )
    }
}
