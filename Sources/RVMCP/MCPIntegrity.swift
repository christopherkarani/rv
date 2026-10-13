import Foundation
import RVDomain
import RVIsolation

public enum MCPIntegrityStatus: Sendable, Equatable {
    /// No mcp.json yet.
    case noConfiguration
    /// mcp.json is byte-for-byte what rv last wrote or what the user trusted.
    case trusted
    /// Changed outside rv, never signed, or no key to check it with.
    case untrusted(String)

    public var isTrusted: Bool {
        if case .untrusted = self { return false }
        return true
    }

    public var label: String {
        switch self {
        case .noConfiguration: "none"
        case .trusted: "trusted"
        case .untrusted: "untrusted"
        }
    }

    public var problem: String? {
        guard case .untrusted(let reason) = self else { return nil }
        return "mcp.json was edited outside rv (\(reason)); review it, then run `rv mcp trust`"
    }
}

/// `~/.config/rv/mcp-integrity.json`: an HMAC of mcp.json's exact bytes,
/// written by every rv write of mcp.json and by `rv mcp trust`. A process
/// running as the user can still change mcp.json; it cannot make it look
/// like rv wrote it.
public enum MCPIntegrity {
    public static let fileName = "mcp-integrity.json"
    static let purpose = "mcp.json"

    static func url(_ configDirectory: URL) -> URL {
        configDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    static func digest(_ data: Data) -> String {
        RVDigest.sha256Hex([UInt8](data))
    }

    public static func status(configDirectory: URL, keys: MCPApprovalKeyStore) -> MCPIntegrityStatus {
        let data: Data
        switch OwnerOnlyFile.read(MCPConfiguration.fileURL(configDirectory: configDirectory), maximumBytes: MCPConfiguration.maximumBytes) {
        case .success(nil): return .noConfiguration
        case .success(let bytes?): data = bytes
        case .failure: return .untrusted("unreadable")
        }
        guard let signer = keys.load() else { return .untrusted("rv has no approvals key to check it with") }
        guard case .success(let stored?) = OwnerOnlyFile.read(url(configDirectory), maximumBytes: 4096),
            let mac = (try? JSONValue.parse(stored))?["mcpJSON"]?.stringValue
        else { return .untrusted("no rv signature") }
        return signer.verify(mac, purpose, [digest(data)]) ? .trusted : .untrusted("contents differ from rv's signature")
    }

    public static func sign(_ data: Data, configDirectory: URL, signer: MCPSigner) -> Bool {
        let body = JSONValue.object([
            "version": .int(1),
            "mcpJSON": .string(signer.mac(purpose, [digest(data)])),
        ])
        return OwnerOnlyFile.write(Data(body.prettyText.utf8), to: url(configDirectory))
    }

    /// Signs mcp.json as it is on disk now. False when it is missing or unreadable.
    public static func signCurrent(configDirectory: URL, signer: MCPSigner) -> Bool {
        guard case .success(let data?) = OwnerOnlyFile.read(
            MCPConfiguration.fileURL(configDirectory: configDirectory), maximumBytes: MCPConfiguration.maximumBytes)
        else { return false }
        return sign(data, configDirectory: configDirectory, signer: signer)
    }
}
