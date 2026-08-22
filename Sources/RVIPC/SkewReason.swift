/// Why the daemon refused a hello handshake. Raw values are wire-stable:
/// changing one breaks handshake decoding for shipped clients.
public enum SkewReason: String, Codable, Sendable, Equatable {
    case protocolSkew = "protocol"
    case majorVersion = "major version"
    case corePacksUnavailable = "core packs unavailable"
}
