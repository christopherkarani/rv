/// Allow-once digest domains. Each digest kind is a distinct
/// `RawRepresentable` String newtype so cross-domain comparison and
/// swapped arguments do not compile; all code as identical strings.
public enum PayloadBinding: Sendable, Equatable, Codable {
    /// Legacy plant with no payload digest. Authorizes unknown/unmasked
    /// spends; fails closed on masked spends.
    case unbound
    /// Hook-ceremony plant: digest under the per-table random salt.
    case salted(SaltedPayloadDigest)
    /// TTY-attestation plant: unsalted content digest the genuine CLI
    /// reviewed. Exact segments never cross IPC.
    case content(ContentPayloadDigest)

    private enum CodingKeys: String, CodingKey {
        case unbound
        case salted
        case content
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unbound:
            try container.encode(true, forKey: .unbound)
        case .salted(let digest):
            try container.encode(digest, forKey: .salted)
        case .content(let digest):
            try container.encode(digest, forKey: .content)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Both-set wire shapes fail closed: exactly one case key.
        var found: PayloadBinding?
        func clash() -> DecodingError {
            DecodingError.dataCorruptedError(
                forKey: .unbound,
                in: container,
                debugDescription: "PayloadBinding must carry exactly one binding"
            )
        }
        if container.contains(.salted) {
            found = .salted(try container.decode(SaltedPayloadDigest.self, forKey: .salted))
        }
        if container.contains(.content) {
            guard found == nil else { throw clash() }
            found = .content(try container.decode(ContentPayloadDigest.self, forKey: .content))
        }
        if container.contains(.unbound) {
            guard found == nil else { throw clash() }
            guard try container.decode(Bool.self, forKey: .unbound) else { throw clash() }
            found = .unbound
        }
        guard let found else {
            throw DecodingError.dataCorruptedError(
                forKey: .unbound,
                in: container,
                debugDescription: "PayloadBinding requires one of unbound/salted/content"
            )
        }
        self = found
    }
}

/// Salted masked-payload digest for one ephemeral table. Memory-only;
/// never crosses IPC or the filesystem.
public struct SaltedPayloadDigest: RawRepresentable, Hashable, Sendable, Equatable, Codable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Unsalted content digest of masked payload segments. Durable form for
/// file rows, allowlist entries, pending asks, and TTY attestation.
public struct ContentPayloadDigest: RawRepresentable, Hashable, Sendable, Equatable, Codable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Failable 64-hex shape gate. Single source of truth for the
    /// content-digest shape, shared by decode and the attest handler.
    public init?(validatingHex text: String) {
        guard isLowercaseHex64(text) else { return nil }
        rawValue = text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard isLowercaseHex64(text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "ContentPayloadDigest must be 64 lowercase hex digits"
            )
        }
        rawValue = text
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Ceremony code dedupe key. Opaque: hex digests plus `tty:`/`pending:`
/// prefixed keys. Never hex-validated.
public struct CodeHash: RawRepresentable, Hashable, Sendable, Equatable, Codable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Grant fingerprint: the view digest folded with the
/// invocation-prefix digest. NOT the `ActionFingerprint` domain
/// (host+session+cwd+command).
public struct GrantFingerprint: RawRepresentable, Hashable, Sendable, Equatable, Codable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Failable 64-hex shape gate. Single source of truth for the
    /// fingerprint shape, shared by decode and the attest handler.
    public init?(validatingHex text: String) {
        guard isLowercaseHex64(text) else { return nil }
        rawValue = text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard isLowercaseHex64(text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "GrantFingerprint must be 64 lowercase hex digits"
            )
        }
        rawValue = text
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// 64-lowercase-hex shape gate shared by the digest newtypes and the
/// attest handler. Exact port of the former attest guards.
public func isLowercaseHex64(_ text: String) -> Bool {
    text.count == 64 && text.allSatisfy(\.isHexDigit) && text == text.lowercased()
}
