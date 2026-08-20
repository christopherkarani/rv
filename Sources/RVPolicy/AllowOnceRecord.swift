import CryptoKit
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

public struct AllowOnceRecord: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case pending
        case granted
        case consumed
    }

    public var schemaVersion: Int
    public var kind: Kind
    public var codeHash: String
    public var commandFingerprint: String
    public var commandRedacted: String
    public var cwd: String
    public var ruleID: String?
    public var createdAt: Date
    public var expiresAt: Date
    public var consumedAt: Date?

    public init(
        schemaVersion: Int,
        kind: Kind,
        codeHash: String,
        commandFingerprint: String,
        commandRedacted: String,
        cwd: String,
        ruleID: String?,
        createdAt: Date,
        expiresAt: Date,
        consumedAt: Date?
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.codeHash = codeHash
        self.commandFingerprint = commandFingerprint
        self.commandRedacted = commandRedacted
        self.cwd = cwd
        self.ruleID = ruleID
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.consumedAt = consumedAt
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
}

public struct AllowOnceListRow: Sendable, Equatable {
    public var kind: AllowOnceRecord.Kind
    public var codeHash: String
    public var commandRedacted: String
    public var cwd: String
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
