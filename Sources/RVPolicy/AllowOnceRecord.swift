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

public enum AllowOnceError: Error, Sendable, Equatable {
    case ttyRequired
    case robotRefused
    case unknownCode
    case expired
    case alreadySpent
    case collision
    case alreadyPending
    case encodeFailed
    case lockFailed
    case emptyCommand
    /// M-33: manual mint refused — the command evaluates to a pinned deny
    /// no allow-once grant can unlock. Pre-arming it would waste the LA
    /// ceremony plus attestation; spend time would deny anyway.
    case notUnlockable
    /// Step 8B.1: the pending row changed between pre-LA display and the
    /// redeem re-read (TOCTOU bind). Never attest a swapped row.
    case redemptionChanged
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
    public var codeHash: CodeHash
    /// Grant fingerprint (`grantFingerprint`, B1): the view digest folded
    /// with the invocation-prefix digest. The name and wire key predate
    /// the folding and are kept for row compatibility.
    public var commandFingerprint: GrantFingerprint
    public var commandRedacted: String
    public var cwd: WorkingDirectory
    public var ruleID: RuleID?
    public var createdAt: Date
    public var expiresAt: Date
    /// M-07 content digest of the masked payload. Nil for legacy rows and
    /// mints without exact text. The redeem TOCTOU binds it, and TTY
    /// attestation carries it so the daemon plants a bound grant.
    /// Never exact segments.
    public var payloadDigest: ContentPayloadDigest?
    /// Display-safe invocation-prefix tag (`"sudo"`, `"FOO=… sudo"`), or
    /// nil for bare commands and legacy rows. Names and basenames only —
    /// never secret values. Shown in `list` and the LA prompt so the
    /// human sees the wrappers the normalized view erases.
    public var invocationDisplay: String?

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
        codeHash: CodeHash,
        commandFingerprint: GrantFingerprint,
        commandRedacted: String,
        cwd: WorkingDirectory,
        ruleID: RuleID?,
        createdAt: Date,
        expiresAt: Date,
        payloadDigest: ContentPayloadDigest? = nil,
        invocationDisplay: String? = nil
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
        self.payloadDigest = payloadDigest
        self.invocationDisplay = invocationDisplay
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
        case payloadDigest = "payload_digest"
        case invocationDisplay = "invocation_display"
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
        try container.encodeIfPresent(payloadDigest, forKey: .payloadDigest)
        try container.encodeIfPresent(invocationDisplay, forKey: .invocationDisplay)
        if case .consumed(let at) = lifecycle {
            try container.encode(at, forKey: .consumedAt)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let kind = try container.decode(Kind.self, forKey: .kind)
        codeHash = try container.decode(CodeHash.self, forKey: .codeHash)
        commandFingerprint = try container.decode(GrantFingerprint.self, forKey: .commandFingerprint)
        commandRedacted = try container.decode(String.self, forKey: .commandRedacted)
        cwd = try container.decode(WorkingDirectory.self, forKey: .cwd)
        ruleID = try container.decodeIfPresent(RuleID.self, forKey: .ruleID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        payloadDigest = try container.decodeIfPresent(ContentPayloadDigest.self, forKey: .payloadDigest)
        invocationDisplay = try container.decodeIfPresent(String.self, forKey: .invocationDisplay)
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
    /// Deny rule this row unlocks, when minted from a deny. Names the
    /// grant in the TTY redeem authentication prompt; nil for pre-armed
    /// mints. Part of the redeem TOCTOU row equality.
    public var ruleID: RuleID? = nil
    /// Display-safe invocation-prefix tag, or nil for bare commands.
    /// Part of the redeem TOCTOU row equality.
    public var invocationDisplay: String? = nil
}

/// Unfolded view digest: the pre-B1 intermediate `grantFingerprint` folds
/// with the invocation prefix. Stays a plain string: it is never stored.
public func commandFingerprint(_ matchingView: MatchingView) -> String {
    sha256Hex(matchingView.rawValue)
}

/// Grant fingerprint: the view digest folded with the invocation-prefix
/// digest. The normalized view erases wrappers, assignments, and the argv0
/// path, so binding the view alone lets one approval cover an unreviewed
/// `sudo`/`env`/path/assignment variant (B1). Folding the prefix digest
/// keeps the same opaque 64-hex shape — rows, attestation, and the memory
/// table carry it unchanged — while separating every erased variant.
///
/// `[]` binds the bare invocation. Callers without exact text (legacy
/// mint ports) bind `[]`: a wrapped spend then mismatches and fails
/// closed, exactly like an unbound M-07 payload.
public func grantFingerprint(_ matchingView: MatchingView, invocationPrefix: [String]) -> GrantFingerprint {
    GrantFingerprint(
        rawValue: sha256Hex(
            commandFingerprint(matchingView) + ":" + maskedPayloadContentDigest(invocationPrefix).rawValue
        )
    )
}

public func sha256Hex(_ text: String) -> String {
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
