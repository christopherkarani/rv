import Foundation
import Synchronization
import Testing
@testable import RVMCP

/// A call is audited before it goes upstream; when that record cannot be
/// written the call is refused, never forwarded unrecorded.
@Suite("MCPGatewayCore forward audit")
struct MCPGatewayForwardAuditTests {
    static let github = MCPGatewayCoreTests.github

    @Test func allowedCallIsRecordedBeforeItIsForwarded() throws {
        let recorded = Mutex<[MCPCallRecord]>([])
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.github]), recordForward: { record in
            recorded.withLock { $0.append(record) }
            return true
        })
        _ = harness.ready()
        let call = harness.client(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_issues","arguments":{"repo":"x"}}}"#)
        #expect(call.toUpstream.count == 1)
        let record = try #require(recorded.withLock { $0 }.first)
        #expect(record.server == "github")
        #expect(record.tool == "list_issues")
        #expect(record.argumentKeys == ["repo"])
        #expect(record.outcome == .forwarding(grant: nil))
        let event = record.auditEvent()
        #expect(event.kind == .mcpCall)
        #expect(event.decision == .allowed)
        #expect(event.detail["stage"] == "forward")
    }

    @Test func allowedCallIsRefusedWhenTheAuditRecordCannotBeWritten() throws {
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.github]), recordForward: { _ in false })
        _ = harness.ready()
        let call = harness.client(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_issues","arguments":{}}}"#)
        #expect(call.toUpstream.isEmpty)
        let error = try #require(call.toClient.first?["error"])
        #expect(call.toClient.first?["id"] == .int(1))
        #expect(error["code"] == .int(-32603))
        #expect(error["message"]?.stringValue?.contains("could not write the audit record") == true)
        // Nothing is pending for it: an upstream exit answers no one twice.
        #expect(harness.core.handle(.upstreamExited(server: "github")).toClient.isEmpty)
    }

    @Test func grantedCallIsRefusedWhenTheAuditRecordCannotBeWritten() {
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.github]), recordForward: { _ in false })
        _ = harness.ready()
        let hash = JSONValue.object(["title": .string("t")]).canonicalHash
        _ = harness.approvals.granted.withLock { $0.insert("github/create_issue/\(hash)") }
        let call = harness.client(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"create_issue","arguments":{"title":"t"}}}"#)
        #expect(call.toUpstream.isEmpty)
        #expect(call.toClient.first?["error"]?["code"] == .int(-32603))
    }

    @Test func elicitedCallIsRefusedWhenTheAuditRecordCannotBeWritten() throws {
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.github]), recordForward: { _ in false })
        _ = harness.ready()
        _ = harness.client(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"elicitation":{}}}}"#)
        let asked = harness.client(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"create_issue","arguments":{"title":"t"}}}"#)
        let key = try #require(asked.toClient.first?["id"]?.stringValue)
        let answered = harness.client(#"{"jsonrpc":"2.0","id":"\#(key)","result":{"action":"accept","content":{"approve":true}}}"#)
        #expect(answered.toUpstream.isEmpty)
        #expect(answered.toClient.first?["id"] == .int(3))
        #expect(answered.toClient.first?["error"]?["code"] == .int(-32603))
    }

    /// M4: the client picks argument names and the tool name, so the
    /// audit event bounds both instead of growing one line without limit.
    @Test func theAuditEventCapsArgumentKeysAndTheSubject() {
        let keys = (0..<200).map { String(format: "%03d", $0) + String(repeating: "k", count: 1000) }
        let record = MCPCallRecord(
            server: "github", tool: String(repeating: "t", count: 5000), decision: .allow, argumentKeys: keys,
            isError: false, outcome: .forwarding(grant: nil))
        let event = record.auditEvent()
        let shown = (event.detail["argumentKeys"] ?? "").split(separator: ",", omittingEmptySubsequences: false)
        #expect(shown.count == MCPCallRecord.maximumAuditedKeys)
        #expect(shown.allSatisfy { $0.utf8.count <= MCPCallRecord.maximumAuditedKeyBytes })
        #expect(shown.first == Substring(String(keys[0].utf8.prefix(MCPCallRecord.maximumAuditedKeyBytes))!))
        #expect(event.detail["argumentKeysTruncated"] == "true")
        #expect(event.subject.utf8.count <= MCPCallRecord.maximumAuditedSubjectBytes)
        #expect((event.detail["tool"] ?? "").utf8.count <= MCPCallRecord.maximumAuditedSubjectBytes)
        let small = MCPCallRecord(
            server: "github", tool: "search", decision: .allow, argumentKeys: ["q"], isError: false,
            outcome: .forwarding(grant: nil)).auditEvent()
        #expect(small.detail["argumentKeys"] == "q")
        #expect(small.detail["argumentKeysTruncated"] == nil)
        #expect(small.subject == "github/search")
    }
}
