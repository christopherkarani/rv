#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if canImport(Security)
import Security
#endif
import Synchronization
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
        #expect(signing.verify("00", .grant, ["x"]) == .noKey)
        #expect(signing.mac(.grant, ["x"], false) == nil)
        let url = directory.appendingPathComponent(MCPApprovalKeyIdentity.fileName)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
        let first = try #require(signing.mac(.grant, ["x"], true))
        let again = try #require(signing.mac(.grant, ["x"], true))
        #expect(first == again)
        #expect(signing.status() == .enrolled)
        #expect(signing.verify(first, .grant, ["x"]) == .valid)
        var info = stat()
        #expect(stat(url.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)

        #expect(chmod(url.path, 0o644) == 0)
        #expect(signing.verify(first, .grant, ["x"]) == .noKey)
        #expect(chmod(url.path, 0o600) == 0)
        #expect(signing.verify(first, .grant, ["x"]) == .valid)
        try Data("short".utf8).write(to: url)
        #expect(chmod(url.path, 0o600) == 0)
        #expect(signing.verify(first, .grant, ["x"]) == .noKey)
    }

    @Test func confirmationCodesAreTenSymbolsAndNormalize() {
        let code = MCPConfirmationCode.generate()
        #expect(code.count == 11)
        #expect(code.dropFirst(5).first == "-")
        #expect(MCPConfirmationCode.normalize(" abcde-fghjk\n") == "ABCDEFGHJK")
        #expect(Set((0..<20).map { _ in MCPConfirmationCode.generate() }).count == 20)
    }

    /// E2: an agent retry never changes the code the person is reading.
    /// The retry gets the same request back, the row is not rewritten, and
    /// the first code still approves; the plaintext never reaches the file.
    @Test func aRetryKeepsTheCodeThePersonIsReading() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MCPApprovalStore(configDirectory: directory, signing: .file(configDirectory: directory))
        let fileURL = directory.appendingPathComponent(MCPApprovalStore.fileName)
        let first = try #require(store.request(server: "gh", tool: "create", argumentsHash: "h", argumentKeys: ["title"]))
        let firstCode = try #require(first.code)
        #expect(first.reused == false)
        #expect(store.hasCode(id: first.id))
        #expect(store.verifyCode(id: first.id, typed: firstCode))
        #expect(store.verifyCode(id: first.id, typed: firstCode.lowercased().replacingOccurrences(of: "-", with: " ")))
        #expect(store.verifyCode(id: first.id, typed: "AAAAA-AAAAA") == false)
        #expect(store.verifyCode(id: "nope", typed: firstCode) == false)
        let before = try Data(contentsOf: fileURL)

        for _ in 0..<5 {
            let retry = try #require(store.request(server: "gh", tool: "create", argumentsHash: "h", argumentKeys: ["title"]))
            #expect(retry == MCPApprovalTicket(id: first.id, code: nil, reused: true))
        }
        #expect(try Data(contentsOf: fileURL) == before, "a retry rewrote the pending request")
        #expect(store.verifyCode(id: first.id, typed: firstCode))
        #expect(store.pending().count == 1)
        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(raw.contains(firstCode) == false)
        #expect(raw.contains(MCPConfirmationCode.normalize(firstCode)) == false)
    }

    /// A different call never maps to a waiting request, and its code never
    /// approves another: tool, arguments, argument names and definition
    /// each make a new request with its own code.
    @Test func aDifferentCallGetsItsOwnRequestAndCode() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MCPApprovalStore(configDirectory: directory, signing: .file(configDirectory: directory))
        let base = try #require(store.request(server: "gh", tool: "create", argumentsHash: "h", argumentKeys: ["title"]))
        let baseCode = try #require(base.code)
        let changed = MCPToolBinding(definitionHash: "d2", pinStatus: .changed)
        let others = [
            store.request(server: "gl", tool: "create", argumentsHash: "h", argumentKeys: ["title"]),
            store.request(server: "gh", tool: "delete", argumentsHash: "h", argumentKeys: ["title"]),
            store.request(server: "gh", tool: "create", argumentsHash: "h2", argumentKeys: ["title"]),
            store.request(server: "gh", tool: "create", argumentsHash: "h", argumentKeys: ["body"]),
            store.request(server: "gh", tool: "create", argumentsHash: "h", argumentKeys: ["title"], binding: changed),
        ]
        var ids: Set<String> = [base.id]
        for other in others {
            let ticket = try #require(other)
            #expect(ticket.reused == false)
            #expect(ids.insert(ticket.id).inserted, "a different call reused request \(ticket.id)")
            let code = try #require(ticket.code)
            #expect(store.verifyCode(id: ticket.id, typed: baseCode) == false)
            #expect(store.verifyCode(id: base.id, typed: code) == false)
        }
        #expect(store.pending().count == 6)
        #expect(store.verifyCode(id: base.id, typed: baseCode))
    }

    /// Single use: once a request is granted and consumed, or refused, the
    /// same call asks again with a new request and a new code, and the old
    /// code approves nothing.
    @Test func aCodeIsSingleUse() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MCPApprovalStore(configDirectory: directory, signing: .file(configDirectory: directory))
        let first = try #require(store.request(server: "gh", tool: "push", argumentsHash: "h", argumentKeys: []))
        let firstCode = try #require(first.code)
        #expect(store.grant(id: first.id, server: "gh", tool: "push", argumentsHash: "h", argumentKeys: []) != nil)
        // Granted, not yet used: the code no longer checks (it is not pending).
        #expect(store.verifyCode(id: first.id, typed: firstCode) == false)
        #expect(store.consumeGrant(server: "gh", tool: "push", argumentsHash: "h", argumentKeys: []) == .granted(id: first.id))

        let second = try #require(store.request(server: "gh", tool: "push", argumentsHash: "h", argumentKeys: []))
        #expect(second.id != first.id)
        #expect(second.reused == false)
        let secondCode = try #require(second.code)
        #expect(store.verifyCode(id: second.id, typed: firstCode) == false)
        #expect(store.verifyCode(id: second.id, typed: secondCode))

        #expect(store.remove(id: second.id) != nil)
        let third = try #require(store.request(server: "gh", tool: "push", argumentsHash: "h", argumentKeys: []))
        #expect(third.id != second.id)
        #expect(third.reused == false)
        #expect(store.verifyCode(id: third.id, typed: secondCode) == false)
    }

    /// The gateway shows the same plaintext code on every retry of a call it
    /// asked for; another gateway (another serve process) that retries the
    /// same call cannot show it and keeps it, never mints a new one.
    @Test func theGatewayShowsTheSameCodeOnEveryRetry() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MCPApprovalStore(configDirectory: directory, signing: .file(configDirectory: directory))
        let gate = MCPApprovalGate.store(store)
        let first = try #require(gate.request("gh", "create", "h", ["title"], .unbound))
        let code = try #require(first.code)
        for _ in 0..<3 {
            #expect(gate.request("gh", "create", "h", ["title"], .unbound) == MCPApprovalTicket(id: first.id, code: code, reused: true))
        }
        let other = MCPApprovalGate.store(store)
        #expect(other.request("gh", "create", "h", ["title"], .unbound) == MCPApprovalTicket(id: first.id, code: nil, reused: true))
        #expect(store.verifyCode(id: first.id, typed: code))
        // A different call through the same gateway never shows this code.
        let different = try #require(gate.request("gh", "create", "h2", ["title"], .unbound))
        #expect(different.id != first.id)
        #expect(different.reused == false)
    }

    /// A request recorded while no key could be made has no code yet; the
    /// first retry that can make one gives it one (nobody is reading an
    /// older code), and later retries keep it.
    @Test func aRequestWithoutACodeGetsOneOnRetry() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyReady = Mutex(false)
        let signing = MCPApprovalSigning(
            status: { .enrolled },
            mac: { purpose, fields, _ in keyReady.withLock { $0 } ? MCPSigner(key: Self.key)?.mac(purpose.rawValue, fields) : nil },
            verify: { candidate, purpose, fields in
                (MCPSigner(key: Self.key)?.verify(candidate, purpose.rawValue, fields) ?? false) ? .valid : .forged
            })
        let store = MCPApprovalStore(configDirectory: directory, signing: signing)
        let keyless = try #require(store.request(server: "gh", tool: "push", argumentsHash: "h", argumentKeys: []))
        #expect(keyless.code == nil)
        #expect(store.hasCode(id: keyless.id) == false)
        keyReady.withLock { $0 = true }
        let minted = try #require(store.request(server: "gh", tool: "push", argumentsHash: "h", argumentKeys: []))
        #expect(minted.id == keyless.id)
        let code = try #require(minted.code)
        #expect(store.verifyCode(id: minted.id, typed: code))
        let request = try #require(store.pending().first)
        #expect(store.argumentKeysAreBound(request))
        #expect(store.request(server: "gh", tool: "push", argumentsHash: "h", argumentKeys: []) == MCPApprovalTicket(id: keyless.id, code: nil, reused: true))
        #expect(store.verifyCode(id: minted.id, typed: code))
    }

    @Test func shownCodesAreBoundedAndKeyedByTheWholeCall() {
        let shown = MCPShownCodes()
        for index in 0..<(MCPShownCodes.capacity + 5) { shown.remember("C\(index)", for: ["id\(index)"]) }
        #expect(shown.code(for: ["id0"]) == nil)
        #expect(shown.code(for: ["id\(MCPShownCodes.capacity + 4)"]) == "C\(MCPShownCodes.capacity + 4)")
        let fresh = shown.show(MCPApprovalTicket(id: "a", code: "AAAAA-BBBBB"), key: ["a", "gh"])
        #expect(fresh.code == "AAAAA-BBBBB")
        #expect(shown.show(MCPApprovalTicket(id: "a", reused: true), key: ["a", "gh"]).code == "AAAAA-BBBBB")
        #expect(shown.show(MCPApprovalTicket(id: "a", reused: true), key: ["a", "gl"]).code == nil)
        // A new request (not reused) with no code never borrows a shown one.
        #expect(shown.show(MCPApprovalTicket(id: "a"), key: ["a", "gh"]).code == nil)
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
