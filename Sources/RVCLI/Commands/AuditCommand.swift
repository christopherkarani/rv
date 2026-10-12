import ArgumentParser
import Foundation
import RVHistory
import RVPolicy

enum AuditRun {
    static func events(home: HomeDirectory, filter: AuditFilter) -> [AuditEvent] {
        AuditLedger(configDirectory: RVPolicyPaths.configDirectory(home: home)).events(filter)
    }

    /// `90s`, `30m`, `24h`, `7d`. Nil for anything else.
    static func duration(_ text: String) -> TimeInterval? {
        guard let unit = text.last, let count = Double(text.dropLast()), count >= 0 else { return nil }
        switch unit {
        case "s": return count
        case "m": return count * 60
        case "h": return count * 3_600
        case "d": return count * 86_400
        default: return nil
        }
    }

    static func filter(since: String?, kinds: [String], limit: Int?, now: Date) throws -> AuditFilter {
        var start: Date?
        if let since {
            guard let seconds = duration(since) else {
                throw ValidationError("--since takes a duration like 30m, 24h, or 7d")
            }
            start = now.addingTimeInterval(-seconds)
        }
        return AuditFilter(since: start, kinds: kinds, limit: limit)
    }

    static func pretty(_ events: [AuditEvent]) -> String {
        guard events.isEmpty == false else { return "" }
        return events.map { event in
            var parts = [
                iso8601(event.time),
                event.decision.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0),
                event.kind.rawValue,
                event.subject,
            ]
            if let agent = event.agent { parts.append("agent=\(agent)") }
            if let reason = event.reason { parts.append("reason=\(reason)") }
            return parts.joined(separator: "  ")
        }.joined(separator: "\n") + "\n"
    }

    static func jsonArray(_ events: [AuditEvent]) -> String {
        guard let data = try? encoder.encode(events), let text = String(data: data, encoding: .utf8) else {
            return "[]\n"
        }
        return text + "\n"
    }

    static func jsonLines(_ events: [AuditEvent]) -> String {
        events.compactMap { event in
            (try? encoder.encode(event)).flatMap { String(data: $0, encoding: .utf8) }
        }.map { $0 + "\n" }.joined()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

struct Audit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audit",
        abstract: "Show the unified audit trail.",
        subcommands: [AuditTail.self, AuditExport.self],
        defaultSubcommand: AuditTail.self
    )
}

struct AuditTail: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tail",
        abstract: "Print the newest audit events."
    )

    @Option(name: [.customShort("n"), .long], help: "Number of events to show.")
    var limit: Int = 50

    @Option(help: "Only events newer than a duration (30m, 24h, 7d).")
    var since: String?

    @Option(help: "Only events of this kind or kind prefix (egress, admission, secret.use).")
    var kind: [String] = []

    @OptionGroup
    var format: FormatFlags

    func run() throws {
        let ctx = CommandContext.current(command: "audit tail", format: format)
        let home = try ctx.requireHome()
        let filter = try AuditRun.filter(since: since, kinds: kind, limit: max(0, limit), now: Date())
        let events = AuditRun.events(home: home, filter: filter)
        ctx.writeStdout(ctx.explicitRobot ? AuditRun.jsonArray(events) : AuditRun.pretty(events))
    }
}

struct AuditExport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Write audit events as JSON Lines (rv.audit.v1) for SIEM ingest."
    )

    @Option(help: "Only events newer than a duration (30m, 24h, 7d).")
    var since: String?

    @Option(help: "Only events of this kind or kind prefix.")
    var kind: [String] = []

    func run() throws {
        let ctx = CommandContext.current(
            command: "audit export", json: true, robot: false, plain: true, noColor: true)
        let home = try ctx.requireHome()
        let filter = try AuditRun.filter(since: since, kinds: kind, limit: nil, now: Date())
        ctx.writeStdout(AuditRun.jsonLines(AuditRun.events(home: home, filter: filter)))
    }
}
