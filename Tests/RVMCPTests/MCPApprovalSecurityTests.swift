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

    static func fixedSigning(honorsGrants: Bool = true) -> MCPApprovalSigning {
        .inProcess(
            honorsGrants: honorsGrants,
            load: { MCPSigner(key: key) }, loadOrCreate: { MCPSigner(key: key) })
    }

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
        let signing = MCPApprovalSigning.file(configDirectory: directory)
        #expect(signing.status() == .notEnrolled)
        #expect(signing.verify("00", "p", ["x"]) == nil)
        #expect(signing.mac("p", ["x"], false) == nil)
        let url = directory.appendingPathComponent(MCPApprovalKeyIdentity.fileName)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
        let first = try #require(signing.mac("p", ["x"], true))
        let again = try #require(signing.mac("p", ["x"], true))
        #expect(first == again)
        #expect(signing.status() == .enrolled)
        #expect(signing.verify(first, "p", ["x"]) == true)
        var info = stat()
        #expect(stat(url.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)

        #expect(chmod(url.path, 0o644) == 0)
        #expect(signing.verify(first, "p", ["x"]) == nil)
        #expect(chmod(url.path, 0o600) == 0)
        #expect(signing.verify(first, "p", ["x"]) == true)
        try Data("short".utf8).write(to: url)
        #expect(chmod(url.path, 0o600) == 0)
        #expect(signing.verify(first, "p", ["x"]) == nil)
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
        let store = MCPApprovalStore(configDirectory: directory, signing: .file(configDirectory: directory))
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
        let signing = MCPApprovalSigning.file(configDirectory: directory)
        let store = MCPApprovalStore(configDirectory: directory, signing: signing)
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
            configDirectory: directory, signing: Self.fixedSigning())
        let signedElsewhere = try #require(otherKey.request(server: "gh", tool: "push", argumentsHash: "h4", argumentKeys: [])?.id)
        #expect(otherKey.grant(id: signedElsewhere, server: "gh", tool: "push", argumentsHash: "h4", argumentKeys: []) != nil)
        #expect(store.consumeGrant(server: "gh", tool: "push", argumentsHash: "h4", argumentKeys: []) == .forged(id: signedElsewhere))

        let keyless = MCPApprovalStore(configDirectory: directory, signing: .unavailable)
        let kept = try #require(store.request(server: "gh", tool: "push", argumentsHash: "h5", argumentKeys: [])?.id)
        #expect(store.grant(id: kept, server: "gh", tool: "push", argumentsHash: "h5", argumentKeys: []) != nil)
        // No key means "cannot verify", not "forged": the legitimate grant
        // stays in place for a gateway that can load the key, and is then
        // consumable exactly once.
        #expect(keyless.consumeGrant(server: "gh", tool: "push", argumentsHash: "h5", argumentKeys: []) == .none)
        #expect(store.consumeGrant(server: "gh", tool: "push", argumentsHash: "h5", argumentKeys: []) == .granted(id: kept))
        #expect(keyless.grant(id: "any", server: "gh", tool: "push", argumentsHash: "h5", argumentKeys: []) == nil)
    }

    /// Linux file custody: the key is readable by any same-user process,
    /// so a correctly MAC'd grant proves nothing about who approved.
    /// Such a store must never mint, grant, verify, or consume approvals.
    @Test func sameUserFileCustodyNeverMintsOrHonorsGrants() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyed = MCPApprovalStore(
            configDirectory: directory,
            signing: Self.fixedSigning())
        let ticket = try #require(keyed.request(server: "gh", tool: "push", argumentsHash: "h1", argumentKeys: []))
        #expect(keyed.grant(id: ticket.id, server: "gh", tool: "push", argumentsHash: "h1", argumentKeys: []) != nil)

        let fileCustody = MCPApprovalStore(
            configDirectory: directory,
            signing: Self.fixedSigning(honorsGrants: false))
        #expect(fileCustody.request(server: "gh", tool: "push", argumentsHash: "h2", argumentKeys: []) == nil)
        #expect(fileCustody.grant(id: ticket.id, server: "gh", tool: "push", argumentsHash: "h1", argumentKeys: []) == nil)
        #expect(fileCustody.verifyCode(id: ticket.id, typed: ticket.code ?? "") == false)
        #expect(fileCustody.consumeGrant(server: "gh", tool: "push", argumentsHash: "h1", argumentKeys: []) == .none)
        // Untouched: a gateway whose key needs the person present can still use it.
        #expect(keyed.consumeGrant(server: "gh", tool: "push", argumentsHash: "h1", argumentKeys: []) == .granted(id: ticket.id))
    }

    @Test func rewrittenPendingRowIsNotSigned() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MCPApprovalStore(configDirectory: directory, signing: .file(configDirectory: directory))
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
        let store = MCPApprovalStore(configDirectory: directory, signing: .file(configDirectory: directory))
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
        let signing = MCPApprovalSigning.file(configDirectory: directory)
        #expect(MCPIntegrity.status(configDirectory: directory, signing: signing) == .noConfiguration)

        let configuration = MCPConfiguration(servers: [
            MCPServerDefinition(name: "gh", command: "gh-mcp", tools: MCPToolPolicy(allow: ["list_*"]))
        ])
        _ = try configuration.write(configDirectory: directory, signing: signing).get()
        #expect(MCPIntegrity.status(configDirectory: directory, signing: signing) == .trusted)

        let url = MCPConfiguration.fileURL(configDirectory: directory)
        let edited = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "list_*", with: "*")
        try Data(edited.utf8).write(to: url)
        let status = MCPIntegrity.status(configDirectory: directory, signing: signing)
        #expect(status == .untrusted("contents differ from rv's signature"))
        #expect(status.problem?.contains("edited outside rv") == true)
        #expect(MCPIntegrity.status(configDirectory: directory, signing: .unavailable).isTrusted == false)

        #expect(MCPIntegrity.signCurrent(configDirectory: directory, signing: signing))
        #expect(MCPIntegrity.status(configDirectory: directory, signing: signing) == .trusted)

        try FileManager.default.removeItem(at: directory.appendingPathComponent(MCPIntegrity.fileName))
        #expect(MCPIntegrity.status(configDirectory: directory, signing: signing) == .untrusted("no rv signature"))
    }


    @Test func integrityJudgesTheBytesItWasGivenWhenTheFileChangesDuringKeyLoad() throws {
        let directory = MCPApprovalSecurityTests.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let signing = MCPApprovalSigning.file(configDirectory: directory)
        let configuration = MCPConfiguration(servers: [MCPServerDefinition(name: "fs", command: "fs-mcp")])
        _ = try configuration.write(configDirectory: directory, signing: signing).get()
        let url = MCPConfiguration.fileURL(configDirectory: directory)
        let trusted = try Data(contentsOf: url)
        let evil = Data(String(decoding: trusted, as: UTF8.self).replacingOccurrences(of: "fs-mcp", with: "evil-binary").utf8)
        try evil.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
        let swapping = MCPApprovalSigning(
            status: { signing.status() },
            mac: { signing.mac($0, $1, $2) },
            verify: { candidate, purpose, fields in
                try? trusted.write(to: url, options: .atomic)
                chmod(url.path, 0o600)
                return signing.verify(candidate, purpose, fields)
            })
        #expect(MCPIntegrity.status(of: evil, configDirectory: directory, signing: swapping)
            == .untrusted("contents differ from rv's signature"))
        #expect(MCPIntegrity.status(configDirectory: directory, signing: signing) == .trusted)
    }


    @Test func untrustedConfigurationTurnsAllowIntoAskOnly() {
        let server = MCPServerDefinition(
            name: "gh", command: "gh-mcp", tools: MCPToolPolicy(allow: ["*"], ask: ["create_*"], deny: ["delete_*"]))
        var configuration = MCPConfiguration(servers: [server])
        #expect(configuration.decision(server: server, tool: "list") == .allow)
        configuration.untrusted = true
        #expect(configuration.decision(server: server, tool: "list") == .ask)
        #expect(configuration.decision(server: server, tool: "create_x") == .ask)
        #expect(configuration.decision(server: server, tool: "delete_x") == .deny)
    }
}
