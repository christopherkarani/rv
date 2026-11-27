#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import RVMCP

/// E2: one approval code per request, shown where the person is.
@Suite("MCP approval code notices")
struct MCPApprovalCodeNoticeTests {
    @Test func aFreshOrRememberedCodeIsShownWithItsApproval() {
        let line = MCPGatewayCore.codeNotice(
            MCPApprovalTicket(id: "1a2b3c4d", code: "ABCDE-FGHJK"), server: "github", tool: "create_issue")
        #expect(line == "approval 1a2b3c4d for github tool create_issue: confirmation code ABCDE-FGHJK")
        let again = MCPGatewayCore.codeNotice(
            MCPApprovalTicket(id: "1a2b3c4d", code: "ABCDE-FGHJK", reused: true), server: "github", tool: "create_issue")
        #expect(again == line)
    }

    @Test func aRetryThatCannotShowTheCodeSaysTheFirstOneStillWorks() {
        let line = MCPGatewayCore.codeNotice(
            MCPApprovalTicket(id: "1a2b3c4d", reused: true), server: "github", tool: "create_issue")
        #expect(line == "approval 1a2b3c4d for github tool create_issue is still waiting: its confirmation code is the one shown when it first asked (for a new code, run `rv mcp deny 1a2b3c4d` and let the agent retry)")
        #expect(MCPGatewayCore.codeNotice(MCPApprovalTicket(id: "x"), server: "s", tool: "t") == nil)
    }

    /// Through the core with a real store: every retry of the call tells the
    /// person the same code, the agent never sees it, and the code approves.
    @Test func everyRetryThroughTheGatewayShowsTheSameCode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-mcp-code-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MCPApprovalStore(configDirectory: directory, signing: .file(configDirectory: directory))
        let configuration = MCPConfiguration(servers: [MCPGatewayCoreTests.github])
        var core = MCPGatewayCore(
            configuration: configuration,
            upstreams: configuration.servers.map { MCPGatewayCore.Upstream(definition: $0, secretValues: []) },
            approvals: .store(store), pinning: .unenforced)
        for case .toUpstream(let server, let message) in core.start() {
            _ = core.handle(.upstream(server: server, message: .object([
                "jsonrpc": .string("2.0"), "id": message["id"] ?? .null,
                "result": .object(["protocolVersion": .string("2025-06-18"), "capabilities": .object([:])]),
            ])))
        }
        _ = core.handle(.client(try JSONValue.parse(
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#)))
        var notices: [String] = []
        for _ in 0..<3 {
            let outputs = core.handle(.client(try JSONValue.parse(MCPGatewayElicitationTests.createCall)))
            notices += outputs.notices
            #expect(outputs.toClient.first?.compactText.contains("confirmation code") == false)
            #expect(outputs.logs.contains { $0.contains("confirmation code") } == false, "the code went to the log, not the person")
        }
        #expect(notices.count == 3)
        #expect(Set(notices).count == 1, "a retry changed the code: \(notices)")
        #expect(store.pending().count == 1)
        let request = try #require(store.pending().first)
        let code = try #require(notices.first?.components(separatedBy: "confirmation code ").last)
        #expect(store.verifyCode(id: request.id, typed: code))
    }

    @Test func aNoticeIsFramedOnItsOwnLineAndBounded() {
        #expect(MCPPersonTerminal.framed("hi") == Array("\r\n◆ rv  hi\r\n".utf8))
        let long = MCPPersonTerminal.framed(String(repeating: "é", count: 4096))
        #expect(long.count <= MCPPersonTerminal.maximumBytes + 4)
        #expect(String(decoding: long, as: UTF8.self).contains("\u{FFFD}") == false)
    }

    @Test func noTerminalMeansNothingIsWritten() throws {
        #expect(MCPPersonTerminal.post("x", path: "/nonexistent/rv-tty") == false)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rv-not-a-tty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        #expect(MCPPersonTerminal.post("x", path: file.path) == false)
        #expect(try Data(contentsOf: file).isEmpty)
    }

    @Test func aTerminalGetsTheLine() throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        try #require(master >= 0)
        defer { close(master) }
        try #require(grantpt(master) == 0 && unlockpt(master) == 0)
        let name = try #require(ptsname(master).map { String(cString: $0) })
        #expect(MCPPersonTerminal.post("approval 1 for s tool t: confirmation code ABCDE-FGHJK", path: name))
        var buffer = [UInt8](repeating: 0, count: 512)
        var poll = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
        try #require(waitReadable(&poll) == 1)
        let count = buffer.withUnsafeMutableBytes { read(master, $0.baseAddress, $0.count) }
        let text = String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self)
        #expect(text.contains("◆ rv  approval 1 for s tool t: confirmation code ABCDE-FGHJK"))
    }
}

private func waitReadable(_ descriptor: inout pollfd) -> Int32 {
    poll(&descriptor, 1, 2000)
}
