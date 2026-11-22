#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation
import RVPolicy
import Testing
@testable import RVMCP

@Suite("rv mcp serve refuses inside the MCP protocol")
struct MCPServeRefusalTests {
    private let untrusted = MCPServeRefusal(
        servers: ["wax"], cause: .untrusted,
        log: "mcp.json was edited outside rv (no rv signature); review it, then run `rv mcp trust`; not launching MCP servers")

    @Test func agentHearsWhatIsOffThatNothingRanAndTheFix() {
        #expect(untrusted.agentMessage == "✕ wax is off · mcp.json is untrusted · nothing ran\n→ ask your user: rv mcp trust")
        let gateway = MCPServeRefusal(servers: [], cause: .configurationUnusable, log: "x")
        #expect(gateway.agentMessage == "✕ rv's MCP gateway is off · rv can't use its MCP setup · nothing ran\n→ ask your user: rv mcp check")
        let many = MCPServeRefusal(servers: ["a", "b", "c", "d", "e"], cause: .trustUnavailable, log: "x")
        #expect(many.agentMessage.hasPrefix("✕ a, b, c +2 more are off · "))
        #expect(many.next == "sudo rv mcp custodian install")
    }

    @Test func initializeGetsTheRefusalAsAJSONRPCError() throws {
        let line = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#.utf8)
        let answer = try #require(untrusted.answer(line))
        #expect(answer["id"] == .int(1))
        #expect(answer["result"] == nil)
        #expect(answer["error"]?["code"] == .int(MCPServeRefusal.errorCode))
        #expect(answer["error"]?["message"]?.stringValue == untrusted.agentMessage)
        #expect(answer["error"]?["data"]?["rv"]?["state"]?.stringValue == "off")
        #expect(answer["error"]?["data"]?["rv"]?["next"]?.stringValue == "rv mcp trust")
        // Every later request too, whatever its id type.
        let list = try #require(untrusted.answer(Data(#"{"jsonrpc":"2.0","id":"x","method":"tools/list"}"#.utf8)))
        #expect(list["id"] == .string("x"))
    }

    @Test func notificationsAndResponsesGetNoAnswerAndGarbageGetsAParseError() throws {
        #expect(untrusted.answer(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) == nil)
        #expect(untrusted.answer(Data(#"{"jsonrpc":"2.0","id":3,"result":{}}"#.utf8)) == nil)
        #expect(untrusted.answer(Data(#"[1,2]"#.utf8)) == nil)
        let garbage = try #require(untrusted.answer(Data("not json".utf8)))
        #expect(garbage["error"]?["code"] == .int(-32700))
        #expect(garbage["id"] == .null)
    }

    /// The agent's channel is the model's context: resolver and sandbox
    /// detail stays in the owner's log.
    @Test func theAgentNeverSeesTheOwnersDetail() {
        let cause = MCPServeRefusal.cause(
            of: .secretUnavailable(server: "wax", secret: "WAX_TOKEN", reason: "provider printed sk-live-123"))
        let refusal = MCPServeRefusal(servers: ["wax"], cause: cause, log: "wax could not read secret WAX_TOKEN: sk-live-123")
        #expect(refusal.agentMessage.contains("WAX_TOKEN"))
        #expect(refusal.agentMessage.contains("sk-live") == false)
        #expect(refusal.errorResponse(id: .int(1)).compactText.contains("sk-live") == false)
        let sandbox = MCPServeRefusal(
            servers: ["wax"], cause: MCPServeRefusal.cause(of: .sandbox("/Users/me/secret-dir cannot be read")), log: "x")
        #expect(sandbox.agentMessage.contains("secret-dir") == false)
        #expect(sandbox.next == "rv mcp check")
    }

    @Test func namesAreEscapedBeforeTheAgentSeesThem() {
        let hostile = MCPServeRefusal(servers: ["wax\u{1B}[2J\u{202E}"], cause: .unknownServer("wax\u{1B}[2J"), log: "x")
        let text = hostile.errorResponse(id: .int(1)).compactText
        #expect(text.contains("\u{1B}") == false)
        #expect(text.contains("\u{202E}") == false)
        #expect(hostile.agentMessage.unicodeScalars.contains { $0 == "\u{1B}" } == false)
    }

    @Test func everyRefusedPlanIsOffAndAnyStartableServerIsNot() {
        let launch = MCPUpstreamLaunch(server: "ok", executable: "/usr/bin/env", arguments: ["true"], environment: [:])
        #expect(MCPServeRefusal.cause(ofPlanned: [.refused(server: "wax", .sandbox("needs a sandbox"))]) == .notSealed)
        #expect(MCPServeRefusal.cause(ofPlanned: [
            .refused(server: "wax", .sandbox("needs a sandbox")), .refused(server: "p", .placeholder(.unsupportedPlatform)),
        ]) == .refusedHere)
        #expect(MCPServeRefusal.cause(ofPlanned: [.refused(server: "wax", .sandbox("x")), .process(launch)]) == nil)
        #expect(MCPServeRefusal.cause(ofPlanned: []) == nil)
    }

    @Test func listJudgesAServerOffExactlyWhenServeWouldRefuseIt() throws {
        let configuration = MCPConfiguration(servers: [
            MCPServerDefinition(name: "bare", command: "b"),
            MCPServerDefinition(name: "open", command: "o", sandbox: MCPSandboxPolicy(network: true)),
            MCPServerDefinition(name: "sealed", command: "c", sandbox: MCPSandboxPolicy(network: false)),
            MCPServerDefinition(name: "web", remote: MCPRemoteServer(url: try #require(URL(string: "https://mcp.example/mcp")))),
        ])
        func cause(_ name: String, _ integrity: MCPIntegrityStatus = .trusted, cage: Bool) -> MCPServeRefusal.Cause? {
            MCPServeRefusal.cause(serving: name, configuration: configuration, integrity: integrity, requireSandbox: cage)
        }
        for name in ["bare", "sealed", "web"] {
            #expect(cause(name, .untrusted("no rv signature"), cage: true) == .untrusted)
            #expect(cause(name, .unsupportedPlatform, cage: false) == .trustUnavailable)
        }
        #expect(cause("bare", cage: true) == .notSealed)
        #expect(cause("open", cage: true) == .notSealed)
        #expect(cause("sealed", cage: true) == nil)
        #expect(cause("web", cage: true) == nil)
        // No cage on this host: a bare server runs uncaged; one that asks
        // for a sandbox is refused.
        #expect(cause("bare", cage: false) == nil)
        #expect(cause("sealed", cage: false) == .notSealed)
        #expect(cause("web", .noConfiguration, cage: false) == nil)

        var managed = configuration
        managed.managed = try ManagedPolicy.decode(Data(#"{"version":1,"mcp":{"requireSandbox":true}}"#.utf8)).get()
        #expect(MCPServeRefusal.cause(serving: "bare", configuration: managed, integrity: .trusted, requireSandbox: false) == .notSealed)

        let untrustedList = MCPServeRefusal(servers: ["bare"], cause: .untrusted, log: "")
        #expect("not governed: " + untrustedList.listReason == "not governed: mcp.json untrusted")
        #expect(MCPEntryStatus.off.isAcceptable == false)
    }

    // MARK: - The stdio responder

    private func pipePair() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        try #require(pipe(&fds) == 0)
        return (fds[0], fds[1])
    }

    private static func send(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    private func readAll(_ fd: Int32) -> [JSONValue] {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            data.append(contentsOf: buffer[0..<n])
        }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { try? JSONValue.parse(String($0)) }
    }

    @Test func responderAnswersEachRequestUntilTheClientCloses() throws {
        let input = try pipePair()
        let output = try pipePair()
        Self.send(input.write, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"# + "\r\n")
        Self.send(input.write, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n\n")
        Self.send(input.write, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        close(input.write)
        let answered = MCPRefusalResponder.serve(untrusted, input: input.read, output: output.write, idleSeconds: 5)
        close(input.read)
        close(output.write)
        let lines = readAll(output.read)
        close(output.read)
        #expect(answered == 2)
        #expect(lines.map { $0["id"] } == [.int(1), .int(2)])
        #expect(lines.allSatisfy { $0["error"]?["message"]?.stringValue == untrusted.agentMessage })
    }

    @Test func responderStopsAfterItsAnswerBudget() throws {
        let input = try pipePair()
        let output = try pipePair()
        let request = #"{"jsonrpc":"2.0","id":7,"method":"ping"}"# + "\n"
        Self.send(input.write, String(repeating: request, count: MCPRefusalResponder.maximumAnswers + 5))
        let answered = MCPRefusalResponder.serve(untrusted, input: input.read, output: output.write, idleSeconds: 5)
        close(input.write)
        close(input.read)
        close(output.write)
        #expect(answered == MCPRefusalResponder.maximumAnswers)
        #expect(readAll(output.read).count == MCPRefusalResponder.maximumAnswers)
        close(output.read)
    }

    @Test func responderGivesUpOnAnIdleClient() throws {
        let input = try pipePair()
        let output = try pipePair()
        let started = Date()
        let answered = MCPRefusalResponder.serve(untrusted, input: input.read, output: output.write, idleSeconds: 1)
        #expect(answered == 0)
        #expect(Date().timeIntervalSince(started) < 10)
        for fd in [input.read, input.write, output.read, output.write] { close(fd) }
    }

    @Test func responderDropsAnOversizedLineWhole() throws {
        let input = try pipePair()
        let output = try pipePair()
        let writer = Thread {
            let huge = #"{"jsonrpc":"2.0","id":9,"method":"x","params":""#
                + String(repeating: "a", count: MCPRefusalResponder.maximumLineBytes + 10) + "\"}\n"
            Self.send(input.write, huge)
            Self.send(input.write, #"{"jsonrpc":"2.0","id":10,"method":"tools/list"}"# + "\n")
            close(input.write)
        }
        writer.start()
        let answered = MCPRefusalResponder.serve(untrusted, input: input.read, output: output.write, idleSeconds: 5)
        close(input.read)
        close(output.write)
        let lines = readAll(output.read)
        close(output.read)
        #expect(answered == 1)
        #expect(lines.map { $0["id"] } == [.int(10)])
    }

    @Test func responderStopsWhenTheClientIsGone() throws {
        let input = try pipePair()
        let output = try pipePair()
        close(output.read)
        // As serve does before it answers; left ignored, as the gateway leaves it.
        signal(SIGPIPE, SIG_IGN)
        Self.send(input.write, #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"# + "\n"
            + #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"# + "\n")
        close(input.write)
        let answered = MCPRefusalResponder.serve(untrusted, input: input.read, output: output.write, idleSeconds: 5)
        close(input.read)
        close(output.write)
        #expect(answered == 0)
    }
}
