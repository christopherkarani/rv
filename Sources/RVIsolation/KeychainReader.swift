#if canImport(Security)
import Security
#endif
import Foundation

/// Host-side keychain reads for policy `keychain` entries. The read runs
/// in the unsandboxed host at spawn; the sandbox receives only the
/// extracted value as one environment variable, exactly like a staged
/// credential copy. Tests pass explicit fakes; production uses `.live`.
struct KeychainReader: Sendable {
    var read: @Sendable (_ service: String, _ account: String) -> Data?
    /// Whether profile `secrets` may be leased on this path. False makes a
    /// profile that lists secrets fail staging.
    var allowsSecrets = true

    static let live = KeychainReader(read: readKeychainItem)

    /// Reads nothing. The identity launch path (prepare/dispatch/redeem)
    /// forbids keychain entries by gate and additionally stages through
    /// this reader, so no secret can reach a runtime even if a gate ever
    /// regresses: staging fails closed, never to a live secret.
    static let denied = KeychainReader(read: { _, _ in nil }, allowsSecrets: false)
}

extension KeychainReader {
    /// The item's creation and modification dates, read without its data,
    /// so it never prompts. Changes when `rv secrets set` rewrites the item.
    static func modificationMarker(_ service: String, _ account: String) -> String? {
        #if os(macOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let attributes = result as? [String: Any]
        else { return nil }
        let created = (attributes[kSecAttrCreationDate as String] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let modified = (attributes[kSecAttrModificationDate as String] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        return "\(created)/\(modified)"
        #else
        return nil
        #endif
    }
}

#if os(macOS)
private func readKeychainItem(_ service: String, _ account: String) -> Data? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
    ]
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
        let data = result as? Data
    else { return nil }
    return data
}
#else
private func readKeychainItem(_ service: String, _ account: String) -> Data? {
    nil
}
#endif
