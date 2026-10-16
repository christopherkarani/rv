import Foundation

/// Open vocabulary so newer writers never break older readers.
/// Dotted names filter by prefix: `egress` matches `egress.denied`.
public struct AuditEventKind: RawRepresentable, Sendable, Hashable, Codable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let commandDenied = AuditEventKind(rawValue: "command.denied")
    public static let egressDenied = AuditEventKind(rawValue: "egress.denied")
    public static let admission = AuditEventKind(rawValue: "admission")
    public static let runtimeSession = AuditEventKind(rawValue: "runtime.session")
    public static let runtimeStarted = AuditEventKind(rawValue: "runtime.started")
    public static let runtimeEnded = AuditEventKind(rawValue: "runtime.ended")
    public static let secretUse = AuditEventKind(rawValue: "secret.use")
    public static let mcpCall = AuditEventKind(rawValue: "mcp.call")
    /// Approvals granted, refused, or rejected as forged; trust of mcp.json.
    public static let mcpApproval = AuditEventKind(rawValue: "mcp.approval")

    public static func workspace(_ phase: String) -> AuditEventKind {
        AuditEventKind(rawValue: "workspace.\(phase)")
    }

    public static func agent(_ phase: String) -> AuditEventKind {
        AuditEventKind(rawValue: "agent.\(phase)")
    }

    public func matches(_ filter: String) -> Bool {
        rawValue == filter || rawValue.hasPrefix(filter + ".")
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AuditDecision: String, Sendable, Hashable, Codable {
    case allowed
    case denied
    case pending
    case failed
    case info
}

/// One normalized record (`rv.audit.v1`). Never carries secret values:
/// writers put names and HMAC fingerprints in `detail`, not plaintext.
public struct AuditEvent: Sendable, Equatable, Codable {
    public static let schemaVersion = "rv.audit.v1"

    public var schema: String
    public var time: Date
    public var kind: AuditEventKind
    public var decision: AuditDecision
    public var subject: String
    public var reason: String?
    public var workspace: String?
    public var runtime: String?
    public var agent: String?
    /// Ledger file the event came from.
    public var source: String
    public var detail: [String: String]
    /// SHA-256 of the previous `audit.jsonl` line; set by `AuditLog.append`.
    public var prev: String?
    /// SHA-256 of this event's own `audit.jsonl` line, when read from it.
    /// Never written to the ledger (appends carry none); forwarded in `rv`
    /// format so a recipient can check each event against the next `prev`.
    public var chainHead: String? = nil

    private enum CodingKeys: String, CodingKey {
        case schema, time, kind, decision, subject, reason, workspace, runtime, agent, source, detail, prev, chainHead
    }

    public init(
        time: Date,
        kind: AuditEventKind,
        decision: AuditDecision,
        subject: String,
        reason: String? = nil,
        workspace: String? = nil,
        runtime: String? = nil,
        agent: String? = nil,
        source: String,
        detail: [String: String] = [:]
    ) {
        self.schema = Self.schemaVersion
        self.time = time
        self.kind = kind
        self.decision = decision
        self.subject = subject
        self.reason = reason
        self.workspace = workspace
        self.runtime = runtime
        self.agent = agent
        self.source = source
        self.detail = detail
    }
}

public struct AuditFilter: Sendable, Equatable {
    public var since: Date?
    public var kinds: [String]
    public var limit: Int?

    public init(since: Date? = nil, kinds: [String] = [], limit: Int? = nil) {
        self.since = since
        self.kinds = kinds
        self.limit = limit
    }

    func admits(_ event: AuditEvent) -> Bool {
        if let since, event.time < since { return false }
        if kinds.isEmpty { return true }
        return kinds.contains { event.kind.matches($0) }
    }
}
