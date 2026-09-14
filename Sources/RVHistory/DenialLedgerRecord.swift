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

/// One redacted denial. Path is already `$HOME` → `~`. No argv.
public struct DenialLedgerRecord: Sendable, Equatable, Codable {
    public var timestamp: Date
    public var host: LedgerHost
    public var tool: LedgerTool
    public var ruleID: RuleID
    public var category: LedgerCategory
    public var path: String

    public init(
        timestamp: Date,
        host: LedgerHost,
        tool: LedgerTool,
        ruleID: RuleID,
        category: LedgerCategory,
        path: String
    ) {
        self.timestamp = timestamp
        self.host = host
        self.tool = tool
        self.ruleID = ruleID
        self.category = category
        self.path = path
    }

    enum CodingKeys: String, CodingKey {
        case timestamp
        case host
        case tool
        case ruleID = "rule_id"
        case category
        case path
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
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(host, forKey: .host)
        try container.encode(tool, forKey: .tool)
        try container.encode(ruleID.rawValue, forKey: .ruleID)
        try container.encode(category, forKey: .category)
        try container.encode(path, forKey: .path)
    }
}
