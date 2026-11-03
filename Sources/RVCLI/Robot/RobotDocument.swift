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
    case serviceStatus(ServiceStatusReport)

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
