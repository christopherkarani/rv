import Foundation
import Testing
@testable import RVMCP

/// A remote server gets at most `maximumRemoteCallsInFlight` calls at once:
/// past it a call is refused unsent, and nothing in flight is touched.
@Suite("MCPGatewayCore remote calls in flight")
struct MCPGatewayRemoteCallCapTests {
    static let remote = MCPServerDefinition(
        name: "remote", remote: MCPRemoteServer(url: URL(string: "https://mcp.example/mcp")!),
        tools: MCPToolPolicy(allow: ["*"]))
    static let local = MCPServerDefinition(name: "local", command: "local-mcp", tools: MCPToolPolicy(allow: ["*"]))

    static func call(_ id: Int) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"echo","arguments":{}}}"#
    }

    @Test func aRemoteTakesAtMostItsCapOfCallsAndAFinishedOneFreesAPlace() throws {
        let cap = MCPGatewayCore.maximumRemoteCallsInFlight
        #expect(cap == 64)
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.remote]))
        _ = harness.ready()
        var forwarded: [Int] = []
        for id in 1...cap {
            let sent = harness.client(Self.call(id)).sent("tools/call")
            #expect(sent.count == 1, "call \(id) was not sent")
            forwarded.append(sent.first?["id"]?.intValue ?? -1)
        }
        let over = harness.client(Self.call(cap + 1))
        #expect(over.toUpstream.isEmpty, "a call past the cap was sent")
        #expect(over.audits.map(\.outcome) == [.notRun])
        #expect(over.toClient.count == 1)
        let message = over.toClient.first?["error"]?["message"]?.stringValue ?? ""
        #expect(over.toClient.first?["id"] == .int(cap + 1))
        #expect(message.contains("already has 64 calls in flight"), "\(message)")
        // One answered: one more goes out, and the next is refused again.
        let first = try #require(forwarded.first)
        let answered = harness.upstream("remote", #"{"jsonrpc":"2.0","id":\#(first),"result":{"content":[]}}"#)
        #expect(answered.toClient.contains { $0["id"] == .int(1) })
        #expect(harness.client(Self.call(cap + 2)).sent("tools/call").count == 1)
        #expect(harness.client(Self.call(cap + 3)).toUpstream.isEmpty)
    }

    @Test func aLocalServerHasNoSuchCap() {
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.local]))
        _ = harness.ready()
        for id in 1...(MCPGatewayCore.maximumRemoteCallsInFlight + 1) {
            #expect(harness.client(Self.call(id)).sent("tools/call").count == 1, "call \(id) was not sent")
        }
    }
}
