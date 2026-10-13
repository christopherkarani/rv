#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
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
        #expect(store.consumeGrant(server: "gh", tool: "push", argumentsHash: "h1") == .forged(id: unsigned))
        #expect(store.consumeGrant(server: "gh", tool: "push", argumentsHash: "h1") == .none)

        let rebound = try #require(store.request(server: "gh", tool: "push", argumentsHash: "h2", argumentKeys: [])?.id)
        #expect(store.grant(id: rebound) != nil)
        try rewrite(fileURL) { $0.replacingOccurrences(of: "\"h2\"", with: "\"h3\"") }
        #expect(store.consumeGrant(server: "gh", tool: "push", argumentsHash: "h3") == .forged(id: rebound))

        let otherKey = MCPApprovalStore(
            configDirectory: directory, keys: MCPApprovalKeyStore(load: { MCPSigner(key: Self.key) }, loadOrCreate: { MCPSigner(key: Self.key) }))
        let signedElsewhere = try #require(otherKey.request(server: "gh", tool: "push", argumentsHash: "h4", argumentKeys: [])?.id)
        #expect(otherKey.grant(id: signedElsewhere) != nil)
        #expect(store.consumeGrant(server: "gh", tool: "push", argumentsHash: "h4") == .forged(id: signedElsewhere))

        let keyless = MCPApprovalStore(configDirectory: directory, keys: .unavailable)
        let lost = try #require(store.request(server: "gh", tool: "push", argumentsHash: "h5", argumentKeys: [])?.id)
        #expect(store.grant(id: lost) != nil)
        #expect(keyless.consumeGrant(server: "gh", tool: "push", argumentsHash: "h5") == .forged(id: lost))
        #expect(keyless.grant(id: "any") == nil)
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
