import Foundation
import RVDomain

/// Operator TTY or a hook host. jsonl: `tty` / HookHost raw value.
public enum LedgerHost: Sendable, Equatable {
    case tty
    case hook(HookHost)

    public var rawValue: String {
        switch self {
        case .tty:
            "tty"
        case .hook(let host):
            host.rawValue
        }
    }

    public init?(rawValue: String) {
        if rawValue == "tty" {
            self = .tty
            return
        }
        guard let host = HookHost(rawValue: rawValue) else {
            return nil
        }
        self = .hook(host)
    }
}

extension LedgerHost: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = LedgerHost(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown ledger host"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Shell `Bash` or a file-tool ledger name (`Read` / `Edit` / `Write`).
public enum LedgerTool: Sendable, Equatable {
    case bash
    case file(FileToolKind)

    public var rawValue: String {
        switch self {
        case .bash:
            "Bash"
        case .file(let kind):
            kind.ledgerName
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "Bash":
            self = .bash
        case "Read":
            self = .file(.read)
        case "Edit":
            self = .file(.edit)
        case "Write":
            self = .file(.write)
        default:
            return nil
        }
    }
}

extension LedgerTool: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = LedgerTool(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown ledger tool"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Deny pack, or secret catalog category when matched text hit the catalog.
public enum LedgerCategory: Sendable, Equatable {
    case pack(PackID)
    case secret(SecretPathCategory)

    public var rawValue: String {
        switch self {
        case .pack(let pack):
            pack.rawValue
        case .secret(let category):
            category.rawValue
        }
    }

    public init?(rawValue: String) {
        if let secret = SecretPathCategory(rawValue: rawValue) {
            self = .secret(secret)
            return
        }
        guard let pack = PackID(validating: rawValue) else {
            return nil
        }
        self = .pack(pack)
    }
}

extension LedgerCategory: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = LedgerCategory(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown ledger category"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// What enforcement would have surfaced for an observed row: a deny, or an
/// ask (a deny a human may approve). jsonl: `would_be`.
public enum LedgerWouldBe: String, Sendable, Equatable, Codable {
    case deny
    case ask
}

/// One redacted denial. Path is already `$HOME` → `~`. No argv.
public struct DenialLedgerRecord: Sendable, Equatable, Codable {
    public var timestamp: Date
    public var host: LedgerHost
    public var tool: LedgerTool
    public var ruleID: RuleID
    public var category: LedgerCategory
    public var path: String
    /// Observe mode: enforcement would have denied, the door allowed.
    /// Encoded only when true, so enforced rows keep their bytes.
    public var observed: Bool
    /// Observed rows only: encoded with `observed`; a row without it
    /// (written before it existed) was a would-be deny.
    public var wouldBe: LedgerWouldBe
    /// The host's session id for the hook request that tripped the rule
    /// (`attributableSession`), so a row names the agent session. Nil for
    /// the TTY and rows written before it existed; encoded only when set.
    public var session: String?

    public init(
        timestamp: Date,
        host: LedgerHost,
        tool: LedgerTool,
        ruleID: RuleID,
        category: LedgerCategory,
        path: String,
        observed: Bool = false,
        wouldBe: LedgerWouldBe = .deny,
        session: String? = nil
    ) {
        self.timestamp = timestamp
        self.host = host
        self.tool = tool
        self.ruleID = ruleID
        self.category = category
        self.path = path
        self.observed = observed
        self.wouldBe = wouldBe
        self.session = session
    }

    /// Longest session id a row keeps.
    public static let maxSessionLength = 128

    /// `raw` when it is an opaque id (`[A-Za-z0-9._:-]`, at most
    /// `maxSessionLength` bytes), else nil. Host session ids are UUIDs or
    /// similar tokens; anything else (spaces, paths, command text) is not
    /// written.
    public static func attributableSession(_ raw: String) -> String? {
        guard raw.isEmpty == false, raw.utf8.count <= maxSessionLength,
              raw.utf8.allSatisfy(isSessionByte)
        else { return nil }
        return raw
    }

    private static func isSessionByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "."), UInt8(ascii: "_"),
             UInt8(ascii: ":"), UInt8(ascii: "-"):
            true
        default:
            false
        }
    }

    enum CodingKeys: String, CodingKey {
        case timestamp
        case host
        case tool
        case ruleID = "rule_id"
        case category
        case path
        case observed
        case wouldBe = "would_be"
        case session
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        host = try container.decode(LedgerHost.self, forKey: .host)
        tool = try container.decode(LedgerTool.self, forKey: .tool)
        let ruleRaw = try container.decode(String.self, forKey: .ruleID)
        guard let decodedRule = RuleID(rawValue: ruleRaw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .ruleID,
                in: container,
                debugDescription: "unknown ledger rule_id"
            )
        }
        ruleID = decodedRule
        category = try container.decode(LedgerCategory.self, forKey: .category)
        path = try container.decode(String.self, forKey: .path)
        observed = try container.decodeIfPresent(Bool.self, forKey: .observed) ?? false
        wouldBe = try container.decodeIfPresent(LedgerWouldBe.self, forKey: .wouldBe) ?? .deny
        session = try container.decodeIfPresent(String.self, forKey: .session)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(host, forKey: .host)
        try container.encode(tool, forKey: .tool)
        try container.encode(ruleID.rawValue, forKey: .ruleID)
        try container.encode(category, forKey: .category)
        try container.encode(path, forKey: .path)
        if observed {
            try container.encode(true, forKey: .observed)
            try container.encode(wouldBe, forKey: .wouldBe)
        }
        try container.encodeIfPresent(session, forKey: .session)
    }
}
