import Foundation
import RVDomain
import RVPresentation

/// Closed machine-output document for CLI robot JSON.
enum RobotDocument {
    case test(TestRobotPayload)
    case explain(ExplainRobotPayload)
    case doctor(DoctorRobotPayload)
    case packsList(PacksRobotPayload)
    case packsInfo(PacksRobotRow)
    case allowlistList([AllowlistRobotRow])
    case allowOnceList([AllowOnceRobotRow])
    /// key=value lines: piped or CI output with no format flag.
    case serviceStatus(ServiceStatusReport)
    /// `rv.service.status.v1`: `rv service status --json` / `--robot`.
    case serviceStatusJSON(ServiceStatusReport)
    /// `rv.setup.v1`: `rv setup --json` / `--robot`.
    case setup(SetupRobotPayload)

    /// Returns this document as JSON with sorted keys and unescaped slashes.
    func render() throws -> String {
        switch self {
        case .test(let payload):
            try Self.jsonString(payload)
        case .explain(let payload):
            try Self.jsonString(payload)
        case .doctor(let payload):
            try Self.jsonString(payload)
        case .packsList(let payload):
            try Self.jsonString(payload)
        case .packsInfo(let payload):
            try Self.jsonString(payload)
        case .allowlistList(let rows):
            try Self.jsonString(rows)
        case .allowOnceList(let rows):
            try Self.jsonString(rows)
        case .serviceStatus(let report):
            Self.serviceStatusLines(report).joined(separator: "\n")
        case .serviceStatusJSON(let report):
            try Self.jsonString(ServiceStatusRobotPayload(report))
        case .setup(let payload):
            try Self.jsonString(payload)
        }
    }

    private static func jsonString(_ value: some Encodable) throws -> String {
        // Defensive: JSONEncoder cannot fail on these plain Codable
        // payloads, so no seam exists to test the failure arm.
        try RobotJSON.encode(value)
    }

    private static func serviceStatusLines(_ report: ServiceStatusReport) -> [String] {
        var lines = [
            "state=\(report.state)",
            "protocol=\(report.protocolName)",
            "label=\(report.label)",
            "fallback=\(report.fallback)",
            "keepAlive=\(report.keepAlive)",
        ]
        if let lastError = report.lastError {
            lines.append("lastError=\(lastError)")
        }
        return lines
    }
}

/// `rv.service.status.v1`: the key=value fields as one JSON object, less
/// `fallback` (hooks have no in-process fallback; it only echoed `state`).
struct ServiceStatusRobotPayload: Equatable, Sendable, Encodable {
    static let schema = "rv.service.status.v1"
    var schema = Self.schema
    var state: String
    var protocolName: String
    var label: String
    var keepAlive: Bool
    var lastError: String?

    init(_ report: ServiceStatusReport) {
        state = report.state
        protocolName = report.protocolName
        label = report.label
        keepAlive = report.keepAlive
        lastError = report.lastError
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case state
        case protocolName = "protocol"
        case label
        case keepAlive = "keep_alive"
        case lastError = "last_error"
    }
}

/// `rv.setup.v1`: what `rv setup --json` did. Printed on every run,
/// including one that changed nothing (`outcome: "unchanged"`) and a
/// failure (`ok: false`, `error` holds the stderr text).
struct SetupRobotPayload: Equatable, Sendable, Encodable {
    static let schema = "rv.setup.v1"
    var schema = Self.schema
    var ok: Bool
    /// `complete`, `unchanged`, `no_hosts`, `skipped` (every detected host
    /// occupied) or `failed`.
    var outcome: String
    /// Detected hosts: `wired` or `occupied`.
    var hosts: [String: String]
    /// Hosts whose hook this run wrote.
    var wrote: [String]
    /// `launchd`, `systemd`, `direct` (Linux, no systemd user manager: rvd
    /// runs unsupervised), `not_managed` (HOME is not the login home) or
    /// `rvd_missing`. Nil on failure.
    var service: String?
    /// Interpreter → hosts left unwired because it does not run.
    var unwiredMissingInterpreter: [String: [String]]?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case schema
        case ok
        case outcome
        case hosts
        case wrote
        case service
        case unwiredMissingInterpreter = "unwired_missing_interpreter"
        case error
    }

    static func failure(_ stderr: String) -> SetupRobotPayload {
        SetupRobotPayload(
            ok: false,
            outcome: "failed",
            hosts: [:],
            wrote: [],
            service: nil,
            unwiredMissingInterpreter: nil,
            error: stderr.trimmingCharacters(in: .newlines)
        )
    }
}
