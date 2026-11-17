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

    static func harness(_ clock: ManualClock, callTimeout: Int = 300) -> GatewayHarness {
        var remote = MCPServerDefinition(
            name: "remote", remote: MCPRemoteServer(url: URL(string: "https://mcp.example/mcp")!),
            tools: MCPToolPolicy(allow: ["*"], ask: ["ask_*"]))
        remote.callTimeoutSeconds = callTimeout
        return GatewayHarness(MCPConfiguration(servers: [remote]), clock: { clock.now })
    }

    /// Sends calls `ids` and expects each forwarded; their upstream ids.
    static func fill(_ harness: inout GatewayHarness, _ ids: ClosedRange<Int>) -> [Int] {
        ids.map { id in
            let sent = harness.client(Self.call(id)).sent("tools/call")
            #expect(sent.count == 1, "call \(id) was not sent")
            return sent.first?["id"]?.intValue ?? -1
        }
    }

    static let elicits = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"elicitation":{}}}}"#
    static let askCall = #"{"jsonrpc":"2.0","id":"p","method":"tools/call","params":{"name":"ask_thing","arguments":{}}}"#

    /// A prompt the user accepts once the remote is full is refused like a
    /// direct call: not sent, and its prompt's row ends declined.
    @Test func aPromptAcceptedAtTheCapIsRefusedAndDeclined() throws {
        let clock = ManualClock()
        var harness = Self.harness(clock)
        _ = harness.client(Self.elicits)
        _ = harness.ready()
        let key = try #require(harness.client(Self.askCall).toClient.first?["id"]?.stringValue)
        _ = Self.fill(&harness, 1...MCPGatewayCore.maximumRemoteCallsInFlight)
        let accepted = harness.client(MCPGatewayElicitationTests.answer(key, #"{"action":"accept","content":{"approve":true}}"#))
        #expect(accepted.toUpstream.isEmpty, "an accepted prompt past the cap was sent")
        #expect(accepted.audits.map(\.outcome) == [.declined(approvalID: key)])
        #expect(accepted.audits.first?.reason?.contains("already in flight") == true)
    }

    /// A call refused at the cap uses no `rv mcp approve` grant: it is
    /// still there for the call once there is room.
    @Test func aCallRefusedAtTheCapLeavesItsGrant() throws {
        let clock = ManualClock()
        var harness = Self.harness(clock)
        _ = harness.ready()
        let forwarded = Self.fill(&harness, 1...MCPGatewayCore.maximumRemoteCallsInFlight)
        let grant = "remote/ask_thing/\(JSONValue.object([:]).canonicalHash)"
        _ = harness.approvals.granted.withLock { $0.insert(grant) }
        #expect(harness.client(Self.askCall).toUpstream.isEmpty)
        #expect(harness.approvals.granted.withLock { $0.contains(grant) }, "the refused call used the grant")
        let first = try #require(forwarded.first)
        _ = harness.upstream("remote", #"{"jsonrpc":"2.0","id":\#(first),"result":{"content":[]}}"#)
        #expect(harness.client(Self.askCall).sent("tools/call").count == 1)
        #expect(harness.approvals.granted.withLock { $0.contains(grant) } == false)
    }

    /// A client's cancel, a call's timeout and the server going away each
    /// free places; after a restart the count starts again from nothing.
    @Test func aCancelATimeoutAnExitAndARestartEachFreePlaces() throws {
        let clock = ManualClock()
        let cap = MCPGatewayCore.maximumRemoteCallsInFlight
        var harness = Self.harness(clock, callTimeout: 10)
        _ = harness.ready()
        _ = Self.fill(&harness, 1...cap)
        #expect(harness.client(Self.call(1000)).toUpstream.isEmpty)
        // A cancel frees its place.
        _ = harness.client(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#)
        _ = Self.fill(&harness, 1001...1001)
        #expect(harness.client(Self.call(1002)).toUpstream.isEmpty)
        // A timeout frees them: every call still waiting runs out.
        clock.advance(10)
        _ = harness.core.handle(.tick)
        _ = Self.fill(&harness, 2001...(2000 + cap))
        #expect(harness.client(Self.call(3000)).toUpstream.isEmpty)
        // The server goes away: nothing of it is in flight, and once it is
        // back (relaunched, initialized and listed) it takes a full cap.
        _ = harness.core.handle(.upstreamExited(server: "remote"))
        clock.advance(1)
        let due = harness.core.handle(.tick)
        #expect(due.restarted == ["remote"])
        guard case .restarting(_, .launching(let launch, _))? = harness.core.phases["remote"] else {
            Issue.record("not relaunching: \(String(describing: harness.core.phases["remote"]))")
            return
        }
        let initialize = harness.core.handle(.upstreamRelaunched(server: "remote", launch: launch)).sent("initialize")
        let initializeID = try #require(initialize.first?["id"])
        let listing = harness.core.handle(.upstream(server: "remote", message: MCPGatewayDeadlineTests.answer(initializeID)))
        let listID = try #require(listing.sent("tools/list").first?["id"]?.intValue)
        _ = harness.upstream(
            "remote", #"{"jsonrpc":"2.0","id":\#(listID),"result":{"tools":[{"name":"echo","inputSchema":{"type":"object"}}]}}"#)
        #expect(harness.core.phases["remote"] == .ready)
        _ = Self.fill(&harness, 4001...(4000 + cap))
        #expect(harness.client(Self.call(5000)).toUpstream.isEmpty)
    }

    @Test func aLocalServerHasNoSuchCap() {
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.local]))
        _ = harness.ready()
        for id in 1...(MCPGatewayCore.maximumRemoteCallsInFlight + 1) {
            #expect(harness.client(Self.call(id)).sent("tools/call").count == 1, "call \(id) was not sent")
        }
    }
}
