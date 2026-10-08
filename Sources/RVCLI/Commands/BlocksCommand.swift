import ArgumentParser
import Foundation
import RVDomain
import RVHistory
import RVPolicy

enum BlocksRun {
    static func list(home: HomeDirectory, json: Bool, now: Date = Date()) -> String {
        let records = DenialLedger(
            configDirectory: RVPolicyPaths.configDirectory(home: home)
        ).records(asOf: now)
        if json {
            return encodeJSON(records)
        }
        if records.isEmpty {
            return ""
        }
        return records.map(prettyLine).joined(separator: "\n") + "\n"
    }

    private static func prettyLine(_ record: DenialLedgerRecord) -> String {
        [
            iso8601(record.timestamp),
            record.host.rawValue,
            record.tool.rawValue,
            record.ruleID.rawValue,
            record.category.rawValue,
            record.path,
        ].joined(separator: "  ")
    }

    private static func encodeJSON(_ records: [DenialLedgerRecord]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(records),
              let text = String(data: data, encoding: .utf8)
        else {
            return "[]\n"
        }
        return text + "\n"
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
        let text = BlocksRun.list(
            home: home,
            json: ctx.explicitRobot
        )
        ctx.writeStdout(text)
    }
}
