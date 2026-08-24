/// Why the daemon refused a handshake or method frame. Raw values are
/// wire-stable: changing one breaks decoding for shipped clients.
public enum SkewReason: String, Codable, Sendable, Equatable {
    case protocolSkew = "protocol"
    case majorVersion = "major version"
    case corePacksUnavailable = "core packs unavailable"
    case handshakeRequired = "handshake required"
}
