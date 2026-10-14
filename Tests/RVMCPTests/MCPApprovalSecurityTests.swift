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

@Suite("MCP approval keys and grants")
struct MCPApprovalSecurityTests {
    static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rv-mcp-keys-\(UUID().uuidString)")
    }

    static let key = [UInt8](repeating: 7, count: 32)

    @Test func signerNeedsAThirtyTwoByteKeyAndSeparatesFields() throws {
        #expect(MCPSigner(key: [UInt8](repeating: 1, count: 31)) == nil)
        let signer = try #require(MCPSigner(key: Self.key))
        let joined = signer.mac("grant", ["ab", "c"])
        #expect(joined != signer.mac("grant", ["a", "bc"]))
        #expect(joined != signer.mac("code", ["ab", "c"]))
        #expect(signer.verify(joined, "grant", ["ab", "c"]))
        #expect(signer.verify(joined, "grant", ["ab", "d"]) == false)
        #expect(signer.verify(nil, "grant", ["ab", "c"]) == false)
        #expect(signer.verify(String(joined.dropLast()), "grant", ["ab", "c"]) == false)
        let other = try #require(MCPSigner(key: [UInt8](repeating: 8, count: 32)))
        #expect(other.verify(joined, "grant", ["ab", "c"]) == false)
    }

    @Test func keyFileIsCreatedOnceOwnerOnlyAndVerifiersNeverCreateIt() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = MCPApprovalKeyStore.file(configDirectory: directory)
        #expect(keys.load() == nil)
        let url = directory.appendingPathComponent(MCPApprovalKeyStore.fileName)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
        let first = try #require(keys.loadOrCreate())
        let again = try #require(keys.loadOrCreate())
        #expect(first.mac("p", ["x"]) == again.mac("p", ["x"]))
        var info = stat()
        #expect(stat(url.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)

        #expect(chmod(url.path, 0o644) == 0)
        #expect(keys.load() == nil)
        #expect(chmod(url.path, 0o600) == 0)
        #expect(keys.load() != nil)
        try Data("short".utf8).write(to: url)
        #expect(chmod(url.path, 0o600) == 0)
        #expect(keys.load() == nil)
    }

    @Test func confirmationCodesAreTenSymbolsAndNormalize() {
        let code = MCPConfirmationCode.generate()
        #expect(code.count == 11)
        #expect(code.dropFirst(5).first == "-")
        #expect(MCPConfirmationCode.normalize(" abcde-fghjk\n") == "ABCDEFGHJK")
        #expect(Set((0..<20).map { _ in MCPConfirmationCode.generate() }).count == 20)
    }

    @Test func onlyTheNewestPrintedCodeApproves() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MCPApprovalStore(configDirectory: directory, keys: .file(configDirectory: directory))
        let first = try #require(store.request(server: "gh", tool: "create", argumentsHash: "h", argumentKeys: []))
        let firstCode = try #require(first.code)
        #expect(store.hasCode(id: first.id))
        #expect(store.verifyCode(id: first.id, typed: firstCode))
        #expect(store.verifyCode(id: first.id, typed: firstCode.lowercased().replacingOccurrences(of: "-", with: " ")))
        #expect(store.verifyCode(id: first.id, typed: "AAAAA-AAAAA") == false)
        #expect(store.verifyCode(id: "nope", typed: firstCode) == false)

        let second = try #require(store.request(server: "gh", tool: "create", argumentsHash: "h", argumentKeys: []))
        #expect(second.id == first.id)
        let secondCode = try #require(second.code)
        #expect(store.verifyCode(id: first.id, typed: secondCode))
        #expect(firstCode == secondCode || store.verifyCode(id: first.id, typed: firstCode) == false)

        let raw = try String(contentsOf: directory.appendingPathComponent(MCPApprovalStore.fileName), encoding: .utf8)
        #expect(raw.contains(secondCode) == false)
    }

    @Test func editedOrUnsignedGrantsAreRejectedAsForged() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = MCPApprovalKeyStore.file(configDirectory: directory)
        let store = MCPApprovalStore(configDirectory: directory, keys: keys)
        let fileURL = directory.appendingPathComponent(MCPApprovalStore.fileName)

        let unsigned = try #require(store.request(server: "gh", tool: "push", argumentsHash: "h1", argumentKeys: [])?.id)
        try rewrite(fileURL) { $0.replacingOccurrences(of: "\"pending\"", with: "\"granted\"") }
        #expect(store.consumeGrant(server: "gh", tool: "push", argumentsHash: "h1", argumentKeys: []) == .forged(id: unsigned))
        #expect(store.consumeGrant(server: "gh", tool: "push", argumentsHash: "h1", argumentKeys: []) == .none)

        let rebound = try #require(store.request(server: "gh", tool: "push", argumentsHash: "h2", argumentKeys: [])?.id)
        #expect(store.grant(id: rebound, server: "gh", tool: "push", argumentsHash: "h2", argumentKeys: []) != nil)
        try rewrite(fileURL) { $0.replacingOccurrences(of: "\"h2\"", with: "\"h3\"") }
        #expect(store.consumeGrant(server: "gh", tool: "push", argumentsHash: "h3", argumentKeys: []) == .forged(id: rebound))

        let otherKey = MCPApprovalStore(
            configDirectory: directory, keys: MCPApprovalKeyStore(load: { MCPSigner(key: Self.key) }, loadOrCreate: { MCPSigner(key: Self.key) }))
        let signedElsewhere = try #require(otherKey.request(server: "gh", tool: "push", argumentsHash: "h4", argumentKeys: [])?.id)
        #expect(otherKey.grant(id: signedElsewhere, server: "gh", tool: "push", argumentsHash: "h4", argumentKeys: []) != nil)
        #expect(store.consumeGrant(server: "gh", tool: "push", argumentsHash: "h4", argumentKeys: []) == .forged(id: signedElsewhere))

        let keyless = MCPApprovalStore(configDirectory: directory, keys: .unavailable)
        let lost = try #require(store.request(server: "gh", tool: "push", argumentsHash: "h5", argumentKeys: [])?.id)
        #expect(store.grant(id: lost, server: "gh", tool: "push", argumentsHash: "h5", argumentKeys: []) != nil)
        #expect(keyless.consumeGrant(server: "gh", tool: "push", argumentsHash: "h5", argumentKeys: []) == .forged(id: lost))
        #expect(keyless.grant(id: "any", server: "gh", tool: "push", argumentsHash: "h5", argumentKeys: []) == nil)
    }

    @Test func rewrittenPendingRowIsNotSigned() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MCPApprovalStore(configDirectory: directory, keys: .file(configDirectory: directory))
        let ticket = try #require(store.request(server: "gh", tool: "push", argumentsHash: "h1", argumentKeys: ["branch"]))
        let code = try #require(ticket.code)
        let fileURL = directory.appendingPathComponent(MCPApprovalStore.fileName)
        try rewrite(fileURL) { $0.replacingOccurrences(of: "\"push\"", with: "\"steal\"") }

        #expect(store.verifyCode(id: ticket.id, typed: code) == false)
        #expect(store.grant(id: ticket.id, server: "gh", tool: "push", argumentsHash: "h1", argumentKeys: ["branch"]) == nil)
        #expect(store.pending().map(\.tool) == ["steal"])
        #expect(store.pending().allSatisfy { $0.state == .pending && $0.grantMAC == nil })
        #expect(store.consumeGrant(server: "gh", tool: "steal", argumentsHash: "h1", argumentKeys: ["branch"]) == .none)
        #expect(store.consumeGrant(server: "gh", tool: "push", argumentsHash: "h1", argumentKeys: ["branch"]) == .none)
    }

    @Test func rewrittenArgumentKeysAreNotSigned() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MCPApprovalStore(configDirectory: directory, keys: .file(configDirectory: directory))
        let ticket = try #require(store.request(
            server: "fs", tool: "write_file", argumentsHash: "h1", argumentKeys: ["path", "contents"]))
        let code = try #require(ticket.code)
        let fileURL = directory.appendingPathComponent(MCPApprovalStore.fileName)
        let needle = "\"path\",\n        \"contents\""
        try rewrite(fileURL) { text in
            #expect(text.contains(needle))
            return text.replacingOccurrences(of: needle, with: "\"note\"")
        }
        #expect(store.verifyCode(id: ticket.id, typed: code) == false)
        #expect(store.grant(
            id: ticket.id, server: "fs", tool: "write_file", argumentsHash: "h1", argumentKeys: ["path", "contents"]) == nil)
        #expect(store.pending().map(\.argumentKeys) == [["note"]])
        #expect(store.pending().allSatisfy { $0.grantMAC == nil && $0.argumentsHash == "h1" })
        #expect(store.grant(
            id: ticket.id, server: "fs", tool: "write_file", argumentsHash: "h1", argumentKeys: ["note"]) == nil)
        #expect(store.consumeGrant(
            server: "fs", tool: "write_file", argumentsHash: "h1", argumentKeys: ["path", "contents"]) == .none)
    }

    private func rewrite(_ url: URL, _ change: (String) -> String) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        try Data(change(text).utf8).write(to: url)
    }
}

@Suite("mcp.json integrity")
struct MCPIntegrityTests {
    @Test func rvWritesAreTrustedAndOutsideEditsAreNot() throws {
        let directory = MCPApprovalSecurityTests.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = MCPApprovalKeyStore.file(configDirectory: directory)
        #expect(MCPIntegrity.status(configDirectory: directory, keys: keys) == .noConfiguration)

        let configuration = MCPConfiguration(servers: [
            MCPServerDefinition(name: "gh", command: "gh-mcp", tools: MCPToolPolicy(allow: ["list_*"]))
        ])
        let signer = try #require(keys.loadOrCreate())
        _ = try configuration.write(configDirectory: directory, signer: signer).get()
        #expect(MCPIntegrity.status(configDirectory: directory, keys: keys) == .trusted)

        let url = MCPConfiguration.fileURL(configDirectory: directory)
        let edited = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "list_*", with: "*")
        try Data(edited.utf8).write(to: url)
        let status = MCPIntegrity.status(configDirectory: directory, keys: keys)
        #expect(status == .untrusted("contents differ from rv's signature"))
        #expect(status.problem?.contains("edited outside rv") == true)
        #expect(MCPIntegrity.status(configDirectory: directory, keys: .unavailable).isTrusted == false)

        #expect(MCPIntegrity.signCurrent(configDirectory: directory, signer: signer))
        #expect(MCPIntegrity.status(configDirectory: directory, keys: keys) == .trusted)

        try FileManager.default.removeItem(at: directory.appendingPathComponent(MCPIntegrity.fileName))
        #expect(MCPIntegrity.status(configDirectory: directory, keys: keys) == .untrusted("no rv signature"))
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
        let directory = MCPApprovalSecurityTests.scratch()
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
        let directory = MCPApprovalSecurityTests.scratch()
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

    @Test func integrityJudgesTheBytesItWasGivenWhenTheFileChangesDuringKeyLoad() throws {
        let directory = MCPApprovalSecurityTests.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = MCPApprovalKeyStore.file(configDirectory: directory)
        let signer = try #require(keys.loadOrCreate())
        let configuration = MCPConfiguration(servers: [MCPServerDefinition(name: "fs", command: "fs-mcp")])
        _ = try configuration.write(configDirectory: directory, signer: signer).get()
        let url = MCPConfiguration.fileURL(configDirectory: directory)
        let trusted = try Data(contentsOf: url)
        let evil = Data(String(decoding: trusted, as: UTF8.self).replacingOccurrences(of: "fs-mcp", with: "evil-binary").utf8)
        try evil.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
        let swapping = MCPApprovalKeyStore(
            load: {
                try? trusted.write(to: url, options: .atomic)
                chmod(url.path, 0o600)
                return keys.load()
            },
            loadOrCreate: { keys.loadOrCreate() })
        #expect(MCPIntegrity.status(of: evil, configDirectory: directory, keys: swapping)
            == .untrusted("contents differ from rv's signature"))
        #expect(MCPIntegrity.status(configDirectory: directory, keys: keys) == .trusted)
    }

    #if os(macOS)
    @Test func approvalKeychainQueryRequiresUserPresence() throws {
        let secret = Data("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff".utf8)
        let add = try #require(ApprovalKeychain.addQuery(value: secret))
        #expect(add[kSecAttrAccessControl as String] != nil)
        #expect(add[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(add[kSecAttrAccessible as String] == nil)
        #expect(ApprovalKeychain.liveUsesSilentCopy == false)
        #expect(ApprovalKeychain.protectedStoreEnabled)

        let silent = ApprovalKeychain.copyQuery(silent: true)
        #expect(silent[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String)
        #expect(silent[kSecUseDataProtectionKeychain as String] as? Bool == true)
        let live = ApprovalKeychain.copyQuery(silent: false)
        #expect(live[kSecUseAuthenticationUI as String] == nil)
        #expect(live[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(live[kSecReturnData as String] as? Bool == true)
        let read = ApprovalKeychain.readQuery()
        #expect(read[kSecUseAuthenticationUI as String] == nil)
        #expect(read[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(read[kSecReturnData as String] as? Bool == true)
        #expect(read[kSecReturnAttributes as String] as? Bool == true)
        #expect(read[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
    }
    #endif

    @Test func untrustedConfigurationTurnsAllowIntoAskOnly() {
        let server = MCPServerDefinition(
            name: "gh", command: "gh-mcp", tools: MCPToolPolicy(defaultDecision: .allow, ask: ["create_*"], deny: ["delete_*"]))
        var configuration = MCPConfiguration(servers: [server])
        #expect(configuration.decision(server: server, tool: "list") == .allow)
        configuration.untrusted = true
        #expect(configuration.decision(server: server, tool: "list") == .ask)
        #expect(configuration.decision(server: server, tool: "create_x") == .ask)
        #expect(configuration.decision(server: server, tool: "delete_x") == .deny)
    }
}
