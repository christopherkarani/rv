import Foundation

/// One change that makes rv less strict: the closed set of loosens an
/// agent may ask for (workstream F2). An agent never applies one. It
/// becomes a proposal that rvd stores, and rvd applies it only after the
/// device owner approves that exact proposal (Touch ID or the login
/// password at rvd's prompt), bound by its content hash.
///
/// Closed on purpose: a kind rvd does not know cannot be proposed (decode
/// fails), so a new loosen needs a new case, an applier and tests.
public enum PolicyLoosen: Sendable, Equatable, Hashable {
    /// An allowlist exception for one rule id (`rv allowlist add`).
    case allowRule(rule: String, reason: String)
    /// An allowlist exception for one exact command (`rv allowlist add-command`).
    case allowCommand(command: String, reason: String)
    /// Machine safety from strict to normal (`rv safety normal`).
    case safetyNormal
    /// One bundled pack turned off (`rv packs disable`, `rv protect <tool> off`).
    case packOff(pack: String)

    /// Longest rule id or pack id, in UTF-8 bytes.
    public static let maxIdentifierBytes = 128
    /// Longest exact command, in UTF-8 bytes.
    public static let maxCommandBytes = 4096
    /// Longest reason, in UTF-8 bytes.
    public static let maxReasonBytes = 280

    /// The wire and store name of this kind.
    public var kind: String {
        switch self {
        case .allowRule: "allowRule"
        case .allowCommand: "allowCommand"
        case .safetyNormal: "safetyNormal"
        case .packOff: "packOff"
        }
    }

    /// Why this change cannot be proposed, or nil when it is well formed.
    /// Checked by rvd before it stores anything, and again before it applies.
    public var problem: String? {
        switch self {
        case .allowRule(let rule, let reason):
            return Self.identifierProblem(rule, what: "rule id") ?? Self.reasonProblem(reason)
        case .allowCommand(let command, let reason):
            if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "the command is empty" }
            if command.utf8.count > Self.maxCommandBytes { return "the command is longer than \(Self.maxCommandBytes) bytes" }
            if command.unicodeScalars.contains(where: { $0.value == 0 }) { return "the command contains a NUL byte" }
            return Self.reasonProblem(reason)
        case .safetyNormal:
            return nil
        case .packOff(let pack):
            return Self.identifierProblem(pack, what: "pack id")
        }
    }

    private static func identifierProblem(_ text: String, what: String) -> String? {
        guard text.isEmpty == false else { return "the \(what) is empty" }
        guard text.utf8.count <= maxIdentifierBytes else { return "the \(what) is longer than \(maxIdentifierBytes) bytes" }
        let allowed = text.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(Character(scalar))
                || scalar == "." || scalar == "-" || scalar == "_" || scalar == ":" || scalar == "/")
        }
        return allowed ? nil : "the \(what) may hold only letters, digits and . - _ : /"
    }

    private static func reasonProblem(_ reason: String) -> String? {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "a reason is required" }
        if reason.utf8.count > maxReasonBytes { return "the reason is longer than \(maxReasonBytes) bytes" }
        return nil
    }

    /// What the change does, in rv's words (never the agent's): the
    /// "Looser:" line the owner reads in the terminal and in rvd's prompt.
    /// Raw text: callers escape it for where it is shown.
    public var looser: String {
        switch self {
        case .allowRule(let rule, _): "rule \(rule) is allowed (an allowlist exception)"
        case .allowCommand(let command, _): "the exact command \"\(command)\" is allowed (an allowlist exception)"
        case .safetyNormal: "safety goes from strict to normal"
        case .packOff(let pack): "pack \(pack) is turned off"
        }
    }

    /// The reason the proposer gave, for kinds that carry one.
    public var reason: String? {
        switch self {
        case .allowRule(_, let reason), .allowCommand(_, let reason): reason
        case .safetyNormal, .packOff: nil
        }
    }

    /// The fields of this change in a fixed order, for the content hash.
    public var canonicalFields: [String] {
        switch self {
        case .allowRule(let rule, let reason): [kind, rule, reason]
        case .allowCommand(let command, let reason): [kind, command, reason]
        case .safetyNormal: [kind]
        case .packOff(let pack): [kind, pack]
        }
    }
}

extension PolicyLoosen: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, rule, command, reason, pack
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Strict: an unknown kind, a missing field, or any key the kind does
    /// not use throws, so a change can never carry a field rvd ignores but
    /// a later reader might honour.
    public init(from decoder: Decoder) throws {
        let keys = Set(try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        func expect(_ allowed: Set<String>) throws {
            guard keys == allowed.union(["kind"]) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "loosen \(kind) has keys \(keys.sorted()), expected \((allowed.union(["kind"])).sorted())"))
            }
        }
        switch kind {
        case "allowRule":
            try expect(["rule", "reason"])
            self = .allowRule(
                rule: try container.decode(String.self, forKey: .rule),
                reason: try container.decode(String.self, forKey: .reason))
        case "allowCommand":
            try expect(["command", "reason"])
            self = .allowCommand(
                command: try container.decode(String.self, forKey: .command),
                reason: try container.decode(String.self, forKey: .reason))
        case "safetyNormal":
            try expect([])
            self = .safetyNormal
        case "packOff":
            try expect(["pack"])
            self = .packOff(pack: try container.decode(String.self, forKey: .pack))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "unknown loosen kind \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .allowRule(let rule, let reason):
            try container.encode(rule, forKey: .rule)
            try container.encode(reason, forKey: .reason)
        case .allowCommand(let command, let reason):
            try container.encode(command, forKey: .command)
            try container.encode(reason, forKey: .reason)
        case .safetyNormal:
            break
        case .packOff(let pack):
            try container.encode(pack, forKey: .pack)
        }
    }
}

/// A proposal's id: `p-` and a number rvd assigns in order ("p-21").
public struct ProposalID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    /// Nil unless `rawValue` is `p-` followed by 1 to 9 ASCII digits.
    public init?(rawValue: String) {
        guard rawValue.hasPrefix("p-") else { return nil }
        let digits = rawValue.dropFirst(2)
        guard (1...9).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        self.rawValue = rawValue
    }

    public init(number: Int) {
        self.rawValue = "p-\(number)"
    }

    /// The number after `p-`.
    public var number: Int { Int(rawValue.dropFirst(2)) ?? 0 }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let id = ProposalID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a proposal id")
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Where a proposal stands.
public enum ProposalStatus: String, Sendable, Equatable, Codable {
    case pending
    case approved
    case rejected
    case expired
}
