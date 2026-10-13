import Foundation
import Testing
@testable import RVMCP

@Suite("MCPGatewayCore approvals")
struct MCPGatewayElicitationTests {
    static let github = MCPGatewayCoreTests.github
    static let createCall = #"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"create_issue","arguments":{"title":"t","body":"b"}}}"#

    static func harness(elicitation: String?) -> GatewayHarness {
        var harness = GatewayHarness(MCPConfiguration(servers: [github]))
        _ = harness.ready()
        let capabilities = elicitation.map { #"{"elicitation":\#($0)}"# } ?? "{}"
        _ = harness.client(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":\#(capabilities)}}"#)
        return harness
    }

    static func answer(_ id: String, _ result: String) -> String {
        #"{"jsonrpc":"2.0","id":"\#(id)","result":\#(result)}"#
    }

    @Test func formCapabilityIsDetectedAcrossProtocolRevisions() {
        #expect(MCPGatewayCore.supportsFormElicitation(.object([:])))
        #expect(MCPGatewayCore.supportsFormElicitation(.object(["form": .object([:]), "url": .object([:])])))
        #expect(MCPGatewayCore.supportsFormElicitation(.object(["url": .object([:])])) == false)
        #expect(MCPGatewayCore.supportsFormElicitation(nil) == false)
        #expect(MCPGatewayCore.supportsFormElicitation(.bool(true)) == false)
    }

    @Test func acceptedElicitationRunsExactlyTheHeldCall() {
        var harness = Self.harness(elicitation: "{}")
        let held = harness.client(Self.createCall)
        #expect(held.toUpstream.isEmpty)
        let prompt = held.toClient.first
        #expect(prompt?["method"] == .string("elicitation/create"))
        let id = prompt?["id"]?.stringValue ?? ""
        #expect(id.hasPrefix("rv-approval-"))
        let message = prompt?["params"]?["message"]?.stringValue ?? ""
        #expect(message.contains("github") && message.contains("create_issue") && message.contains(#""title":"t""#))
        #expect(prompt?["params"]?["requestedSchema"]?["properties"]?["approve"]?["type"] == .string("boolean"))
        #expect(held.audits.first?.decision == .ask)
        #expect(held.audits.first?.auditEvent().decision == .pending)
        #expect(harness.approvals.requested.withLock { $0 }.isEmpty)

        let accepted = harness.client(Self.answer(id, #"{"action":"accept","content":{"approve":true}}"#))
        let forwarded = accepted.toUpstream.first?.1
        #expect(forwarded?["params"]?["name"] == .string("create_issue"))
        #expect(forwarded?["params"]?["arguments"] == .object(["title": .string("t"), "body": .string("b")]))
        let upstreamID = forwarded?["id"]?.intValue ?? -1
        let done = harness.upstream("github", #"{"jsonrpc":"2.0","id":\#(upstreamID),"result":{"content":[]}}"#)
        #expect(done.toClient.first?["id"] == .int(11))
        #expect(done.audits.first?.approvedVia == .elicitation)
        #expect(done.audits.first?.approvalID == id)
        #expect(done.audits.first?.auditEvent().decision == .allowed)
        #expect(done.audits.first?.auditEvent().detail["approvedVia"] == "elicitation")

        #expect(harness.client(Self.answer(id, #"{"action":"accept","content":{"approve":true}}"#)).isEmpty)
        #expect(harness.client(Self.createCall).toClient.first?["method"] == .string("elicitation/create"))
    }

    @Test func declineCancelAndUncheckedBoxAllRefuse() {
        for result in [
            #"{"action":"decline"}"#, #"{"action":"cancel"}"#, #"{"action":"accept","content":{"approve":false}}"#,
            #"{"action":"bogus"}"#,
        ] {
            var harness = Self.harness(elicitation: "{}")
            let id = harness.client(Self.createCall).toClient.first?["id"]?.stringValue ?? ""
            let refused = harness.client(Self.answer(id, result))
            #expect(refused.toUpstream.isEmpty, "\(result)")
            #expect(refused.toClient.first?["id"] == .int(11))
            #expect(refused.toClient.first?["result"]?["isError"] == .bool(true))
            #expect(refused.toClient.first?.compactText.contains("declined") == true)
            #expect(refused.audits.first?.declined == true)
            #expect(refused.audits.first?.auditEvent().decision == .denied)
        }
    }

    @Test func elicitationErrorFallsBackToOutOfBandApproval() {
        var harness = Self.harness(elicitation: "{}")
        let id = harness.client(Self.createCall).toClient.first?["id"]?.stringValue ?? ""
        let fallback = harness.client(#"{"jsonrpc":"2.0","id":"\#(id)","error":{"code":-32601,"message":"no"}}"#)
        #expect(fallback.toUpstream.isEmpty)
        #expect(fallback.toClient.first?.compactText.contains("rv mcp approve req1") == true)
        #expect(fallback.logs.first?.contains("confirmation code ABCDE-FGHJK") == true)
        #expect(harness.approvals.requested.withLock { $0 } == ["github/create_issue"])
    }

    @Test func clientCancellationWithdrawsThePrompt() {
        var harness = Self.harness(elicitation: "{}")
        let id = harness.client(Self.createCall).toClient.first?["id"]?.stringValue ?? ""
        let cancelled = harness.client(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":11}}"#)
        #expect(cancelled.toClient.first?["method"] == .string("notifications/cancelled"))
        #expect(cancelled.toClient.first?["params"]?["requestId"] == .string(id))
        #expect(harness.client(Self.answer(id, #"{"action":"accept","content":{"approve":true}}"#)).toUpstream.isEmpty)
    }

    @Test func clientWithoutElicitationGetsOutOfBandApprovalAndACode() {
        var harness = Self.harness(elicitation: nil)
        let paused = harness.client(Self.createCall)
        #expect(paused.toClient.first?["method"] == nil)
        #expect(paused.toClient.first?.compactText.contains("in their own terminal") == true)
        #expect(paused.logs == [
            "approval req1 for github tool create_issue: confirmation code ABCDE-FGHJK (type it when `rv mcp approve req1` asks)"
        ])
        var urlOnly = Self.harness(elicitation: #"{"url":{}}"#)
        #expect(urlOnly.client(Self.createCall).toClient.first?["method"] == nil)
    }

    @Test func unansweredPromptsAreCapped() {
        var harness = Self.harness(elicitation: "{}")
        for index in 0..<MCPGatewayCore.maximumHeld {
            let call = #"{"jsonrpc":"2.0","id":\#(100 + index),"method":"tools/call","params":{"name":"create_issue","arguments":{"n":\#(index)}}}"#
            #expect(harness.client(call).toClient.first?["method"] == .string("elicitation/create"))
        }
        let overflow = harness.client(Self.createCall)
        #expect(overflow.toClient.first?.compactText.contains("rv mcp approve req1") == true)
    }

    @Test func forgedGrantIsAuditedAndTheCallStillAsks() {
        var harness = Self.harness(elicitation: nil)
        let hash = JSONValue.object(["body": .string("b"), "title": .string("t")]).canonicalHash
        _ = harness.approvals.forged.withLock { $0.insert("github/create_issue/\(hash)") }
        let reply = harness.client(Self.createCall)
        #expect(reply.toUpstream.isEmpty)
        let event = reply.compactMap { if case .event(let e) = $0 { e } else { nil } }.first
        #expect(event?.kind == .mcpApproval)
        #expect(event?.decision == .denied)
        #expect(event?.reason == "forged grant rejected")
        #expect(event?.detail["approval"] == "forged1")
        #expect(reply.logs.contains { $0.contains("not signed by rv") })
        #expect(harness.approvals.requested.withLock { $0 } == ["github/create_issue"])
    }
}
