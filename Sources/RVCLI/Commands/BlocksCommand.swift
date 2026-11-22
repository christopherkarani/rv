import ArgumentParser
import Foundation
import RVDomain
import RVHistory
import RVPolicy
import RVPresentation

enum BlocksRun {
    static func list(home: HomeDirectory, json: Bool, now: Date = Date()) throws -> String {
        let records = DenialLedger(
            configDirectory: RVPolicyPaths.configDirectory(home: home)
        ).records(asOf: now)
        if json {
            return try encodeJSON(records)
        }
        if records.isEmpty {
            return ""
        }
        return records.map(prettyLine).joined(separator: "\n") + "\n"
    }

    /// Every row says what happened after the timestamp, so a real stop
    /// never reads like a watched one: `✕ Stopped` (the command did not
    /// run), or for an observe-mode row (the agent was not blocked)
    /// `◐ Watched, would stop` / `◐ Watched, would ask` (what enforcement
    /// would have done). A host name is never one of these words. A row
    /// that names its agent session ends with `session=<id>`.
    private static func prettyLine(_ record: DenialLedgerRecord) -> String {
        [
            iso8601(record.timestamp),
            verdict(record),
            record.host.rawValue,
            record.tool.rawValue,
            DisplayedText.field(record.ruleID.rawValue),
            record.category.rawValue,
            DisplayedText.field(record.path),
            record.session.map { "session=" + DisplayedText.field($0) },
        ].compactMap { $0 }.joined(separator: "  ")
    }

    private static func verdict(_ record: DenialLedgerRecord) -> String {
        guard record.observed else { return "✕ Stopped" }
        return record.wouldBe == .ask ? watchedWouldAskWords : watchedWouldStopWords
    }

    // REQ-T7 named divergence: slashes are no longer spelled `\/`.
    private static func encodeJSON(_ records: [DenialLedgerRecord]) throws -> String {
        try RobotJSON.encode(records, options: .compactISO8601) + "\n"
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

struct Blocks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "blocks",
        abstract: "List recent denials."
    )

    @OptionGroup
    var format: FormatFlags

    func run() throws {
        let ctx = CommandContext.current(command: "blocks", format: format)
        let home = try ctx.requireHome()
        let text = try BlocksRun.list(
            home: home,
            json: ctx.explicitRobot
        )
        ctx.writeStdout(text)
    }
}
