import ArgumentParser
import Foundation
import RVDomain
import RVHistory
import RVPolicy
import RVPresentation
import RVTUI
import RVTheme

enum BlocksRun {
    /// `palette` paints each row's glyph (red ✕, amber ◐) on a colour
    /// terminal; the colour-off default keeps rows plain when piped.
    static func list(
        home: HomeDirectory,
        json: Bool,
        now: Date = Date(),
        palette: Palette = colorOffPalette
    ) throws -> String {
        let records = DenialLedger(
            configDirectory: RVPolicyPaths.configDirectory(home: home)
        ).records(asOf: now)
        if json {
            return try encodeJSON(records)
        }
        if records.isEmpty {
            return ""
        }
        return records.map { prettyLine($0, palette: palette) }.joined(separator: "\n") + "\n"
    }

    /// Every row says what happened after the timestamp, so a real stop
    /// never reads like a watched one: `✕ Stopped` (the command did not
    /// run), or `◐ Would stop` for a watch-mode row (the agent was not
    /// blocked; `--json` `would_be` says whether guard mode would have
    /// asked or stopped). A host name is never one of these words. A row
    /// that names its agent session ends with `session=<id>`.
    private static func prettyLine(_ record: DenialLedgerRecord, palette: Palette) -> String {
        [
            iso8601(record.timestamp),
            paintLeadingGlyph(verdict(record), rest: "", palette: palette),
            record.host.rawValue,
            record.tool.rawValue,
            DisplayedText.field(record.ruleID.rawValue),
            record.category.rawValue,
            DisplayedText.field(record.path),
            record.session.map { "session=" + DisplayedText.field($0) },
        ].compactMap { $0 }.joined(separator: "  ")
    }

    private static func verdict(_ record: DenialLedgerRecord) -> String {
        record.observed ? wouldStopWords : stoppedWords
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
            json: ctx.explicitRobot,
            palette: ctx.appearance.palette
        )
        ctx.writeStdout(text)
    }
}
