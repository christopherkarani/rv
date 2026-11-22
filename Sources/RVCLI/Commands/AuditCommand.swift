import ArgumentParser
import Foundation
import RVDomain
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
        try validateKinds(kinds)
        return AuditFilter(since: start, kinds: kinds, limit: limit)
    }

    /// The kind families `--kind` can name. `workspace.*` and `agent.*` take
    /// any phase, so only their family is checked.
    static let kindFamilies: [String] = {
        var families: [String] = []
        for kind in AuditEventKind.allCases {
            let family = String(kind.rawValue.prefix { $0 != "." })
            if families.contains(family) == false { families.append(family) }
        }
        return families + ["workspace", "agent"]
    }()

    /// A `--kind` that matches no event would print nothing, which reads as
    /// "nothing happened". Refuse it and list what does exist.
    static func validateKinds(_ kinds: [String]) throws {
        for kind in kinds where knownKind(kind) == false {
            throw ValidationError(
                "--kind \(DisplayedText.field(kind)) matches no audit event kind; use one of: \(kindFamilies.joined(separator: ", ")) (or a full kind such as secret.use)")
        }
    }

    static func knownKind(_ kind: String) -> Bool {
        for family in ["workspace", "agent"] where kind == family || kind.hasPrefix(family + ".") {
            return kind.hasSuffix(".") == false
        }
        return AuditEventKind.allCases.contains { $0.matches(kind) }
    }

    /// What `rv audit tail` prints when there is nothing to show.
    static func emptyMessage(filtered: Bool) -> String {
        filtered ? "No audit events match these filters.\n" : "No audit events yet.\n"
    }

    static func pretty(_ events: [AuditEvent]) -> String {
        guard events.isEmpty == false else { return "" }
        return events.map { event in
            var parts = [
                iso8601(event.time),
                event.decision.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0),
                event.kind.rawValue,
                DisplayedText.field(event.subject),
            ]
            parts.append(contentsOf: changeSummary(event))
            if let agent = event.agent { parts.append("agent=\(DisplayedText.field(agent))") }
            if let reason = event.reason { parts.append("reason=\(DisplayedText.field(reason))") }
            return parts.joined(separator: "  ")
        }.joined(separator: "\n") + "\n"
    }

    /// What a gate change changed and who authorized it, for `policy.changed`,
    /// `policy.managed` and `config.changed`; empty for other kinds.
    static func changeSummary(_ event: AuditEvent) -> [String] {
        guard event.kind == .policyChanged || event.kind == .policyManaged || event.kind == .configChanged else {
            return []
        }
        let detail = event.detail
        var pieces: [String] = []
        if event.kind == .policyChanged {
            let prior = detail["prior_revision"].map { "r\($0)" } ?? "none"
            let revision = detail["revision"] ?? "?"
            let hash = String((detail["hash"] ?? "").prefix(12))
            pieces.append("\(detail["change"] ?? "save") \(prior) -> r\(revision)")
            pieces.append("hash=\(hash)")
            if let target = detail["rollback_to"] { pieces.append("restored=r\(target)") }
        } else if let prior = detail["prior"], let new = detail["new"] {
            pieces.append("\(prior) -> \(new)")
        } else if let change = detail["change"] {
            pieces.append(change)
            if let serial = detail["serial"] { pieces.append("serial=\(serial)") }
        }
        if let host = detail["host"], let port = detail["port"] { pieces.append("\(host):\(port)") }
        for key in ["added", "removed", "changed"] {
            if let value = detail[key] { pieces.append("\(key)=\(value)") }
        }
        if let by = detail["authorized_by"] { pieces.append("by=\(by)") }
        return pieces.map { DisplayedText.field($0) }
    }

    static func jsonArray(_ events: [AuditEvent]) throws -> String {
        try RobotJSON.encode(events, options: .compactISO8601) + "\n"
    }

    static func jsonLines(_ events: [AuditEvent]) throws -> String {
        try RobotJSON.encodeLines(events, options: .compactISO8601)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

enum AuditVerifyRun {
    static func check(_ url: URL) -> Result<AuditChainReport, CommandFailure> {
        AuditChain.verify(fileURL: url).mapError { CommandFailure($0.message) }
    }

    static func json(_ report: AuditChainReport) throws -> String {
        try RobotJSON.encode(report, options: .auditVerify)
    }

    static func text(_ report: AuditChainReport, path: String) -> String {
        guard report.lines > 0 else { return "no audit lines yet (\(DisplayedText.field(path)))\n" }
        if let broken = report.firstBreak {
            let scope = broken.line == 1
                ? "  the file was changed at its start"
                : "  lines 1-\(broken.line - 1) are intact; line \(broken.line) or the one before it was edited, removed, inserted, or reordered"
            return "audit chain BROKEN at line \(broken.line) of \(DisplayedText.field(path)): \(DisplayedText.field(broken.reason))\n\(scope)\n"
        }
        var text = "audit chain intact: \(report.lines) lines, head \(report.head)\n"
        if report.unchained > 0 {
            text += "  the first \(report.unchained) line\(report.unchained == 1 ? "" : "s") predate the chain and are not covered\n"
        }
        return text
    }
}

struct Audit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audit",
        abstract: "Show the unified audit trail.",
        subcommands: [AuditTail.self, AuditExport.self, AuditForward.self, AuditVerify.self],
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
        if ctx.explicitRobot {
            ctx.writeStdout(try AuditRun.jsonArray(events))
        } else if events.isEmpty {
            ctx.writeStdout(AuditRun.emptyMessage(filtered: since != nil || kind.isEmpty == false || limit <= 0))
        } else {
            ctx.writeStdout(AuditRun.pretty(events))
        }
    }
}

struct AuditVerify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Check the audit.jsonl hash chain and report the first break."
    )

    @OptionGroup
    var format: FormatFlags

    func run() throws {
        let ctx = CommandContext.current(command: "audit verify", format: format)
        let home = try ctx.requireHome()
        let url = AuditLog.fileURL(configDirectory: RVPolicyPaths.configDirectory(home: home))
        let report: AuditChainReport
        switch AuditVerifyRun.check(url) {
        case .failure(let failure): try ctx.fail("rv audit verify: \(failure.message)\n")
        case .success(let checked): report = checked
        }
        ctx.writeStdout(
            ctx.explicitRobot
                ? try AuditVerifyRun.json(report)
                : AuditVerifyRun.text(report, path: url.path))
        if report.isIntact == false { throw ExitCode(1) }
    }
}

struct AuditExport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Write audit events as JSON Lines (rv.audit.v1 or OCSF) for SIEM ingest."
    )

    @Option(help: "rv (rv.audit.v1) or ocsf (OCSF 1.3.0).")
    var format: AuditForwardRun.Format = .rv

    @Option(help: "Only events newer than a duration (30m, 24h, 7d).")
    var since: String?

    @Option(help: "Only events of this kind or kind prefix.")
    var kind: [String] = []

    func run() throws {
        let ctx = CommandContext.current(
            command: "audit export", json: true, robot: false, plain: true, noColor: true)
        let home = try ctx.requireHome()
        let filter = try AuditRun.filter(since: since, kinds: kind, limit: nil, now: Date())
        let events = AuditRun.events(home: home, filter: filter)
        switch format {
        case .rv:
            ctx.writeStdout(try AuditRun.jsonLines(events))
        case .ocsf:
            let host = ProcessInfo.processInfo.hostName
            ctx.writeStdout(events.compactMap { AuditOCSF.jsonLine($0, hostName: host) }.map { $0 + "\n" }.joined())
        }
    }
}
