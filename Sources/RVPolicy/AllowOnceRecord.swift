#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import RVDomain

public struct TTYCapability: Equatable, Sendable {
    public var stdinIsTTY: Bool
    public var stdoutIsTTY: Bool
    public var ci: Bool

    public init(stdinIsTTY: Bool, stdoutIsTTY: Bool, ci: Bool) {
        self.stdinIsTTY = stdinIsTTY
        self.stdoutIsTTY = stdoutIsTTY
        self.ci = ci
    }
}

public func allowsInteractiveAllowOnce(_ tty: TTYCapability) -> Bool {
    tty.stdinIsTTY && tty.stdoutIsTTY && !tty.ci
}

public enum AllowOnceConsumeStatus: Sendable, Equatable {
    case consumed(tokenID: String)
    case notFound
    case alreadyConsumed
    case expired
    case unavailable
}

public enum AllowOnceError: Error, Sendable, Equatable {
    case ttyRequired
    case robotRefused
    case unknownCode
    case expired
    case alreadySpent
    case collision
    case encodeFailed
    case lockFailed
    case emptyCommand
}

public enum AllowOnceLifecycle: Sendable, Equatable {
    case pending
    case granted
    case consumed(at: Date)
}

public struct AllowOnceRecord: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case pending
        case granted
        case consumed
    }

    public var schemaVersion: Int
    public var lifecycle: AllowOnceLifecycle
    public var codeHash: String
    public var commandFingerprint: String
    public var commandRedacted: String
    public var cwd: WorkingDirectory
    public var ruleID: RuleID?
    public var createdAt: Date
    public var expiresAt: Date

    /// List/TTY/robot projection of `lifecycle`. Not stored beside it.
    public var kind: Kind {
        switch lifecycle {
        case .pending:
            return .pending
        case .granted:
            return .granted
        case .consumed:
            return .consumed
        }
    }

    /// Instant this row was consumed. `nil` unless `lifecycle` is `.consumed`.
    public var consumedAt: Date? {
        guard case .consumed(let at) = lifecycle else { return nil }
        return at
    }

    public init(
        schemaVersion: Int,
        lifecycle: AllowOnceLifecycle,
        codeHash: String,
        commandFingerprint: String,
        commandRedacted: String,
        cwd: WorkingDirectory,
        ruleID: RuleID?,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.lifecycle = lifecycle
        self.codeHash = codeHash
        self.commandFingerprint = commandFingerprint
        self.commandRedacted = commandRedacted
        self.cwd = cwd
        self.ruleID = ruleID
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case kind
        case codeHash = "code_hash"
        case commandFingerprint = "command_fingerprint"
        case commandRedacted = "command_redacted"
        case cwd
        case ruleID = "rule_id"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case consumedAt = "consumed_at"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(kind, forKey: .kind)
        try container.encode(codeHash, forKey: .codeHash)
        try container.encode(commandFingerprint, forKey: .commandFingerprint)
        try container.encode(commandRedacted, forKey: .commandRedacted)
        try container.encode(cwd, forKey: .cwd)
        try container.encodeIfPresent(ruleID, forKey: .ruleID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(expiresAt, forKey: .expiresAt)
        if case .consumed(let at) = lifecycle {
            try container.encode(at, forKey: .consumedAt)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let kind = try container.decode(Kind.self, forKey: .kind)
        codeHash = try container.decode(String.self, forKey: .codeHash)
        commandFingerprint = try container.decode(String.self, forKey: .commandFingerprint)
        commandRedacted = try container.decode(String.self, forKey: .commandRedacted)
        cwd = try container.decode(WorkingDirectory.self, forKey: .cwd)
        ruleID = try container.decodeIfPresent(RuleID.self, forKey: .ruleID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        let stamp = try container.decodeIfPresent(Date.self, forKey: .consumedAt)
        switch kind {
        case .pending:
            if stamp != nil {
                throw DecodingError.dataCorruptedError(
                    forKey: .consumedAt,
                    in: container,
                    debugDescription: "pending allow-once must omit consumed_at"
                )
            }
            lifecycle = .pending
        case .granted:
            if stamp != nil {
                throw DecodingError.dataCorruptedError(
                    forKey: .consumedAt,
                    in: container,
                    debugDescription: "granted allow-once must omit consumed_at"
                )
            }
            lifecycle = .granted
        case .consumed:
            guard let stamp else {
                throw DecodingError.dataCorruptedError(
                    forKey: .consumedAt,
                    in: container,
                    debugDescription: "consumed allow-once requires consumed_at"
                )
            }
            lifecycle = .consumed(at: stamp)
        }
    }
}

public struct AllowOnceListRow: Sendable, Equatable {
    public var kind: AllowOnceRecord.Kind
    public var codeHash: String
    public var commandRedacted: String
    public var cwd: WorkingDirectory
    public var createdAt: Date
    public var expiresAt: Date
}

public func commandFingerprint(_ matchingView: MatchingView) -> String {
    sha256Hex(matchingView.rawValue)
}

func sha256Hex(_ text: String) -> String {
    let digest = SHA256.hash(data: Data(text.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

func redactCommand(_ matchingView: MatchingView) -> String {
    let text = matchingView.rawValue
    guard text.isEmpty == false else { return "[redacted]" }
    let tokens = text.split(whereSeparator: \.isWhitespace)
    guard let head = tokens.first else { return "[redacted]" }
    if tokens.count == 1 {
        return String(head)
    }
    return "\(head) …"
}
