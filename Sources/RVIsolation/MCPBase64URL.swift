import Foundation

/// Unpadded base64url over bytes, matching Node `toString("base64url")`.
/// One copy serves the server-auth mint and the WorkOS name hash.
enum MCPBase64URL {
    /// Encodes bytes as unpadded base64url.
    static func encode(_ bytes: Data) -> String {
        bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}
