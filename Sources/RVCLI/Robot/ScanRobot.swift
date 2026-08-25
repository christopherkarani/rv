import Foundation
import RVDomain
import RVPresentation

struct ScanSessionsRobotPayload: Equatable, Sendable, Encodable {
    var schema: String
    var findings: [ScanFindingRobotRow]
    var warnings: [ScanWarningRobotRow]
    var filesScanned: Int
    var eventsExtracted: Int
    var setupNudge: Bool

    enum CodingKeys: String, CodingKey {
        case schema
        case findings
        case warnings
        case filesScanned = "files_scanned"
        case eventsExtracted = "events_extracted"
        case setupNudge = "setup_nudge"
    }
}

struct ScanFindingRobotRow: Equatable, Sendable, Encodable {
    var host: String
    var sessionID: String?
    var path: String
    var occurredAt: String?
    var ruleID: String
    var packID: String
    var commandRedacted: String
    var command: String?
    var count: Int
    var lastSeen: String?

    enum CodingKeys: String, CodingKey {
        case host
        case sessionID = "session_id"
        case path
        case occurredAt = "occurred_at"
        case ruleID = "rule_id"
        case packID = "pack_id"
        case commandRedacted = "command_redacted"
        case command
        case count
        case lastSeen = "last_seen"
    }
}

struct ScanWarningRobotRow: Equatable, Sendable, Encodable {
    var code: String
    var message: String
}

func scanSessionsRobotPayload(
    from report: ScanReport,
    showCommand: Bool
) -> ScanSessionsRobotPayload {
    ScanSessionsRobotPayload(
        schema: "rv.scan.sessions",
        findings: report.findings.map { scanFindingRobotRow(from: $0, showCommand: showCommand) },
        warnings: report.warnings.map { ScanWarningRobotRow(code: $0.code, message: $0.message) },
        filesScanned: report.filesScanned,
        eventsExtracted: report.eventsExtracted,
        setupNudge: report.setupNudgeRecommended
    )
}

func renderScanSessionsRobot(
    from report: ScanReport,
    showCommand: Bool
) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let payload = scanSessionsRobotPayload(from: report, showCommand: showCommand)
    do {
        let data = try encoder.encode(payload)
        return String(decoding: data, as: UTF8.self)
    } catch {
        preconditionFailure("ScanSessionsRobotPayload encoding cannot fail (\(error))")
    }
}

private func scanFindingRobotRow(
    from finding: ScanFinding,
    showCommand: Bool
) -> ScanFindingRobotRow {
    ScanFindingRobotRow(
        host: finding.host.rawValue,
        sessionID: finding.sessionID,
        path: finding.sourcePath,
        occurredAt: scanRobotISO8601(finding.occurredAt),
        ruleID: finding.ruleID.rawValue,
        packID: finding.packID.rawValue,
        commandRedacted: redactMatchingView(finding.matchingView),
        command: showCommand ? finding.matchingView.rawValue : nil,
        count: finding.count,
        lastSeen: scanRobotISO8601(finding.lastSeen)
    )
}

private func scanRobotISO8601(_ date: Date?) -> String? {
    guard let date else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}
