import Foundation
import Testing
@testable import RVMCP

/// What each `.ask` audit site records. `pending` means an approval is awaited
/// right now; a refusal before any grant is `denied`; a granted call is
/// `allowed` even if it then failed.
@Suite("MCPGatewayCore call outcomes")
struct MCPGatewayCoreOutcomeTests {
    static let createCall = MCPGatewayElicitationTests.createCall

    @Test func unrecordableApprovalRequestIsDenied() {
        let approvals = MCPApprovalGate(
            consumeGrant: { _, _, _, _, _ in .none }, request: { _, _, _, _, _ in nil })
        let configuration = MCPConfiguration(servers: [MCPGatewayCoreTests.github])
        var core = MCPGatewayCore(
            configuration: configuration,
            upstreams: [.init(definition: MCPGatewayCoreTests.github, secretValues: [])],
            approvals: approvals, pinning: .unenforced, recordForward: { _ in true }, clock: { Date() })
        for case .toUpstream(_, let message) in core.start() {
            _ = core.handle(.upstream(server: "github", message: .object([
                "jsonrpc": .string("2.0"), "id": message["id"] ?? .null, "result": .object([:]),
            ])))
        }
        let reply = core.handle(.client(try! JSONValue.parse(Self.createCall)))
        let record = reply.audits.first
        #expect(record?.reason == "rv could not record an approval request")
        #expect(record?.auditEvent().decision == .denied)
    }

    @Test func argumentsNotShownIsDenied() {
        var harness = MCPGatewayElicitationTests.harness(elicitation: "{}")
        let filler = String(repeating: "a", count: MCPGatewayCore.maximumElicitationArguments + 100)
        let call = #"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"create_issue","arguments":{"aaa":"\#(filler)"}}}"#
        let record = harness.client(call).audits.first
        #expect(record?.reason == "approval prompt did not include the full arguments")
        #expect(record?.auditEvent().decision == .denied)
    }

    @Test func askCallToAnUnavailableUpstreamWasNeverGrantedSoIsDenied() {
        var harness = GatewayHarness(MCPConfiguration(servers: [MCPGatewayCoreTests.github]))
        let initialize = harness.core.start().toUpstream[0].1
        _ = harness.upstream("github", #"{"jsonrpc":"2.0","id":\#(initialize["id"]?.intValue ?? -1),"error":{"message":"boom"}}"#)
        let record = harness.client(Self.createCall).audits.first
        #expect(record?.reason?.hasPrefix("upstream unavailable") == true)
        #expect(record?.auditEvent().decision == .denied)
    }

    @Test func grantedCallWhoseUpstreamExitsIsAllowed() {
        var harness = MCPGatewayElicitationTests.harness(elicitation: nil)
        let hash = JSONValue.object(["body": .string("b"), "title": .string("t")]).canonicalHash
        _ = harness.approvals.granted.withLock { $0.insert("github/create_issue/\(hash)") }
        let sent = harness.client(Self.createCall)
        #expect(sent.toUpstream.count == 1)
        let record = harness.core.handle(.upstreamExited(server: "github")).audits.first
        #expect(record?.reason == "upstream exited")
        #expect(record?.approvalID == "grant1")
        #expect(record?.auditEvent().decision == .allowed)
    }

    /// A call in flight when the gateway stops ends with one record, saying
    /// it may still have run; a second stop finds nothing.
    @Test func callInFlightWhenTheGatewayStopsIsInterruptedOnce() {
        var harness = MCPGatewayElicitationTests.harness(elicitation: nil)
        let hash = JSONValue.object(["body": .string("b"), "title": .string("t")]).canonicalHash
        _ = harness.approvals.granted.withLock { $0.insert("github/create_issue/\(hash)") }
        #expect(harness.client(Self.createCall).toUpstream.count == 1)
        let records = harness.core.handle(.gatewayStopping).audits
        #expect(records.count == 1)
        #expect(records.first?.reason == "gateway stopped; the call may still have run")
        #expect(records.first?.approvalID == "grant1")
        if case .interrupted? = records.first?.outcome {} else { Issue.record("\(String(describing: records.first))") }
        #expect(harness.core.handle(.gatewayStopping).audits.isEmpty)
    }

    /// A prompt still shown when the gateway stops ends declined, once.
    @Test func heldPromptWhenTheGatewayStopsIsDeclinedOnce() {
        var harness = MCPGatewayElicitationTests.harness(elicitation: "{}")
        #expect(harness.client(Self.createCall).audits.first?.auditEvent().decision == .pending)
        let records = harness.core.handle(.gatewayStopping).audits
        #expect(records.count == 1)
        #expect(records.first?.reason == "gateway stopped")
        #expect(records.first?.auditEvent().decision == .denied)
        #expect(harness.core.handle(.gatewayStopping).audits.isEmpty)
    }

    @Test func heldPromptWhoseUpstreamExitsWasNeverGrantedSoIsDenied() {
        var harness = MCPGatewayElicitationTests.harness(elicitation: "{}")
        #expect(harness.client(Self.createCall).audits.first?.auditEvent().decision == .pending)
        let record = harness.core.handle(.upstreamExited(server: "github")).audits.first
        #expect(record?.reason == "upstream exited")
        #expect(record?.auditEvent().decision == .denied)
    }

    /// Nothing went upstream, so an accepted prompt that finds its server
    /// unavailable ends declined, with its approval id.
    @Test func acceptedPromptThatFindsTheUpstreamUnavailableIsDeclined() {
        let harness = GatewayHarness(MCPConfiguration(servers: [MCPGatewayCoreTests.github]))
        let record = harness.core.unavailable(
            client: .int(1), server: "github", tool: "create_issue", decision: .ask, keys: [],
            approvalID: "rv-approval-1").audits.first
        #expect(record?.outcome == .declined(approvalID: "rv-approval-1"))
        #expect(record?.auditEvent().decision == .denied)
        #expect(record?.auditEvent().detail["approval"] == "rv-approval-1")
    }

    /// A prompt the client cancels ends its `awaiting` row, declined with
    /// its approval id; a late yes runs nothing.
    @Test func heldPromptTheClientCancelsIsDeclinedOnce() throws {
        var harness = MCPGatewayElicitationTests.harness(elicitation: "{}")
        let key = try #require(harness.client(Self.createCall).toClient.first?["id"]?.stringValue)
        let cancelled = harness.client(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":11}}"#)
        #expect(cancelled.audits.count == 1)
        #expect(cancelled.audits.first?.outcome == .declined(approvalID: key))
        #expect(cancelled.audits.first?.reason == "cancelled by client")
        #expect(cancelled.audits.first?.auditEvent().decision == .denied)
        #expect(cancelled.toClient.contains { $0["method"] == .string("notifications/cancelled") })
        let late = harness.client(MCPGatewayElicitationTests.answer(key, #"{"action":"accept","content":{"approve":true}}"#))
        #expect(late.toUpstream.isEmpty)
        #expect(late.audits.isEmpty)
        #expect(harness.core.handle(.gatewayStopping).audits.isEmpty)
    }

    @Test func outOfBandAwaitingIsPending() {
        var harness = MCPGatewayElicitationTests.harness(elicitation: nil)
        let record = harness.client(Self.createCall).audits.first
        #expect(record?.reason == "awaiting approval")
        #expect(record?.auditEvent().decision == .pending)
    }

    @Test func expiredPromptIsDenied() {
        var now = Date(timeIntervalSince1970: 1_000)
        let box = Box(now)
        var core = MCPGatewayCore(
            configuration: MCPConfiguration(servers: [MCPGatewayCoreTests.github]),
            upstreams: [.init(definition: MCPGatewayCoreTests.github, secretValues: [])],
            approvals: FakeApprovals().gate, pinning: .unenforced, recordForward: { _ in true }, clock: { box.value },
            deadlineClock: { box.value })
        for case .toUpstream(_, let message) in core.start() {
            _ = core.handle(.upstream(server: "github", message: .object([
                "jsonrpc": .string("2.0"), "id": message["id"] ?? .null, "result": .object([:]),
            ])))
        }
        _ = core.handle(.client(try! JSONValue.parse(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"elicitation":{}}}}"#)))
        _ = core.handle(.client(try! JSONValue.parse(Self.createCall)))
        now = now.addingTimeInterval(MCPGatewayCore.heldLifetime + 1)
        box.value = now
        let record = core.expireHeld().compactMap { if case .audit(let r) = $0 { r } else { nil } }.first
        #expect(record?.auditEvent().decision == .denied)
    }

    @Test func allowAndDenyPolicyCallsKeepTheirDecision() {
        var harness = GatewayHarness(MCPConfiguration(servers: [MCPGatewayCoreTests.github]))
        _ = harness.ready()
        let denied = harness.client(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"delete_repo","arguments":{}}}"#)
        #expect(denied.audits.first?.auditEvent().decision == .denied)
        let sent = harness.client(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_issues","arguments":{}}}"#)
        #expect(sent.toUpstream.count == 1)
        let exited = harness.core.handle(.upstreamExited(server: "github"))
        #expect(exited.audits.first?.decision == .allow)
        #expect(exited.audits.first?.auditEvent().decision == .allowed)
    }

    @Test func auditDetailBytesAreUnchanged() {
        var harness = MCPGatewayElicitationTests.harness(elicitation: "{}")
        let id = harness.client(Self.createCall).toClient.first?["id"]?.stringValue ?? ""
        let accepted = harness.client(MCPGatewayElicitationTests.answer(id, #"{"action":"accept","content":{"approve":true}}"#))
        let upstreamID = accepted.toUpstream.first?.1["id"]?.intValue ?? -1
        let done = harness.upstream("github", #"{"jsonrpc":"2.0","id":\#(upstreamID),"result":{"content":[]}}"#)
        let event = done.audits.first?.auditEvent(time: Date(timeIntervalSince1970: 0))
        let duration = event?.detail["durationMs"]
        #expect(duration != nil)
        #expect(event?.detail == [
            "server": "github", "tool": "create_issue", "policy": "ask", "argumentKeys": "body,title",
            "isError": "false", "approval": id, "approvedVia": "elicitation", "durationMs": duration ?? "",
        ])
        #expect(event?.subject == "github/create_issue")
        #expect(event?.reason == nil)
        #expect(event?.decision == .allowed)

        var refusal = MCPGatewayElicitationTests.harness(elicitation: "{}")
        let held = refusal.client(Self.createCall).toClient.first?["id"]?.stringValue ?? ""
        let declined = refusal.client(MCPGatewayElicitationTests.answer(held, #"{"action":"decline"}"#))
        let declinedEvent = declined.audits.first?.auditEvent(time: Date(timeIntervalSince1970: 0))
        #expect(declinedEvent?.detail == [
            "server": "github", "tool": "create_issue", "policy": "ask", "argumentKeys": "body,title",
            "isError": "true", "approval": held,
        ])
        #expect(declinedEvent?.reason == "declined by the user")
        #expect(declinedEvent?.decision == .denied)
    }

    /// The base `detail` for the sites whose outcome moved: only `decision` may change.
    @Test func auditDetailBytesAreUnchangedForMovedSites() {
        let base: [String: String] = [
            "server": "github", "tool": "create_issue", "policy": "ask", "argumentKeys": "body,title", "isError": "true",
        ]

        var prompt = MCPGatewayElicitationTests.harness(elicitation: "{}")
        let held = prompt.client(Self.createCall).toClient.first?["id"]?.stringValue ?? ""
        let exited = prompt.core.handle(.upstreamExited(server: "github")).audits.first?.auditEvent()
        #expect(exited?.detail == base.merging(["approval": held]) { $1 })
        #expect(exited?.decision == .denied)

        var outOfBand = MCPGatewayElicitationTests.harness(elicitation: nil)
        let awaiting = outOfBand.client(Self.createCall).audits.first
        #expect(awaiting?.auditEvent().detail == base.merging(["approval": awaiting?.approvalID ?? "?"]) { $1 })

        var granted = MCPGatewayElicitationTests.harness(elicitation: nil)
        let hash = JSONValue.object(["body": .string("b"), "title": .string("t")]).canonicalHash
        _ = granted.approvals.granted.withLock { $0.insert("github/create_issue/\(hash)") }
        #expect(granted.client(Self.createCall).toUpstream.count == 1)
        let interrupted = granted.core.handle(.upstreamExited(server: "github")).audits.first?.auditEvent()
        #expect(interrupted?.detail == base.merging(["approval": "grant1", "approvedVia": "local"]) { $1 })
    }
}

private final class Box: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}
