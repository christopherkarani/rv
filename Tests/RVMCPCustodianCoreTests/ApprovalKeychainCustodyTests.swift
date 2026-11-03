#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if canImport(Security)
import Security
#endif
import Testing
@testable import RVMCP
@testable import RVMCPCustodianCore

@Suite("MCP custodian keychain custody")
struct ApprovalKeychainCustodyTests {
    static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rv-custodian-keys-\(UUID().uuidString)")
    }

    @Test func approvalKeyRequiresUserPresenceAndRejectsSilentCopy() {
        #expect(ApprovalKeyProtection.requiresUserPresence)
        #expect(ApprovalKeyProtection.usesDataProtectionKeychain)
        #expect(ApprovalKeyProtection.allowsSilentCopy == false)
    }

    @Test func plantedApprovalItemWithoutUserPresenceIsNotAdopted() {
        #expect(ApprovalKeyAccess.requiresUserPresence(nil) == false)
        #expect(ApprovalKeyAccess.requiresUserPresence([:]) == false)
        #expect(ApprovalKeyAccess.requiresUserPresence(["dacl": "default"]) == false)
        #expect(ApprovalKeyAccess.requiresUserPresence(["od": ["cup": true]]) == false)
        #expect(ApprovalKeyAccess.requiresUserPresence(["od": ["cpo": true]]))
        #expect(ApprovalKeyAccess.requiresUserPresence(["cpo": true]))
        let parsed = ApprovalKeyAccess.stringKeyed(["od": ["cpo": true]] as NSDictionary)
        #expect(ApprovalKeyAccess.requiresUserPresence(parsed))
        let passcodeOnly = ApprovalKeyAccess.stringKeyed(["od": ["cup": true]] as NSDictionary)
        #expect(ApprovalKeyAccess.requiresUserPresence(passcodeOnly) == false)
        #expect(ApprovalKeyAccess.adoption(.absent) == .absent)
        #expect(ApprovalKeyAccess.adoption(.unreadable) == .rejectKeep)
        #expect(ApprovalKeyAccess.adoption(.noAccessControl) == .rejectAndDelete)
        #expect(ApprovalKeyAccess.adoption(.constraints(userPresence: false)) == .rejectAndDelete)
        #expect(ApprovalKeyAccess.adoption(.constraints(userPresence: true)) == .accept)
    }

    @Test func plantedUserPresenceItemIsNotTheSigningSecret() throws {
        let directory = ApprovalKeychainCustodyTests.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plantedText = String(repeating: "ab", count: 32)
        let planted = Data(plantedText.utf8)
        let plantedKey = try #require(MCPHex.decode(Array(plantedText.utf8)))
        #expect(plantedKey.count == 32)
        #expect(ApprovalKeyAccess.adoptedSigner(
            secret: planted, anchor: nil, pinnedFingerprint: nil, constraints: ["cpo": true], configDirectory: directory) == nil)
        #expect(ApprovalKeyAccess.disposition(
            secret: planted, anchor: nil, pinnedFingerprint: nil, item: .constraints(userPresence: true),
            configDirectory: directory) == .rejectPlanted)
        #expect(ApprovalKeyAccess.adoptedSigner(
            secret: planted, anchor: nil, pinnedFingerprint: nil, constraints: ["od": ["cpo": true]],
            configDirectory: directory) == nil)

        let real = [UInt8](repeating: 9, count: 32)
        let anchor = [UInt8](repeating: 3, count: 32)
        let enrollment = try #require(ApprovalKeyEnrollment.issue(key: real, anchor: anchor))
        let pin = enrollment.fingerprint
        #expect(ApprovalKeyAnchor.save(anchor, configDirectory: directory) == false)
        #expect(ApprovalKeyAnchor.load(directory) == nil)
        #expect(enrollment.save(configDirectory: directory))
        let secret = Data(MCPHex.encode(real).utf8)
        let stored = try String(contentsOf: ApprovalKeyEnrollment.url(directory), encoding: .utf8)
        #expect(stored.contains(MCPHex.encode(real)) == false)
        #expect(stored.contains(MCPHex.encode(anchor)) == false)
        #expect(FileManager.default.fileExists(atPath: ApprovalKeyAnchor.url(directory).path) == false)
        let orPolicy: [String: Any] = ["cpo": true, "cup": true, "pkofn": 1]
        #expect(ApprovalKeyAccess.requiresUserPresence(orPolicy) == false)
        #expect(ApprovalKeyAccess.disposition(
            secret: secret, anchor: anchor, pinnedFingerprint: pin, item: ApprovalKeyAccess.item(from: orPolicy),
            configDirectory: directory) == .rejectAndDelete)
        #expect(ApprovalKeyAccess.adoptedSigner(
            secret: secret, anchor: anchor, pinnedFingerprint: pin, constraints: orPolicy, configDirectory: directory) == nil)
        let nested = ApprovalKeyAccess.stringKeyed(["od": ["cpo": true, "cup": true, "pkofn": 1]] as NSDictionary)
        #expect(ApprovalKeyAccess.requiresUserPresence(nested) == false)
        #expect(ApprovalKeyAccess.disposition(
            secret: secret, anchor: anchor, pinnedFingerprint: pin, item: .constraints(userPresence: false),
            configDirectory: directory) == .rejectAndDelete)
        #expect(ApprovalKeyAccess.disposition(
            secret: secret, anchor: anchor, pinnedFingerprint: pin, item: .noAccessControl, configDirectory: directory)
            == .rejectAndDelete)
        #expect(ApprovalKeyAccess.disposition(
            secret: secret, anchor: nil, pinnedFingerprint: nil, item: .unreadable, configDirectory: directory) == .rejectKeep)

        let signer = try #require(ApprovalKeyAccess.adoptedSigner(
            secret: secret, anchor: anchor, pinnedFingerprint: pin, constraints: ["cpo": true], configDirectory: directory))
        let expected = try #require(MCPSigner(key: real))
        #expect(signer.mac("enrollment", ["check"]) == expected.mac("enrollment", ["check"]))
        #expect(ApprovalKeyAccess.adoptedSigner(
            secret: planted, anchor: anchor, pinnedFingerprint: pin, constraints: ["cpo": true], configDirectory: directory) == nil)

        let attacker = [UInt8](repeating: 4, count: 32)
        let forged = try #require(ApprovalKeyEnrollment.issue(key: plantedKey, anchor: attacker))
        #expect(forged.save(configDirectory: directory))
        #expect(ApprovalKeyAccess.adoptedSigner(
            secret: planted, anchor: anchor, pinnedFingerprint: pin, constraints: ["cpo": true], configDirectory: directory) == nil)
        #expect(ApprovalKeyAccess.adoptedSigner(
            secret: secret, anchor: anchor, pinnedFingerprint: pin, constraints: ["cpo": true], configDirectory: directory) == nil)
    }

    @Test func diskWriteDoesNotAdoptAPlantedKeyOrRevealTheMACKey() throws {
        let directory = ApprovalKeychainCustodyTests.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = [UInt8](repeating: 9, count: 32)
        let anchor = [UInt8](repeating: 3, count: 32)
        let plantedText = String(repeating: "ab", count: 32)
        let planted = Data(plantedText.utf8)
        let plantedKey = try #require(MCPHex.decode(Array(plantedText.utf8)))
        let enrollment = try #require(ApprovalKeyEnrollment.issue(key: real, anchor: anchor))
        let pin = enrollment.fingerprint
        #expect(ApprovalKeyAnchor.save(anchor, configDirectory: directory) == false)
        #expect(ApprovalKeyAnchor.load(directory) == nil)
        #expect(enrollment.save(configDirectory: directory))
        let enrolled = try String(contentsOf: ApprovalKeyEnrollment.url(directory), encoding: .utf8)
        #expect(enrolled.contains(MCPHex.encode(real)) == false)
        #expect(enrolled.contains(MCPHex.encode(anchor)) == false)
        #expect(FileManager.default.fileExists(atPath: ApprovalKeyAnchor.url(directory).path) == false)
        let secret = Data(MCPHex.encode(real).utf8)
        let signer = try #require(ApprovalKeyAccess.adoptedSigner(
            secret: secret, anchor: anchor, pinnedFingerprint: pin, constraints: ["cpo": true], configDirectory: directory))
        let expected = try #require(MCPSigner(key: real))
        #expect(signer.mac("enrollment", ["check"]) == expected.mac("enrollment", ["check"]))

        let attacker = [UInt8](repeating: 4, count: 32)
        let fileAnchor = JSONValue.object(["version": .int(1), "anchor": .string(MCPHex.encode(attacker))])
        try Data(fileAnchor.compactText.utf8).write(to: ApprovalKeyAnchor.url(directory))
        chmod(ApprovalKeyAnchor.url(directory).path, 0o600)
        let forged = try #require(ApprovalKeyEnrollment.issue(key: plantedKey, anchor: attacker))
        #expect(forged.save(configDirectory: directory))
        let leaked = try String(contentsOf: ApprovalKeyAnchor.url(directory), encoding: .utf8)
        #expect(leaked.contains(MCPHex.encode(attacker)))
        #expect(leaked.contains(MCPHex.encode(real)) == false)
        #expect(ApprovalKeyAnchor.load(directory) == nil)
        #expect(ApprovalKeyAccess.disposition(
            secret: planted, anchor: nil, pinnedFingerprint: nil, item: .constraints(userPresence: true),
            configDirectory: directory) == .rejectPlanted)
        #expect(ApprovalKeyAccess.adoptedSigner(
            secret: planted, anchor: nil, pinnedFingerprint: nil, constraints: ["cpo": true], configDirectory: directory) == nil)
        #expect(ApprovalKeyAccess.adoptedSigner(
            secret: planted, anchor: anchor, pinnedFingerprint: pin, constraints: ["cpo": true], configDirectory: directory) == nil)
        #expect(ApprovalKeyAccess.adoptedSigner(
            secret: planted, anchor: attacker, pinnedFingerprint: pin, constraints: ["cpo": true], configDirectory: directory) == nil)
        #expect(FileManager.default.fileExists(atPath: ApprovalKeyAnchor.url(directory).path) == false)

        let resealed = try #require(ApprovalKeyEnrollment.issue(key: plantedKey, anchor: anchor))
        #expect(resealed.save(configDirectory: directory))
        let again = JSONValue.object(["version": .int(1), "anchor": .string(MCPHex.encode(anchor))])
        try Data(again.compactText.utf8).write(to: ApprovalKeyAnchor.url(directory))
        chmod(ApprovalKeyAnchor.url(directory).path, 0o600)
        let copied = try String(contentsOf: ApprovalKeyAnchor.url(directory), encoding: .utf8)
        #expect(copied.contains(MCPHex.encode(anchor)))
        #expect(copied.contains(MCPHex.encode(real)) == false)
        #expect(ApprovalKeyAnchor.load(directory) == nil)
        #expect(ApprovalKeyAccess.adoptedSigner(
            secret: planted, anchor: anchor, pinnedFingerprint: pin, constraints: ["cpo": true], configDirectory: directory) == nil)
        #expect(FileManager.default.fileExists(atPath: ApprovalKeyAnchor.url(directory).path) == false)

        #expect(enrollment.save(configDirectory: directory))
        let restored = try #require(ApprovalKeyAccess.adoptedSigner(
            secret: secret, anchor: anchor, pinnedFingerprint: pin, constraints: ["cpo": true], configDirectory: directory))
        #expect(restored.mac("enrollment", ["check"]) == expected.mac("enrollment", ["check"]))
    }

    @Test func consistentKeychainPairFromAnotherProcessIsAdoptedButDiskMaterialIsNot() throws {
        // `rv mcp serve` creates the key and `rv mcp approve` runs later in a
        // different process, so a pair sealed by the keychain anchor item
        // must verify cross-process. What disk alone can produce — an
        // enrollment file with no keychain anchor/pin behind it — must not.
        let directory = ApprovalKeychainCustodyTests.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let otherProcessKey = [UInt8](repeating: 8, count: 32)
        let otherProcessAnchor = [UInt8](repeating: 6, count: 32)
        let enrollment = try #require(ApprovalKeyEnrollment.issue(key: otherProcessKey, anchor: otherProcessAnchor))
        let pin = enrollment.fingerprint
        #expect(ApprovalKeyAnchor.save(otherProcessAnchor, configDirectory: directory) == false)
        #expect(ApprovalKeyAnchor.load(directory) == nil)
        #expect(enrollment.save(configDirectory: directory))
        let secret = Data(MCPHex.encode(otherProcessKey).utf8)
        let adopted = try #require(ApprovalKeyAccess.adoptedSigner(
            secret: secret, anchor: otherProcessAnchor, pinnedFingerprint: pin, constraints: ["cpo": true],
            configDirectory: directory))
        let otherExpected = try #require(MCPSigner(key: otherProcessKey))
        #expect(adopted.mac("enrollment", ["check"]) == otherExpected.mac("enrollment", ["check"]))
        #expect(ApprovalKeyAccess.disposition(
            secret: secret, anchor: otherProcessAnchor, pinnedFingerprint: pin, item: .constraints(userPresence: true),
            configDirectory: directory) == .accept)
        // The same secret with no keychain seal behind it is planted.
        #expect(ApprovalKeyAccess.adoptedSigner(
            secret: secret, anchor: nil, pinnedFingerprint: nil, constraints: ["cpo": true],
            configDirectory: directory) == nil)
        #expect(ApprovalKeyAccess.disposition(
            secret: secret, anchor: nil, pinnedFingerprint: nil, item: .constraints(userPresence: true),
            configDirectory: directory) == .rejectPlanted)

        let diskKey = [UInt8](repeating: 2, count: 32)
        let diskAnchor = [UInt8](repeating: 1, count: 32)
        let diskEnrollment = try #require(ApprovalKeyEnrollment.issue(key: diskKey, anchor: diskAnchor))
        #expect(diskEnrollment.save(configDirectory: directory))
        let fileAnchor = JSONValue.object(["version": .int(1), "anchor": .string(MCPHex.encode(diskAnchor))])
        try Data(fileAnchor.compactText.utf8).write(to: ApprovalKeyAnchor.url(directory))
        chmod(ApprovalKeyAnchor.url(directory).path, 0o600)
        #expect(ApprovalKeyAnchor.load(directory) == nil)
        // Production never passes a disk-read anchor; with none, no adoption.
        #expect(ApprovalKeyAccess.adoptedSigner(
            secret: Data(MCPHex.encode(diskKey).utf8), anchor: nil, pinnedFingerprint: nil,
            constraints: ["cpo": true], configDirectory: directory) == nil)
        #expect(FileManager.default.fileExists(atPath: ApprovalKeyAnchor.url(directory).path))

        let real = [UInt8](repeating: 5, count: 32)
        let realAnchor = [UInt8](repeating: 4, count: 32)
        let realEnrollment = try #require(ApprovalKeyEnrollment.issue(key: real, anchor: realAnchor))
        #expect(realEnrollment.save(configDirectory: directory))
        let signer = try #require(ApprovalKeyAccess.adoptedSigner(
            secret: Data(MCPHex.encode(real).utf8), anchor: realAnchor, pinnedFingerprint: realEnrollment.fingerprint,
            constraints: ["cpo": true], configDirectory: directory))
        let expected = try #require(MCPSigner(key: real))
        #expect(signer.mac("enrollment", ["check"]) == expected.mac("enrollment", ["check"]))
    }

    #if os(macOS)
    @Test func approvalKeychainQueryRequiresUserPresence() throws {
        let secret = Data("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff".utf8)
        let group = "TEAMID0000.\(MCPCustodianWire.accessGroupSuffix)"
        let add = try #require(ApprovalKeychain.addQuery(value: secret, accessGroup: group))
        #expect(ApprovalKeychain.addQuery(value: secret, accessGroup: nil) == nil)
        #expect(add[kSecAttrAccessControl as String] != nil)
        #expect(add[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(add[kSecAttrAccessible as String] == nil)
        #expect(ApprovalKeychain.liveUsesSilentCopy == false)
        #expect(ApprovalKeychain.protectedStoreEnabled)

        let silent = ApprovalKeychain.copyQuery(silent: true, accessGroup: group)
        #expect(silent[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String)
        #expect(silent[kSecUseDataProtectionKeychain as String] as? Bool == true)
        let live = ApprovalKeychain.copyQuery(silent: false, accessGroup: group)
        #expect(live[kSecUseAuthenticationUI as String] == nil)
        #expect(live[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(live[kSecReturnData as String] as? Bool == true)
        let read = ApprovalKeychain.readQuery(accessGroup: group)
        #expect(read[kSecUseAuthenticationUI as String] == nil)
        #expect(read[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(read[kSecReturnData as String] as? Bool == true)
        #expect(read[kSecReturnAttributes as String] as? Bool == true)
        #expect(read[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)

        // Every data-protection query is scoped to the custodian's access
        // group, for both the key and the anchor account.
        for account in [MCPApprovalKeyIdentity.keychainAccount, MCPApprovalKeyIdentity.anchorAccount] {
            #expect(ApprovalKeychain.existenceQuery(account: account, accessGroup: group)[kSecAttrAccessGroup as String] as? String == group)
            #expect(ApprovalKeychain.copyQuery(silent: true, account: account, accessGroup: group)[kSecAttrAccessGroup as String] as? String == group)
            #expect(ApprovalKeychain.readQuery(account: account, accessGroup: group)[kSecAttrAccessGroup as String] as? String == group)
            #expect(ApprovalKeychain.deleteQuery(account: account, accessGroup: group)[kSecAttrAccessGroup as String] as? String == group)
            let groupedAdd = try #require(ApprovalKeychain.addQuery(value: secret, account: account, accessGroup: group))
            #expect(groupedAdd[kSecAttrAccessGroup as String] as? String == group)
        }
        #expect(add[kSecAttrAccessGroup as String] as? String == group)

        // Promptable reads share one authentication context (short Touch ID
        // reuse window so one onboard burst prompts once); the silent ACL
        // probe must never carry it or presence detection would lie.
        #expect(read[kSecUseAuthenticationContext as String] != nil)
        #expect(silent[kSecUseAuthenticationContext as String] == nil)
        #expect(live[kSecUseAuthenticationContext as String] == nil)
        #expect(ApprovalKeychain.authReuseDuration == 30)

        // The legacy cleanup delete must stay out of the data-protection
        // store: an unflagged SecItemDelete matches the protected item
        // too (observed live), which made every read destroy the key.
        for account in [MCPApprovalKeyIdentity.keychainAccount, MCPApprovalKeyIdentity.anchorAccount] {
            let legacy = ApprovalKeychain.unprotectedDeleteQuery(account: account)
            #expect(legacy[kSecUseDataProtectionKeychain as String] as? Bool == false)
            #expect(legacy[kSecAttrAccessGroup as String] == nil)
            #expect(legacy[kSecAttrAccount as String] as? String == account)
        }
    }
    #endif
}
