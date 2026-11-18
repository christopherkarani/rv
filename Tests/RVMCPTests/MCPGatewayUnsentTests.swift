import Foundation
import Testing
@testable import RVMCP

/// `.upstreamUnsent`: a request the runtime did not post because its remote
/// had its most requests in flight. Each kind ends once, as the docs say.
@Suite("MCPGatewayCore requests not sent")
struct MCPGatewayUnsentTests {
    typealias Cap = MCPGatewayRemoteCallCapTests

    static func unsent(_ harness: inout GatewayHarness, _ id: Int, server: String = "remote") -> [MCPGatewayOutput] {
        harness.core.handle(.upstreamUnsent(server: server, id: .int(id)))
    }

    static func forwarded(_ outputs: [MCPGatewayOutput]) throws -> Int {
        try #require(outputs.sent("tools/call").first?["id"]?.intValue)
    }

    @Test func aPlainCallEndsNotRunOnceAndSaysSo() throws {
        let clock = ManualClock()
        var harness = Cap.harness(clock)
        _ = harness.ready()
        let id = try Self.forwarded(harness.client(Cap.call(1)))
        let ended = Self.unsent(&harness, id)
        #expect(ended.audits.map(\.outcome) == [.notRun])
        #expect(ended.audits.first?.decision == .allow)
        #expect(ended.toClient.count == 1)
        #expect(ended.toClient.first?["id"] == .int(1))
        #expect(ended.toClient.first?["error"]?["message"]?.stringValue?.contains("was not run") == true)
        // A second report for it finds nothing.
        #expect(Self.unsent(&harness, id).isEmpty)
    }

    /// An approved call that could not be sent keeps its approval id on its
    /// last row, and the client is told the approval was used up.
    @Test func anApprovedCallEndsDeclinedWithItsApprovalUsedUp() throws {
        let clock = ManualClock()
        var harness = Cap.harness(clock)
        _ = harness.ready()
        let grant = "remote/ask_thing/\(JSONValue.object([:]).canonicalHash)"
        _ = harness.approvals.granted.withLock { $0.insert(grant) }
        let id = try Self.forwarded(harness.client(Cap.askCall))
        let ended = Self.unsent(&harness, id)
        #expect(ended.audits.map(\.outcome) == [.declined(approvalID: "grant1")])
        let message = ended.toClient.first?["error"]?["message"]?.stringValue ?? ""
        #expect(message.contains("was not run") && message.contains("approval"), "\(message)")
    }

    @Test func anAcceptedPromptsCallEndsDeclinedWithItsApprovalUsedUp() throws {
        let clock = ManualClock()
        var harness = Cap.harness(clock)
        _ = harness.client(Cap.elicits)
        _ = harness.ready()
        let key = try #require(harness.client(Cap.askCall).toClient.first?["id"]?.stringValue)
        let id = try Self.forwarded(
            harness.client(MCPGatewayElicitationTests.answer(key, #"{"action":"accept","content":{"approve":true}}"#)))
        let ended = Self.unsent(&harness, id)
        #expect(ended.audits.map(\.outcome) == [.declined(approvalID: key)])
        #expect(Self.unsent(&harness, id).isEmpty)
    }

    /// A listing page not sent fails as an unanswered page: the listing
    /// ends with the pages already returned.
    @Test func aListingPageNotSentEndsTheListingWithWhatItHas() throws {
        let clock = ManualClock()
        var harness = Cap.harness(clock)
        _ = harness.ready()
        let first = try #require(harness.client(#"{"jsonrpc":"2.0","id":"l","method":"tools/list"}"#).sent("tools/list").first?["id"]?.intValue)
        let page = harness.upstream(
            "remote", #"{"jsonrpc":"2.0","id":\#(first),"result":{"tools":[{"name":"echo","inputSchema":{"type":"object"}}],"nextCursor":"p2"}}"#)
        let second = try #require(page.sent("tools/list").first?["id"]?.intValue)
        let ended = Self.unsent(&harness, second)
        let reply = try #require(ended.toClient.first { $0["id"] == .string("l") })
        #expect(reply["result"]?["tools"]?.arrayValue?.count == 1, "\(reply)")
        #expect(ended.logs.contains { $0.contains("too many requests") }, "\(ended.logs)")
        #expect(Self.unsent(&harness, second).isEmpty)
    }

    /// rv's own listing after a restart, not sent: the restart failed, as
    /// any failed relisting does.
    @Test func aRelistingPageNotSentStopsTheServer() throws {
        let clock = ManualClock()
        var harness = Cap.harness(clock)
        _ = harness.ready()
        _ = harness.core.handle(.upstreamExited(server: "remote"))
        clock.advance(1)
        #expect(harness.core.handle(.tick).restarted == ["remote"])
        guard case .restarting(_, .launching(let launch, _))? = harness.core.phases["remote"] else {
            Issue.record("not relaunching")
            return
        }
        let initialize = harness.core.handle(.upstreamRelaunched(server: "remote", launch: launch)).sent("initialize")
        let initializeID = try #require(initialize.first?["id"])
        let listing = harness.core.handle(.upstream(server: "remote", message: MCPGatewayDeadlineTests.answer(initializeID)))
        let listID = try #require(listing.sent("tools/list").first?["id"]?.intValue)
        #expect(Self.unsent(&harness, listID).stopped == ["remote"])
    }

    /// A ping rv could not send says nothing about the server: no hung
    /// verdict, no stop, no restart; its calls keep their own deadlines.
    @Test func aPingNotSentGivesNoVerdict() throws {
        let clock = ManualClock()
        var harness = Cap.harness(clock, callTimeout: 10)
        _ = harness.ready()
        _ = try Self.forwarded(harness.client(Cap.call(1)))
        clock.advance(10)
        let expired = harness.core.handle(.tick)
        let ping = try #require(expired.sent("ping").first?["id"]?.intValue)
        let dropped = Self.unsent(&harness, ping)
        #expect(dropped.stopped.isEmpty)
        #expect(dropped.logs.contains { $0.contains("ping") }, "\(dropped.logs)")
        clock.advance(MCPGatewayCore.pingTimeout)
        let later = harness.core.handle(.tick)
        #expect(later.stopped.isEmpty, "\(later)")
        #expect(harness.core.phases["remote"] == .ready)
        // A later call that times out pings again.
        _ = try Self.forwarded(harness.client(Cap.call(2)))
        clock.advance(10)
        #expect(harness.core.handle(.tick).sent("ping").count == 1)
    }

    /// A report for a call that already ended (it timed out, or the client
    /// cancelled it) finds nothing: no second record, no second answer.
    @Test func aReportAfterTheCallEndedFindsNothing() throws {
        let clock = ManualClock()
        var harness = Cap.harness(clock, callTimeout: 10)
        _ = harness.ready()
        let timedOut = try Self.forwarded(harness.client(Cap.call(1)))
        clock.advance(10)
        #expect(harness.core.handle(.tick).audits.count == 1)
        #expect(Self.unsent(&harness, timedOut).isEmpty)
        let cancelled = try Self.forwarded(harness.client(Cap.call(2)))
        _ = harness.client(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}"#)
        #expect(Self.unsent(&harness, cancelled).isEmpty)
    }

    /// A report naming another server does not end this server's call.
    @Test func aReportForAnotherServerEndsNothing() throws {
        let clock = ManualClock()
        var harness = Cap.harness(clock)
        _ = harness.ready()
        let id = try Self.forwarded(harness.client(Cap.call(1)))
        #expect(Self.unsent(&harness, id, server: "other").isEmpty)
        let answered = harness.upstream("remote", #"{"jsonrpc":"2.0","id":\#(id),"result":{"content":[]}}"#)
        #expect(answered.toClient.contains { $0["id"] == .int(1) })
    }
}
