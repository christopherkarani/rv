/// Why a hello ack is skewed. Raw values are wire-stable.
/// `handshake required` is a method-frame error, not a hello status.
public enum HelloSkewReason: String, Codable, Sendable, Equatable {
    case protocolSkew = "protocol"
    case majorVersion = "major version"
    case corePacksUnavailable = "core packs unavailable"
}

/// Why a method frame was refused, including a missing handshake. Raw values are
/// wire-stable: changing one breaks decoding for shipped clients.
public enum SkewReason: String, Codable, Sendable, Equatable {
    case protocolSkew = "protocol"
    case majorVersion = "major version"
    case corePacksUnavailable = "core packs unavailable"
    case handshakeRequired = "handshake required"
}
