import Foundation
import Testing
import RVIsolation
@testable import RVMCP
@testable import RVMCPCustodianCore

@Suite("MCP custodian request handler")
struct CustodianRequestHandlerTests {
    static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rv-custodian-handler-\(UUID().uuidString)")
    }

    /// Fake key store: the file adapter stands in for the keychain, so no
    /// test touches a live keychain.
    static func handler(directory: URL) -> CustodianRequestHandler {
        CustodianRequestHandler(
            service: MCPCustodianKeyService(signing: .file(configDirectory: directory)))
    }

    static func helloData() throws -> Data {
        try JSONEncoder().encode(MCPCustodianHello())
    }

    static func requestData(_ request: MCPCustodianRequest) throws -> Data {
        try JSONEncoder().encode(request)
    }

    static func ack(_ reply: CustodianIncomingReply) throws -> MCPCustodianHelloAck {
        try JSONDecoder().decode(MCPCustodianHelloAck.self, from: reply.frame)
    }

    static func response(_ reply: CustodianIncomingReply) throws -> MCPCustodianResponse {
        try JSONDecoder().decode(MCPCustodianResponse.self, from: reply.frame)
    }

    @Test func discoveryAnswersHelloOnlyWithEndpoint() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handler = Self.handler(directory: directory)

        let hello = handler.handleIncoming(
            try Self.helloData(), peerRole: .cli, handshakeOK: false, discoveryOnly: true)
        #expect(try Self.ack(hello).ok)
        #expect(hello.handshakeAccepted)
        #expect(hello.includeEndpoint)

        let action = handler.handleIncoming(
            try Self.requestData(.status), peerRole: .cli, handshakeOK: true, discoveryOnly: true)
        #expect(try Self.response(action) == .error(.unauthorized))
        #expect(action.includeEndpoint == false)
    }

    @Test func nonCLIPeersAreDeniedEveryOperation() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handler = Self.handler(directory: directory)

        for role in [TrustedRVComponentRole.service, .workspaceHost, .operatorUI, .mcpCustodian, nil] {
            let hello = handler.handleIncoming(
                try Self.helloData(), peerRole: role, handshakeOK: false, discoveryOnly: false)
            #expect(try Self.ack(hello).ok == false)
            #expect(hello.handshakeAccepted == false)

            for request in [
                MCPCustodianRequest.status,
                .mac(purpose: "grant", fields: ["a"], createIfMissing: true),
                .verify(candidate: "00", purpose: "grant", fields: ["a"]),
            ] {
                let reply = handler.handleIncoming(
                    try Self.requestData(request), peerRole: role, handshakeOK: true, discoveryOnly: false)
                #expect(try Self.response(reply) == .error(.unauthorized))
            }
        }
        // Denied mac(createIfMissing:) must not have enrolled a key.
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(MCPApprovalKeyIdentity.fileName).path) == false)
    }

    @Test func requestsBeforeHandshakeAreDenied() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handler = Self.handler(directory: directory)
        let reply = handler.handleIncoming(
            try Self.requestData(.status), peerRole: .cli, handshakeOK: false, discoveryOnly: false)
        #expect(try Self.response(reply) == .error(.unauthorized))
    }

    @Test func wrongProtocolHelloIsRefused() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handler = Self.handler(directory: directory)
        let data = try JSONEncoder().encode(MCPCustodianHello(protocolVersion: "rv.mcp-custodian.v0"))
        let reply = handler.handleIncoming(data, peerRole: .cli, handshakeOK: false, discoveryOnly: true)
        #expect(try Self.ack(reply).ok == false)
        #expect(reply.handshakeAccepted == false)
        #expect(reply.includeEndpoint == false)
    }

    @Test func cliPeerGetsMacAndVerifyFromTheFakeStore() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handler = Self.handler(directory: directory)

        let statusReply = handler.handleIncoming(
            try Self.requestData(.status), peerRole: .cli, handshakeOK: true, discoveryOnly: false)
        #expect(try Self.response(statusReply) == .status(.notEnrolled))

        let macReply = handler.handleIncoming(
            try Self.requestData(.mac(purpose: "grant", fields: ["a", "b"], createIfMissing: true)),
            peerRole: .cli, handshakeOK: true, discoveryOnly: false)
        guard case .mac(let value) = try Self.response(macReply), let mac = value else {
            Issue.record("expected a MAC, got \(try Self.response(macReply))")
            return
        }
        #expect(mac.count == 64)

        let verifyReply = handler.handleIncoming(
            try Self.requestData(.verify(candidate: mac, purpose: "grant", fields: ["a", "b"])),
            peerRole: .cli, handshakeOK: true, discoveryOnly: false)
        #expect(try Self.response(verifyReply) == .verify(true))

        let forgedReply = handler.handleIncoming(
            try Self.requestData(.verify(candidate: String(repeating: "0", count: 64), purpose: "grant", fields: ["a", "b"])),
            peerRole: .cli, handshakeOK: true, discoveryOnly: false)
        #expect(try Self.response(forgedReply) == .verify(false))
    }

    @Test func custodianInternalPurposeAndGarbageAreBadRequests() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handler = Self.handler(directory: directory)

        let enrollment = handler.handleIncoming(
            try Self.requestData(.mac(purpose: "enrollment", fields: ["check"], createIfMissing: true)),
            peerRole: .cli, handshakeOK: true, discoveryOnly: false)
        #expect(try Self.response(enrollment) == .error(.badRequest))

        let garbage = handler.handleIncoming(
            Data("not json".utf8), peerRole: .cli, handshakeOK: true, discoveryOnly: false)
        #expect(try Self.response(garbage) == .error(.badRequest))
    }

    @Test func launchParsingMirrorsRVD() throws {
        let plain = try CustodianLaunch.parse(arguments: ["rv-mcp-custodian"])
        #expect(plain.idleExitSeconds == CustodianIdleWatchdog.defaultSeconds)
        #expect(plain.printVersion == false)
        let version = try CustodianLaunch.parse(arguments: ["rv-mcp-custodian", "--version"])
        #expect(version.printVersion)
        let idle = try CustodianLaunch.parse(arguments: ["rv-mcp-custodian", "--idle-exit-seconds=42"])
        #expect(idle.idleExitSeconds == 42)
        #expect(throws: CustodianLaunchError.invalidIdleExit) {
            try CustodianLaunch.parse(arguments: ["rv-mcp-custodian", "--idle-exit-seconds", "0"])
        }
    }
}
