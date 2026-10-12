#if os(macOS)
import Foundation
import Security
import Testing
@testable import RVIsolation

/// Real login-keychain round trip through the production resolver.
/// Opt in with `RV_LIVE_KEYCHAIN=1` (CI keychains are often locked).
@Suite("SecretKeychainLive", .enabled(if: ProcessInfo.processInfo.environment["RV_LIVE_KEYCHAIN"] == "1"))
struct SecretKeychainLiveTests {
    @Test func liveResolverReadsAGenericPasswordAndReportsMissingItems() throws {
        let service = "rv.test.\(UUID().uuidString)"
        let value = "kc-\(UUID().uuidString)"
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "rv-test",
            kSecValueData as String: Data((value + "\n").utf8),
        ]
        try #require(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)
        defer {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary)
        }
        let resolver = SecretResolver.live(environment: [:], home: NSTemporaryDirectory())
        let resolved = try resolver.resolve(.keychain(service: service, account: "rv-test")).get()
        #expect(resolved.text == value)
        guard case .failure(.notFound) = resolver.resolve(.keychain(service: service, account: "nobody")) else {
            Issue.record("a missing item must be notFound")
            return
        }
    }
}
#endif
