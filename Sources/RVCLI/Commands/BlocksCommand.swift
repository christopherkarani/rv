import ArgumentParser
import Foundation
import RVDomain
import RVHistory
import RVPolicy

enum BlocksRun {
    /// What to show. Filters apply to text and JSON; `limit` only to text,
    /// so `--json` keeps returning every matching row.
    struct Options: Equatable {
        static let defaultLimit = 20

        var limit: Int? = Options.defaultLimit
        var rule: String?
        var host: String?

        func matches(_ record: DenialLedgerRecord) -> Bool {
            if let rule, record.ruleID.rawValue.localizedCaseInsensitiveContains(rule) == false { return false }
            if let host, record.host.rawValue.caseInsensitiveCompare(host) != .orderedSame { return false }
            return true
        }

        var isFiltered: Bool { rule != nil || host != nil }
    }

    static func list(
        home: HomeDirectory, json: Bool, options: Options = Options(), now: Date = Date()
    ) throws -> String {
        let records = DenialLedger(
            configDirectory: RVPolicyPaths.configDirectory(home: home)
        ).records(asOf: now).filter(options.matches)
        if json {
            return try encodeJSON(records)
        }
        return text(records, options: options)
    }

    static func text(_ records: [DenialLedgerRecord], options: Options) -> String {
        if records.isEmpty {
            let days = Int(RVHistory.maxAge / 86_400)
            return options.isFiltered
                ? "No denials match. rv blocks without --rule or --host lists every one.\n"
                : "No denials in the last \(days) days.\n"
        }
        let shown = options.limit.map { Array(records.prefix($0)) } ?? records
        let rows = [header] + shown.map(columns)
        var lines = table(rows)
        lines.append("")
        if shown.count < records.count {
            lines.append("Showing the newest \(shown.count) of \(records.count). rv blocks --all lists every one.")
        }
        lines.append("By rule: " + summary(records))
        lines.append(
            "BLOCKED stopped the agent; WOULD BLOCK and WOULD ASK are observe mode, which let it run.")
        return lines.joined(separator: "\n") + "\n"
    }

    static let header = ["TIME", "DECISION", "HOST", "TOOL", "RULE", "TARGET"]

    /// The decision in words: an enforced row stopped the agent; an
    /// observed row is what enforcement would have done.
    static func decision(_ record: DenialLedgerRecord) -> String {
        guard record.observed else { return "BLOCKED" }
        return record.wouldBe == .ask ? "WOULD ASK" : "WOULD BLOCK"
    }

    private static func columns(_ record: DenialLedgerRecord) -> [String] {
        var target = DisplayedText.field(record.path)
        if let session = record.session {
            target += (target.isEmpty ? "" : "  ") + "session=" + DisplayedText.field(session)
        }
        return [
            timestamp(record.timestamp),
            decision(record),
            record.host.rawValue,
            record.tool.rawValue,
            DisplayedText.field(record.ruleID.rawValue),
            target,
        ]
    }

    /// Left-aligned columns two spaces apart; the last column is not padded.
    private static func table(_ rows: [[String]]) -> [String] {
        let count = rows.map(\.count).max() ?? 0
        let widths = (0..<count).map { column in
            rows.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0
        }
        return rows.map { row in
            row.enumerated().map { column, cell in
                column == row.count - 1 ? cell : cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }
            .joined(separator: "  ")
            .trimmingTrailingSpaces()
        }
    }

    /// `core.judge:laya-block 41 · core.git:reset-hard 3`, most frequent first.
    static func summary(_ records: [DenialLedgerRecord]) -> String {
        let counts = Dictionary(grouping: records, by: \.ruleID.rawValue).mapValues(\.count)
        return counts
            .sorted { ($1.value, $0.key) < ($0.value, $1.key) }
            .map { "\(DisplayedText.field($0.key)) \($0.value)" }
            .joined(separator: " · ")
    }

    // REQ-T7 named divergence: slashes are no longer spelled `\/`.
    private static func encodeJSON(_ records: [DenialLedgerRecord]) throws -> String {
        try RobotJSON.encode(records, options: .compactISO8601) + "\n"
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private extension String {
    func trimmingTrailingSpaces() -> String {
        var text = self
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }
}

struct Blocks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "blocks",
        abstract: "List recent denials, newest first."
    )

    @Option(name: .customLong("limit"), help: "Rows to show (default 20).")
    var limit: Int?

    @Flag(name: .customLong("all"), help: "Show every row.")
    var all = false

    @Option(name: .customLong("rule"), help: "Only rules whose id contains this text (e.g. core.git).")
    var rule: String?

    @Option(name: .customLong("host"), help: "Only this host (e.g. claude).")
    var host: String?

    @OptionGroup
    var format: FormatFlags

    func validate() throws {
        if let limit, limit < 1 {
            throw ValidationError("--limit must be at least 1")
        }
        if all, limit != nil {
            throw ValidationError("use --all or --limit, not both")
        }
    }

    func run() throws {
        let ctx = CommandContext.current(command: "blocks", format: format)
        let home = try ctx.requireHome()
        let text = try BlocksRun.list(
            home: home,
            json: ctx.explicitRobot,
            options: BlocksRun.Options(
                limit: all ? nil : (limit ?? BlocksRun.Options.defaultLimit),
                rule: rule,
                host: host
            )
        )
        ctx.writeStdout(text)
    }
}
