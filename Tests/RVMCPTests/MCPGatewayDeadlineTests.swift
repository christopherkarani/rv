import Foundation
import Synchronization
import Testing
@testable import RVMCP

/// A clock the test moves by hand.
final class ManualClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    var now: Date { current.withLock { $0 } }

    func advance(_ seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

@Suite("MCPGatewayCore deadlines")
struct MCPGatewayDeadlineTests {
    static func github(callTimeout: Int = MCPServerDefinition.defaultCallTimeoutSeconds) -> MCPServerDefinition {
        var definition = MCPGatewayCoreTests.github
        definition.callTimeoutSeconds = callTimeout
        return definition
    }

    static func harness(
        _ servers: [MCPServerDefinition], clock: ManualClock, elicits: Bool = false
    ) -> GatewayHarness {
        var harness = GatewayHarness(MCPConfiguration(servers: servers), clock: { clock.now })
        if elicits {
            _ = harness.client(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"elicitation":{}}}}"#)
        }
        return harness
    }

    static func answer(_ id: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": .object([:])])
    }

    // MARK: tools/call

    @Test func callNotAnsweredInTimeFailsTheClientAuditsAndCancelsUpstream() throws {
        let clock = ManualClock()
        var harness = Self.harness([Self.github(callTimeout: 10)], clock: clock)
        _ = harness.ready()
        let call = harness.client(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_issues","arguments":{"query":"hunter2-arg"}}}"#)
        let id = try #require(call.toUpstream.first?.1["id"]?.intValue)

        clock.advance(9)
        #expect(harness.core.handle(.tick).isEmpty)
        clock.advance(2)
        let expired = harness.core.handle(.tick)

        let record = try #require(expired.audits.first)
        #expect(expired.audits.count == 1)
        #expect(record.outcome == .interrupted(grant: nil))
        #expect(record.isError)
        #expect(record.reason?.contains("timed out") == true)
        #expect(record.argumentKeys == ["query"])
        // Cancelled upstream; never sent again.
        #expect(expired.toUpstream.count == 1)
        #expect(expired.toUpstream.first?.0 == "github")
        #expect(expired.toUpstream.first?.1["method"] == .string("notifications/cancelled"))
        #expect(expired.toUpstream.first?.1["params"]?["requestId"] == .int(id))
        let reply = try #require(expired.toClient.first)
        #expect(expired.toClient.count == 1)
        #expect(reply["id"] == .int(5))
        #expect(reply["error"]?["code"] == .int(-32603))
        let message = try #require(reply["error"]?["message"]?.stringValue)
        #expect(message.contains("github") && message.contains("list_issues") && message.contains("10 s"))
        #expect(message.contains("hunter2-arg") == false)

        // A late answer is dropped: the client already has its error.
        let late = harness.upstream("github", #"{"jsonrpc":"2.0","id":\#(id),"result":{"content":[]}}"#)
        #expect(late.isEmpty)
        clock.advance(1000)
        #expect(harness.core.handle(.tick).isEmpty)
    }

    @Test func callDeadlineFollowsEachServersSetting() throws {
        let clock = ManualClock()
        let notes = {
            var definition = MCPGatewayCoreTests.notes
            definition.callTimeoutSeconds = 100
            return definition
        }()
        var harness = Self.harness([Self.github(), notes], clock: clock)
        _ = harness.ready()
        _ = harness.client(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"github__list_issues"}}"#)
        _ = harness.client(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"notes__write"}}"#)
        clock.advance(101)
        let first = harness.core.handle(.tick)
        #expect(first.toClient.map { $0["id"] } == [.int(2)])
        clock.advance(Double(MCPServerDefinition.defaultCallTimeoutSeconds) - 101 + 1)
        let second = harness.core.handle(.tick)
        #expect(second.toClient.map { $0["id"] } == [.int(1)])
        #expect(second.toClient.first?["error"]?["message"]?.stringValue?.contains("300 s") == true)
    }

    @Test func anyInputRunsTheDeadlineCheck() throws {
        let clock = ManualClock()
        var harness = Self.harness([Self.github(callTimeout: 10)], clock: clock)
        _ = harness.ready()
        _ = harness.client(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_issues"}}"#)
        clock.advance(11)
        let ping = harness.client(#"{"jsonrpc":"2.0","id":6,"method":"ping"}"#)
        #expect(ping.toClient.map { $0["id"] } == [.int(5), .int(6)])
    }

    @Test func validProgressResetsTheCallDeadline() throws {
        let clock = ManualClock()
        var harness = Self.harness([Self.github(callTimeout: 10)], clock: clock)
        _ = harness.ready()
        _ = harness.client(#"{"jsonrpc":"2.0","id":"c","method":"tools/call","params":{"name":"list_issues","arguments":{},"_meta":{"progressToken":7}}}"#)
        func progress(_ params: String) -> [MCPGatewayOutput] {
            harness.upstream("github", #"{"jsonrpc":"2.0","method":"notifications/progress","params":\#(params)}"#)
        }
        clock.advance(8)
        #expect(progress(#"{"progressToken":7,"progress":1}"#).toClient.count == 1)
        clock.advance(8)
        #expect(harness.core.handle(.tick).isEmpty)
        // Progress the gateway drops (another token, a non-finite number)
        // does not keep the call alive.
        #expect(progress(#"{"progressToken":8,"progress":2}"#).isEmpty)
        #expect(progress(#"{"progressToken":7,"progress":"x"}"#).isEmpty)
        clock.advance(3)
        let expired = harness.core.handle(.tick)
        #expect(expired.toClient.first?["id"] == .string("c"))
        #expect(expired.toClient.first?["error"]?["code"] == .int(-32603))
        // Its token is gone with it.
        #expect(progress(#"{"progressToken":7,"progress":3}"#).isEmpty)
    }

    @Test func progressFromAnotherServerDoesNotResetTheDeadline() throws {
        let clock = ManualClock()
        var harness = Self.harness([Self.github(callTimeout: 10), MCPGatewayCoreTests.notes], clock: clock)
        _ = harness.ready()
        _ = harness.client(#"{"jsonrpc":"2.0","id":"c","method":"tools/call","params":{"name":"github__list_issues","arguments":{},"_meta":{"progressToken":7}}}"#)
        clock.advance(8)
        #expect(harness.upstream("notes", #"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":7,"progress":1}}"#).isEmpty)
        clock.advance(3)
        #expect(harness.core.handle(.tick).toClient.first?["id"] == .string("c"))
    }

    @Test func grantedCallThatTimesOutKeepsItsGrantInTheRecord() throws {
        let clock = ManualClock()
        var harness = Self.harness([Self.github(callTimeout: 10)], clock: clock)
        _ = harness.ready()
        let hash = JSONValue.object([:]).canonicalHash
        harness.approvals.granted.withLock { $0.insert("github/create_issue/\(hash)") }
        let call = harness.client(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"create_issue","arguments":{}}}"#)
        #expect(call.toUpstream.count == 1)
        clock.advance(11)
        let record = try #require(harness.core.handle(.tick).audits.first)
        #expect(record.decision == .ask)
        #expect(record.outcome == .interrupted(grant: MCPCallRecord.Grant(approvalID: "grant1", channel: .local)))
    }

    @Test func cancelledCallIsForgottenAfterTheCallDeadline() throws {
        let clock = ManualClock()
        var harness = Self.harness([Self.github(callTimeout: 10)], clock: clock)
        _ = harness.ready()
        let call = harness.client(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_issues"}}"#)
        let id = try #require(call.toUpstream.first?.1["id"]?.intValue)
        _ = harness.client(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5}}"#)
        #expect(harness.core.pending.count == 1)
        clock.advance(9)
        #expect(harness.core.handle(.tick).isEmpty)
        #expect(harness.core.pending.count == 1)
        clock.advance(2)
        #expect(harness.core.handle(.tick).isEmpty)
        #expect(harness.core.pending.isEmpty)
        #expect(harness.upstream("github", #"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#).isEmpty)
    }

    @Test func timedOutCallIsForgottenAfterAnotherCallDeadline() throws {
        let clock = ManualClock()
        var harness = Self.harness([Self.github(callTimeout: 10)], clock: clock)
        _ = harness.ready()
        _ = harness.client(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_issues"}}"#)
        clock.advance(11)
        _ = harness.core.handle(.tick)
        #expect(harness.core.pending.count == 1)
        clock.advance(11)
        #expect(harness.core.handle(.tick).isEmpty)
        #expect(harness.core.pending.isEmpty)
    }

    @Test func exitForgetsTheServersCancelledCalls() throws {
        let clock = ManualClock()
        var harness = Self.harness([Self.github(), MCPGatewayCoreTests.notes], clock: clock)
        _ = harness.ready()
        _ = harness.client(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"github__list_issues"}}"#)
        _ = harness.client(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"notes__write"}}"#)
        _ = harness.client(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#)
        _ = harness.client(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}"#)
        #expect(harness.core.pending.count == 2)
        #expect(harness.core.handle(.upstreamExited(server: "github")).toClient.isEmpty)
        #expect(harness.core.pending.count == 1)
    }

    // MARK: initialize

    @Test func initializeNotAnsweredInTimeFailsTheServerStopsItAndReleasesWaiting() throws {
        let clock = ManualClock()
        var harness = Self.harness([Self.github(), MCPGatewayCoreTests.notes], clock: clock)
        let started = harness.core.start().toUpstream
        let githubInit = try #require(started.first { $0.0 == "github" }?.1["id"])
        _ = harness.core.handle(.upstream(server: "github", message: Self.answer(githubInit)))
        #expect(harness.client(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#).isEmpty)

        clock.advance(MCPGatewayDeadlines.standardStart - 1)
        #expect(harness.core.handle(.tick).isEmpty)
        clock.advance(2)
        let expired = harness.core.handle(.tick)
        #expect(expired.stopped == ["notes"])
        #expect(expired.logs.contains { $0.contains("notes") && $0.contains("initialize") && $0.contains("30 s") })
        // The waiting listing goes out to the server that is ready.
        #expect(expired.toUpstream.map(\.0) == ["github"])
        #expect(expired.toUpstream.first?.1["method"] == .string("tools/list"))

        let call = harness.client(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"notes__write"}}"#)
        let message = call.toClient.first?["error"]?["message"]?.stringValue ?? ""
        #expect(message.contains("unavailable") && message.contains("initialize"))
        // The exit that follows the stop keeps the reason.
        _ = harness.core.handle(.upstreamExited(server: "notes"))
        let after = harness.client(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"notes__write"}}"#)
        #expect(after.toClient.first?["error"]?["message"]?.stringValue?.contains("initialize") == true)
        // A late answer to the expired initialize does not make it ready.
        let notesInit = try #require(started.first { $0.0 == "notes" }?.1["id"])
        let late = harness.core.handle(.upstream(server: "notes", message: Self.answer(notesInit)))
        #expect(late.toUpstream.isEmpty)
        #expect(harness.core.phases["notes"] != .ready)
    }

    @Test func initializeDeadlineIsInjectable() throws {
        let clock = ManualClock()
        var harness = GatewayHarness(
            MCPConfiguration(servers: [Self.github()]), clock: { clock.now },
            deadlines: MCPGatewayDeadlines(start: 2, list: 3))
        _ = harness.core.start()
        clock.advance(3)
        #expect(harness.core.handle(.tick).stopped == ["github"])
    }

    // MARK: tools/list

    @Test func listNotAnsweredInTimeCompletesWithoutThatServer() throws {
        let clock = ManualClock()
        var harness = Self.harness([Self.github(), MCPGatewayCoreTests.notes], clock: clock)
        _ = harness.ready()
        let fanout = harness.client(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#).toUpstream
        let githubID = try #require(fanout.first { $0.0 == "github" }?.1["id"]?.intValue)
        let notesID = try #require(fanout.first { $0.0 == "notes" }?.1["id"]?.intValue)
        #expect(harness.upstream("github", #"{"jsonrpc":"2.0","id":\#(githubID),"result":{"tools":[{"name":"list_issues"}]}}"#).toClient.isEmpty)

        clock.advance(MCPGatewayDeadlines.standardList - 1)
        #expect(harness.core.handle(.tick).isEmpty)
        clock.advance(2)
        let expired = harness.core.handle(.tick)
        let names = expired.toClient.first?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(names == ["github__list_issues"])
        #expect(expired.logs.contains { $0.contains("notes") && $0.contains("did not list tools") })
        #expect(expired.stopped.isEmpty)
        #expect(harness.upstream("notes", #"{"jsonrpc":"2.0","id":\#(notesID),"result":{"tools":[{"name":"write"}]}}"#).isEmpty)

        // The server stays ready: its calls still go upstream.
        #expect(harness.core.phases["notes"] == .ready)
        let call = harness.client(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"notes__write"}}"#)
        #expect(call.toUpstream.first?.0 == "notes")
    }

    @Test func listDeadlineCoversEveryPage() throws {
        let clock = ManualClock()
        var harness = Self.harness([Self.github()], clock: clock)
        _ = harness.ready()
        let first = harness.client(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#).toUpstream
        let firstID = try #require(first.first?.1["id"]?.intValue)
        clock.advance(20)
        let page = harness.upstream("github", #"{"jsonrpc":"2.0","id":\#(firstID),"result":{"tools":[{"name":"list_issues"}],"nextCursor":"p2"}}"#)
        #expect(page.toUpstream.count == 1)
        clock.advance(MCPGatewayDeadlines.standardList + 1)
        let expired = harness.core.handle(.tick)
        let names = expired.toClient.first?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(names == ["list_issues"])
    }

    // MARK: held approvals

    @Test func heldApprovalExpiresOnATickWithNoOtherInput() throws {
        let clock = ManualClock()
        var harness = Self.harness([Self.github()], clock: clock, elicits: true)
        _ = harness.ready()
        let prompt = harness.client(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"create_issue","arguments":{}}}"#)
        #expect(prompt.toClient.first?["method"] == .string("elicitation/create"))
        clock.advance(MCPGatewayCore.heldLifetime + 1)
        let expired = harness.core.handle(.tick)
        #expect(expired.audits.first?.declined == true)
        #expect(expired.toClient.contains { $0["id"] == .int(5) })
    }
}
