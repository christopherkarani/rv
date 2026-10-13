import Foundation
import RVDomain

/// Best-effort OCSF 1.3.0 mapping of `rv.audit.v1` events. rv fields with no
/// OCSF home go under `unmapped`, so nothing is lost.
public enum AuditOCSF {
    public static let version = "1.3.0"

    struct Class {
        var uid: Int
        var name: String
        var category: Int
        var categoryName: String
        var activity: Int
        var activityName: String
    }

    public static func object(_ event: AuditEvent, hostName: String) -> [String: Any] {
        let mapped = mappedClass(event)
        let (statusID, status) = self.status(event.decision)
        let (dispositionID, disposition) = self.disposition(event.decision)
        let (severityID, severity) = self.severity(event.decision)
        var object: [String: Any] = [
            "class_uid": mapped.uid,
            "class_name": mapped.name,
            "category_uid": mapped.category,
            "category_name": mapped.categoryName,
            "activity_id": mapped.activity,
            "activity_name": mapped.activityName,
            "type_uid": mapped.uid * 100 + mapped.activity,
            "type_name": "\(mapped.name): \(mapped.activityName)",
            "time": Int64((event.time.timeIntervalSince1970 * 1_000).rounded()),
            "severity_id": severityID,
            "severity": severity,
            "status_id": statusID,
            "status": status,
            "disposition_id": dispositionID,
            "disposition": disposition,
            "action_id": event.decision == .denied ? 2 : event.decision == .allowed ? 1 : 0,
            "action": event.decision == .denied ? "Denied" : event.decision == .allowed ? "Allowed" : "Unknown",
            "message": "rv \(event.kind.rawValue) \(event.subject): \(event.decision.rawValue)"
                + (event.reason.map { " (\($0))" } ?? ""),
            "metadata": [
                "version": version,
                "uid": uid(event),
                "log_name": event.source,
                "product": ["name": "rv", "vendor_name": "rv", "version": ProductVersion.semver],
            ] as [String: Any],
            "device": ["hostname": hostName, "type_id": 0],
        ]
        if let agent = event.agent { object["actor"] = ["app_name": agent] }
        switch mapped.uid {
        case 6003:
            let parts = event.subject.split(separator: "/", maxSplits: 1).map(String.init)
            object["api"] = [
                "operation": event.detail["tool"] ?? (parts.count == 2 ? parts[1] : event.kind.rawValue),
                "service": ["name": event.detail["server"] ?? (parts.count == 2 ? parts[0] : "rv.secrets")],
            ] as [String: Any]
            object["src_endpoint"] = ["hostname": hostName]
        case 4001:
            let pieces = event.subject.split(separator: ":")
            var endpoint: [String: Any] = ["hostname": pieces.first.map(String.init) ?? event.subject]
            if pieces.count == 2, let port = Int(pieces[1]) { endpoint["port"] = port }
            object["dst_endpoint"] = endpoint
            object["src_endpoint"] = ["hostname": hostName]
        case 1007:
            object["process"] = ["name": event.detail["tool"] ?? "command"]
        default:
            object["app"] = ["name": "rv", "version": ProductVersion.semver]
        }
        var unmapped: [String: Any] = ["rv_kind": event.kind.rawValue, "rv_subject": event.subject]
        if let reason = event.reason { unmapped["rv_reason"] = reason }
        if let workspace = event.workspace { unmapped["rv_workspace"] = workspace }
        if let runtime = event.runtime { unmapped["rv_runtime"] = runtime }
        if event.detail.isEmpty == false { unmapped["rv_detail"] = event.detail }
        object["unmapped"] = unmapped
        return object
    }

    public static func jsonLine(_ event: AuditEvent, hostName: String) -> String? {
        let object = object(event, hostName: hostName)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Stable id so a SIEM can drop the duplicates at-least-once delivery may send.
    public static func uid(_ event: AuditEvent) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let bytes = (try? encoder.encode(event)).map(Array.init) ?? Array(event.subject.utf8)
        return String(RVDigest.sha256Hex(bytes).prefix(32))
    }

    static func mappedClass(_ event: AuditEvent) -> Class {
        let kind = event.kind
        if kind == .mcpCall || kind == .secretUse {
            return Class(uid: 6003, name: "API Activity", category: 6, categoryName: "Application Activity", activity: 99, activityName: "Other")
        }
        if kind == .egressDenied {
            return Class(uid: 4001, name: "Network Activity", category: 4, categoryName: "Network Activity", activity: 5, activityName: "Refuse")
        }
        if kind == .commandDenied {
            return Class(uid: 1007, name: "Process Activity", category: 1, categoryName: "System Activity", activity: 1, activityName: "Launch")
        }
        let lifecycle = Class(uid: 6002, name: "Application Lifecycle", category: 6, categoryName: "Application Activity", activity: 99, activityName: "Other")
        if kind == .runtimeStarted { return Class(uid: 6002, name: lifecycle.name, category: 6, categoryName: lifecycle.categoryName, activity: 3, activityName: "Start") }
        if kind == .runtimeEnded { return Class(uid: 6002, name: lifecycle.name, category: 6, categoryName: lifecycle.categoryName, activity: 4, activityName: "Stop") }
        return lifecycle
    }

    static func status(_ decision: AuditDecision) -> (Int, String) {
        switch decision {
        case .allowed, .info: (1, "Success")
        case .denied, .failed: (2, "Failure")
        case .pending: (99, "Pending")
        }
    }

    static func disposition(_ decision: AuditDecision) -> (Int, String) {
        switch decision {
        case .allowed: (1, "Allowed")
        case .denied: (2, "Blocked")
        case .pending: (14, "Delayed")
        case .failed: (27, "Error")
        case .info: (17, "Logged")
        }
    }

    static func severity(_ decision: AuditDecision) -> (Int, String) {
        switch decision {
        case .allowed, .info: (1, "Informational")
        case .pending: (2, "Low")
        case .denied, .failed: (3, "Medium")
        }
    }
}
