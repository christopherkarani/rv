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

    public static func status(configDirectory: URL, signing: MCPApprovalSigning) -> MCPIntegrityStatus {
        switch OwnerOnlyFile.read(MCPConfiguration.fileURL(configDirectory: configDirectory), maximumBytes: MCPConfiguration.maximumBytes) {
        case .success(let bytes): return status(of: bytes, configDirectory: configDirectory, signing: signing)
        case .failure: return .untrusted("unreadable")
        }
    }

    /// The status of bytes already in hand, so the caller verifies exactly
    /// what it decoded instead of re-reading the file (a swap between the
    /// two reads would verify one file and run another).
    public static func status(of data: Data?, configDirectory: URL, signing: MCPApprovalSigning) -> MCPIntegrityStatus {
        guard let data else { return .noConfiguration }
        guard signing.status() == .enrolled else { return .untrusted("rv has no approvals key to check it with") }
        guard case .success(let stored?) = OwnerOnlyFile.read(url(configDirectory), maximumBytes: 4096),
            let mac = (try? JSONValue.parse(stored))?["mcpJSON"]?.stringValue
        else { return .untrusted("no rv signature") }
        switch signing.verify(mac, purpose, [digest(data)]) {
        case .some(true): return .trusted
        case .some(false): return .untrusted("contents differ from rv's signature")
        case .none: return .untrusted("rv has no approvals key to check it with")
        }
    }

    public static func sign(_ data: Data, configDirectory: URL, signing: MCPApprovalSigning) -> Bool {
        guard let mac = signing.mac(purpose, [digest(data)], true) else { return false }
        let body = JSONValue.object([
            "version": .int(1),
            "mcpJSON": .string(mac),
        ])
        return OwnerOnlyFile.write(Data(body.prettyText.utf8), to: url(configDirectory))
    }

    /// Signs mcp.json as it is on disk now. False when it is missing or unreadable.
    public static func signCurrent(configDirectory: URL, signing: MCPApprovalSigning) -> Bool {
        guard case .success(let data?) = OwnerOnlyFile.read(
            MCPConfiguration.fileURL(configDirectory: configDirectory), maximumBytes: MCPConfiguration.maximumBytes)
        else { return false }
        return sign(data, configDirectory: configDirectory, signing: signing)
    }
}
