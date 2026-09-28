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

    static let live = KeychainReader(read: readKeychainItem)
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
