import Foundation
import Testing
@testable import RVDomain

// MARK: - Fixture

private struct MCPAdmissionFixture {
    let session: RuntimeSession
    let capability: RuntimeCapability
    let binding: RuntimeChannelBinding
    let boundBinding: RuntimeChannelBinding
    let instance: AgentInstance
    let activeContext: AuthenticatedAgentContext
    let revokedContext: AuthenticatedAgentContext
    let foreignContext: AuthenticatedAgentContext

    init() {
        let workspace = WorkingDirectory(validating: "/tmp/rv-mcp-admission")!
        let session = RuntimeSession(
            id: RuntimeSessionID(),
            workspaceSessionID: WorkspaceSessionID(),
            host: .opencode,
            workspace: workspace,
            backend: .seatbelt,
            startedAt: Date(timeIntervalSince1970: 0),
            child: nil
        )
        let capability = RuntimeCapability()
        let instance = AgentInstance(
            id: AgentInstanceID(),
            owner: OwnerPrincipal(uid: 501),
            definitionID: AgentDefinitionID(rawValue: "mcp-agent"),
            definitionRevision: AgentDefinitionRevision(digestHex: String(repeating: "c", count: 64)),
            workspaceSessionID: session.workspaceSessionID,
            runtimeSessionID: session.id,
            executableEvidence: .none,
            assurance: .launchObserved,
            groupLeader: RuntimeChildIdentity(pid: 100),
            workloadProcess: nil,
            parent: nil,
            effectiveAuthority: AgentAuthority(scopes: []),
            delegableAuthority: AgentAuthority(scopes: []),
            mintedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let foreign = AgentInstance(
            id: AgentInstanceID(),
            owner: OwnerPrincipal(uid: 501),
            definitionID: AgentDefinitionID(rawValue: "mcp-agent"),
            definitionRevision: AgentDefinitionRevision(digestHex: String(repeating: "c", count: 64)),
            workspaceSessionID: session.workspaceSessionID,
            runtimeSessionID: session.id,
            executableEvidence: .none,
            assurance: .launchObserved,
            groupLeader: RuntimeChildIdentity(pid: 100),
            workloadProcess: nil,
            parent: nil,
            effectiveAuthority: AgentAuthority(scopes: []),
            delegableAuthority: AgentAuthority(scopes: []),
            mintedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        self.session = session
        self.capability = capability
        binding = RuntimeChannelBinding(session: session, capability: capability)
        boundBinding = RuntimeChannelBinding(
            session: session,
            capability: capability,
            agentInstanceID: instance.id
        )
        self.instance = instance
        activeContext = AuthenticatedAgentContext(instance: instance, validity: .active)
        revokedContext = AuthenticatedAgentContext(instance: instance, validity: .inactive)
        foreignContext = AuthenticatedAgentContext(instance: foreign, validity: .active)
    }

    func frame(
        dispatch: MCPDispatchAction,
        id: UUID = UUID(),
        capability: RuntimeCapability? = nil,
        claim: UUID? = nil,
        version: Int = 1
    ) -> RuntimeActionFrame {
        RuntimeActionFrame(
            version: version,
            requestID: RuntimeActionRequestID(validating: id.uuidString)!,
            capability: capability ?? self.capability,
            claimedSession: RuntimeSessionClaim(validating: (claim ?? session.id.rawValue).uuidString)!,
            action: .mcp(dispatch: dispatch)
        )
    }

    func shellFrame(command: String = "touch marker") -> RuntimeActionFrame {
        RuntimeActionFrame(
            version: 1,
            requestID: RuntimeActionRequestID(),
            capability: capability,
            claimedSession: RuntimeSessionClaim(validating: session.id.rawValue.uuidString)!,
            action: .shell(ShellCommand(rawValue: command))
        )
    }
}

private func mcpDispatch(
    address: String = "tools.demo.user.conn.read",
    arguments: String = "{}",
    key: String = "key-1"
) -> MCPDispatchAction {
    MCPDispatchAction(
        address: address,
        argsDigest: MCPDispatchDigest.hex(of: arguments),
        idempotencyKey: key,
        argumentsJSON: arguments
    )
}

private final class VerdictFlag: @unchecked Sendable {
    var calls = 0
}

private func jsonQuoted(_ text: String) -> String {
    String(data: (try? JSONEncoder().encode(text))!, encoding: .utf8)!
}

private func mcpBody(
    _ fixture: MCPAdmissionFixture,
    address: String,
    arguments: String,
    digest: String? = nil,
    key: String = "key-1",
    version: Int = 1
) -> Data {
    Data(
        """
        {"v":\(version),"id":"\(UUID().uuidString)","capability":"\(fixture.capability.rawValue)","session":"\(fixture.session.id.rawValue.uuidString)","address":\(jsonQuoted(address)),"argsDigest":"\(digest ?? MCPDispatchDigest.hex(of: arguments))","idempotencyKey":\(jsonQuoted(key)),"arguments":\(jsonQuoted(arguments))}
        """.utf8
    )
}

private func responseJSON(
    _ response: RuntimeAdmissionResponse,
    requestID: String? = "req-1"
) throws -> [String: Any] {
    let wire = try RuntimeAdmissionCodec.encodeResponse(response, requestID: requestID).get()
    var buffer = wire
    let taken = try #require(RuntimeAdmissionCodec.takeFrame(from: &buffer))
    let body = try taken.get()
    return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

// MARK: - Codec

@Suite("RuntimeAdmissionMCPCodec")
struct RuntimeAdmissionMCPCodecTests {
    @Test func roundtripPreservesDispatch() throws {
        let fixture = MCPAdmissionFixture()
        let dispatch = mcpDispatch(arguments: "{\"q\":1}")
        let frame = fixture.frame(dispatch: dispatch)
        let wire = try RuntimeAdmissionCodec.encodeRequest(frame).get()
        var buffer = wire
        let taken = try #require(RuntimeAdmissionCodec.takeFrame(from: &buffer))
        let decoded = try RuntimeAdmissionCodec.decodeRequest(taken.get()).get()
        #expect(decoded == frame)
        #expect(decoded.action == .mcp(dispatch: dispatch))
    }

    @Test func extraKeyIsMalformed() {
        let fixture = MCPAdmissionFixture()
        let body = Data(
            """
            {"v":1,"id":"\(UUID().uuidString)","capability":"\(fixture.capability.rawValue)","session":"\(fixture.session.id.rawValue.uuidString)","address":"tools.demo.user.conn.read","argsDigest":"\(MCPDispatchDigest.hex(of: "{}"))","idempotencyKey":"key-1","arguments":"{}","workspace":"/tmp/other"}
            """.utf8
        )
        #expect(RuntimeAdmissionCodec.decodeRequest(body) == .failure(.malformed))
    }

    @Test func missingKeyIsMalformed() {
        let fixture = MCPAdmissionFixture()
        let body = Data(
            """
            {"v":1,"id":"\(UUID().uuidString)","capability":"\(fixture.capability.rawValue)","session":"\(fixture.session.id.rawValue.uuidString)","address":"tools.demo.user.conn.read","argsDigest":"\(MCPDispatchDigest.hex(of: "{}"))","idempotencyKey":"key-1"}
            """.utf8
        )
        #expect(RuntimeAdmissionCodec.decodeRequest(body) == .failure(.malformed))
    }

    @Test func oversizedBodyIsOversized() {
        let fixture = MCPAdmissionFixture()
        let big = String(repeating: "a", count: RuntimeAdmissionCodec.maxBodyBytes)
        let body = mcpBody(fixture, address: "tools.demo.user.conn.read", arguments: big)
        #expect(RuntimeAdmissionCodec.decodeRequest(body) == .failure(.oversized))
    }

    @Test func oversizedArgumentsIsMalformed() {
        let fixture = MCPAdmissionFixture()
        let big = String(repeating: "a", count: MCPDispatchWireLimits.maxArgumentsUTF8Bytes + 1)
        let body = mcpBody(fixture, address: "tools.demo.user.conn.read", arguments: big)
        #expect(body.count < RuntimeAdmissionCodec.maxBodyBytes)
        #expect(RuntimeAdmissionCodec.decodeRequest(body) == .failure(.malformed))
    }

    @Test func argumentsAtCapDecodes() throws {
        let fixture = MCPAdmissionFixture()
        let exact = String(repeating: "a", count: MCPDispatchWireLimits.maxArgumentsUTF8Bytes)
        let body = mcpBody(fixture, address: "tools.demo.user.conn.read", arguments: exact)
        let decoded = try RuntimeAdmissionCodec.decodeRequest(body).get()
        #expect(decoded.action == .mcp(dispatch: MCPDispatchAction(
            address: "tools.demo.user.conn.read",
            argsDigest: MCPDispatchDigest.hex(of: exact),
            idempotencyKey: "key-1",
            argumentsJSON: exact
        )))
    }

    @Test func oversizedAddressIsMalformed() {
        let fixture = MCPAdmissionFixture()
        let long = "tools." + String(repeating: "a", count: MCPDispatchWireLimits.maxAddressUTF8Bytes)
        let body = mcpBody(fixture, address: long, arguments: "{}")
        #expect(RuntimeAdmissionCodec.decodeRequest(body) == .failure(.malformed))
    }

    @Test func oversizedKeyIsMalformed() {
        let fixture = MCPAdmissionFixture()
        let long = String(repeating: "k", count: MCPDispatchWireLimits.maxIdempotencyKeyUTF8Bytes + 1)
        let body = mcpBody(fixture, address: "tools.demo.user.conn.read", arguments: "{}", key: long)
        #expect(RuntimeAdmissionCodec.decodeRequest(body) == .failure(.malformed))
    }

    @Test func digestMismatchIsMalformed() {
        let fixture = MCPAdmissionFixture()
        let body = mcpBody(
            fixture,
            address: "tools.demo.user.conn.read",
            arguments: "{\"q\":1}",
            digest: MCPDispatchDigest.hex(of: "{\"q\":2}")
        )
        #expect(RuntimeAdmissionCodec.decodeRequest(body) == .failure(.malformed))
    }

    @Test func emptyAddressAndKeyAreMalformed() {
        let fixture = MCPAdmissionFixture()
        #expect(RuntimeAdmissionCodec.decodeRequest(
            mcpBody(fixture, address: "", arguments: "{}")
        ) == .failure(.malformed))
        #expect(RuntimeAdmissionCodec.decodeRequest(
            mcpBody(fixture, address: "tools.demo.user.conn.read", arguments: "{}", key: "")
        ) == .failure(.malformed))
    }

    @Test func nulByteIsMalformed() {
        let fixture = MCPAdmissionFixture()
        let body = Data(
            """
            {"v":1,"id":"\(UUID().uuidString)","capability":"\(fixture.capability.rawValue)","session":"\(fixture.session.id.rawValue.uuidString)","address":"tools.demo.user.conn.re\\u0000ad","argsDigest":"\(MCPDispatchDigest.hex(of: "{}"))","idempotencyKey":"key-1","arguments":"{}"}
            """.utf8
        )
        #expect(RuntimeAdmissionCodec.decodeRequest(body) == .failure(.malformed))
    }

    @Test func unparseableAddressDecodesForDownstreamAudit() throws {
        let fixture = MCPAdmissionFixture()
        let body = mcpBody(fixture, address: "!!!not-an-address", arguments: "{\"q\":1}")
        let decoded = try RuntimeAdmissionCodec.decodeRequest(body).get()
        guard case .mcp(let dispatch) = decoded.action else {
            Issue.record("expected .mcp, got \(decoded.action)")
            return
        }
        #expect(dispatch.address == "!!!not-an-address")
        #expect(dispatch.argumentsJSON == "{\"q\":1}")
    }

    @Test func emptyArgumentsDecodeForTypedDownstreamError() throws {
        let fixture = MCPAdmissionFixture()
        let body = mcpBody(fixture, address: "tools.demo.user.conn.read", arguments: "")
        let decoded = try RuntimeAdmissionCodec.decodeRequest(body).get()
        guard case .mcp(let dispatch) = decoded.action else {
            Issue.record("expected .mcp, got \(decoded.action)")
            return
        }
        #expect(dispatch.argumentsJSON == "")
    }
}

// MARK: - Admission matrix

@Suite("RuntimeAdmissionMCPGate")
struct RuntimeAdmissionMCPGateTests {
    @Test func approveAdmitsWithInvokePayload() {
        let fixture = MCPAdmissionFixture()
        let dispatch = mcpDispatch()
        var binding: RuntimeChannelBinding? = fixture.boundBinding
        let decision = RuntimeAdmissionGate.submitMCP(
            binding: &binding,
            frame: .success(fixture.frame(dispatch: dispatch)),
            verdict: { _, _ in .approve },
            agentContext: fixture.activeContext
        )
        #expect(decision.invoke == dispatch)
        #expect(decision.response == .executed(exitStatus: -1))
        #expect(decision.event.authorization == .allowed)
        #expect(decision.event.executionAttempted == false)
        #expect(decision.event.result == "authorized")
        #expect(decision.event.fingerprint == "mcp:\(dispatch.address):\(dispatch.argsDigest):\(dispatch.idempotencyKey)")
        #expect(decision.event.mcpAddress == dispatch.address)
        #expect(decision.event.mcpConnection == "conn")
        #expect(decision.event.agentInstance == fixture.instance.id.rawValue.uuidString)
        #expect(decision.event.agentDefinition == "mcp-agent")
    }

    @Test func requireApprovalAdmitsForInvokerElicitation() {
        let fixture = MCPAdmissionFixture()
        var binding: RuntimeChannelBinding? = fixture.boundBinding
        let decision = RuntimeAdmissionGate.submitMCP(
            binding: &binding,
            frame: .success(fixture.frame(dispatch: mcpDispatch())),
            verdict: { _, _ in .requireApproval },
            agentContext: fixture.activeContext
        )
        #expect(decision.invoke != nil)
        #expect(decision.event.authorization == .allowed)
    }

    @Test func blockDeniesWithoutInvokeAndWithoutBurningFingerprint() {
        let fixture = MCPAdmissionFixture()
        let dispatch = mcpDispatch()
        var binding: RuntimeChannelBinding? = fixture.boundBinding
        let denied = RuntimeAdmissionGate.submitMCP(
            binding: &binding,
            frame: .success(fixture.frame(dispatch: dispatch)),
            verdict: { _, _ in .block },
            agentContext: fixture.activeContext
        )
        let expected = Deny(
            ruleID: RuleID(pack: PackID(rawValue: "core.mcp"), pattern: "tool-blocked"),
            reason: "mcp tool policy blocked this tool"
        )
        #expect(denied.invoke == nil)
        #expect(denied.response == .denied(expected))
        #expect(denied.event.authorization == .denied)
        #expect(denied.event.executionAttempted == false)
        #expect(denied.event.result == "core.mcp:tool-blocked")
        #expect(denied.event.fingerprint == "mcp:\(dispatch.address):\(dispatch.argsDigest):\(dispatch.idempotencyKey)")
        #expect(denied.event.mcpAddress == dispatch.address)
        #expect(denied.event.mcpConnection == "conn")
        // A deny burns no fingerprint: the same call runs after the
        // verdict changes, with a fresh request id.
        let admitted = RuntimeAdmissionGate.submitMCP(
            binding: &binding,
            frame: .success(fixture.frame(dispatch: dispatch)),
            verdict: { _, _ in .approve },
            agentContext: fixture.activeContext
        )
        #expect(admitted.invoke == dispatch)
    }

    @Test func unparseableAddressAdmitsWithoutConsultingPolicy() {
        let fixture = MCPAdmissionFixture()
        let flag = VerdictFlag()
        var binding: RuntimeChannelBinding? = fixture.boundBinding
        let decision = RuntimeAdmissionGate.submitMCP(
            binding: &binding,
            frame: .success(fixture.frame(dispatch: mcpDispatch(address: "!!!not-an-address"))),
            verdict: { _, _ in flag.calls += 1; return .block },
            agentContext: fixture.activeContext
        )
        #expect(decision.invoke != nil)
        #expect(flag.calls == 0)
        #expect(decision.event.mcpAddress == "!!!not-an-address")
        #expect(decision.event.mcpConnection == nil)
    }

    @Test func nilBindingIsUnknownSession() {
        let fixture = MCPAdmissionFixture()
        let flag = VerdictFlag()
        var binding: RuntimeChannelBinding?
        let decision = RuntimeAdmissionGate.submitMCP(
            binding: &binding,
            frame: .success(fixture.frame(dispatch: mcpDispatch())),
            verdict: { _, _ in flag.calls += 1; return .approve },
            agentContext: fixture.activeContext
        )
        #expect(decision.invoke == nil)
        #expect(decision.response == .rejected(.unknownSession))
        #expect(flag.calls == 0)
    }

    @Test func principalLessBindingIsRejectedBeforePolicy() {
        let fixture = MCPAdmissionFixture()
        let flag = VerdictFlag()
        var binding: RuntimeChannelBinding? = fixture.binding
        let decision = RuntimeAdmissionGate.submitMCP(
            binding: &binding,
            frame: .success(fixture.frame(dispatch: mcpDispatch())),
            verdict: { _, _ in flag.calls += 1; return .approve }
        )
        #expect(decision.invoke == nil)
        #expect(decision.response == .rejected(.principalRequired))
        #expect(decision.event.authorization == .rejected)
        #expect(flag.calls == 0)
    }

    @Test func smuggledContextIsRejectedAndNotStamped() {
        let fixture = MCPAdmissionFixture()
        var binding: RuntimeChannelBinding? = fixture.binding
        let decision = RuntimeAdmissionGate.submitMCP(
            binding: &binding,
            frame: .success(fixture.frame(dispatch: mcpDispatch())),
            verdict: { _, _ in .approve },
            agentContext: fixture.activeContext
        )
        #expect(decision.invoke == nil)
        #expect(decision.response == .rejected(.principalRequired))
        #expect(decision.event.agentInstance == nil)
        #expect(decision.event.agentDefinition == nil)
    }

    @Test func boundBindingWithoutContextIsRejected() {
        let fixture = MCPAdmissionFixture()
        var binding: RuntimeChannelBinding? = fixture.boundBinding
        let decision = RuntimeAdmissionGate.submitMCP(
            binding: &binding,
            frame: .success(fixture.frame(dispatch: mcpDispatch())),
            verdict: { _, _ in .approve }
        )
        #expect(decision.invoke == nil)
        #expect(decision.response == .rejected(.principalRequired))
    }

    @Test func wrongCapabilityIsRejectedBeforePolicy() {
        let fixture = MCPAdmissionFixture()
        let flag = VerdictFlag()
        var binding: RuntimeChannelBinding? = fixture.boundBinding
        let decision = RuntimeAdmissionGate.submitMCP(
            binding: &binding,
            frame: .success(fixture.frame(dispatch: mcpDispatch(), capability: RuntimeCapability())),
            verdict: { _, _ in flag.calls += 1; return .approve },
            agentContext: fixture.activeContext
        )
        #expect(decision.invoke == nil)
        #expect(decision.response == .rejected(.invalidCapability))
        #expect(flag.calls == 0)
    }

    @Test func wrongSessionClaimIsImpersonation() {
        let fixture = MCPAdmissionFixture()
        var binding: RuntimeChannelBinding? = fixture.boundBinding
        let decision = RuntimeAdmissionGate.submitMCP(
            binding: &binding,
            frame: .success(fixture.frame(dispatch: mcpDispatch(), claim: UUID())),
            verdict: { _, _ in .approve },
            agentContext: fixture.activeContext
        )
        #expect(decision.invoke == nil)
        #expect(decision.response == .rejected(.impersonation))
    }

    @Test func finishedBindingIsRejected() {
        let fixture = MCPAdmissionFixture()
        var binding: RuntimeChannelBinding? = fixture.boundBinding.finished()
        let decision = RuntimeAdmissionGate.submitMCP(
            binding: &binding,
            frame: .success(fixture.frame(dispatch: mcpDispatch())),
            verdict: { _, _ in .approve },
            agentContext: fixture.activeContext
        )
        #expect(decision.invoke == nil)
        #expect(decision.response == .rejected(.inactiveSession))
    }

    @Test func revokedPrincipalIsRejected() {
        let fixture = MCPAdmissionFixture()
        var binding: RuntimeChannelBinding? = fixture.boundBinding
        let decision = RuntimeAdmissionGate.submitMCP(
            binding: &binding,
            frame: .success(fixture.frame(dispatch: mcpDispatch())),
            verdict: { _, _ in .approve },
            agentContext: fixture.revokedContext
        )
        #expect(decision.invoke == nil)
        #expect(decision.response == .rejected(.inactiveSession))
    }

    @Test func foreignPrincipalIsImpersonation() {
        let fixture = MCPAdmissionFixture()
        var binding: RuntimeChannelBinding? = fixture.boundBinding
        let decision = RuntimeAdmissionGate.submitMCP(
            binding: &binding,
            frame: .success(fixture.frame(dispatch: mcpDispatch())),
            verdict: { _, _ in .approve },
            agentContext: fixture.foreignContext
        )
        #expect(decision.invoke == nil)
        #expect(decision.response == .rejected(.impersonation))
    }

    @Test func repeatedRequestIDReplays() {
        let fixture = MCPAdmissionFixture()
        let dispatch = mcpDispatch()
        let id = UUID()
        var binding: RuntimeChannelBinding? = fixture.boundBinding
        let first = RuntimeAdmissionGate.submitMCP(
            binding: &binding,
            frame: .success(fixture.frame(dispatch: dispatch, id: id)),
            verdict: { _, _ in .approve },
            agentContext: fixture.activeContext
        )
        #expect(first.invoke != nil)
        let replay = RuntimeAdmissionGate.submitMCP(
            binding: &binding,
            frame: .success(fixture.frame(dispatch: dispatch, id: id)),
            verdict: { _, _ in .approve },
            agentContext: fixture.activeContext
        )
        #expect(replay.invoke == nil)
        #expect(replay.response == .rejected(.replay))
    }

    @Test func repeatedIdempotencyKeyReplaysOnFingerprint() {
        let fixture = MCPAdmissionFixture()
        let dispatch = mcpDispatch()
        var binding: RuntimeChannelBinding? = fixture.boundBinding
        let first = RuntimeAdmissionGate.submitMCP(
            binding: &binding,
            frame: .success(fixture.frame(dispatch: dispatch)),
            verdict: { _, _ in .approve },
            agentContext: fixture.activeContext
        )
        #expect(first.invoke != nil)
        let replay = RuntimeAdmissionGate.submitMCP(
            binding: &binding,
            frame: .success(fixture.frame(dispatch: dispatch)),
            verdict: { _, _ in .approve },
            agentContext: fixture.activeContext
        )
        #expect(replay.invoke == nil)
        #expect(replay.response == .rejected(.replay))
        #expect(replay.event.fingerprint == first.event.fingerprint)
    }

    @Test func freshKeyAfterAdmitIsNotAReplay() {
        let fixture = MCPAdmissionFixture()
        var binding: RuntimeChannelBinding? = fixture.boundBinding
        let first = RuntimeAdmissionGate.submitMCP(
            binding: &binding,
            frame: .success(fixture.frame(dispatch: mcpDispatch(key: "key-1"))),
            verdict: { _, _ in .approve },
            agentContext: fixture.activeContext
        )
        #expect(first.invoke != nil)
        let second = RuntimeAdmissionGate.submitMCP(
            binding: &binding,
            frame: .success(fixture.frame(dispatch: mcpDispatch(key: "key-2"))),
            verdict: { _, _ in .approve },
            agentContext: fixture.activeContext
        )
        #expect(second.invoke != nil)
    }

    @Test func malformedFrameIsRejected() {
        let fixture = MCPAdmissionFixture()
        var binding: RuntimeChannelBinding? = fixture.boundBinding
        let decision = RuntimeAdmissionGate.submitMCP(
            binding: &binding,
            frame: .failure(.malformed),
            verdict: { _, _ in .approve },
            agentContext: fixture.activeContext
        )
        #expect(decision.invoke == nil)
        #expect(decision.response == .rejected(.malformed))
    }

    @Test func versionMismatchIsRejected() {
        let fixture = MCPAdmissionFixture()
        var binding: RuntimeChannelBinding? = fixture.boundBinding
        let decision = RuntimeAdmissionGate.submitMCP(
            binding: &binding,
            frame: .success(fixture.frame(dispatch: mcpDispatch(), version: 99)),
            verdict: { _, _ in .approve },
            agentContext: fixture.activeContext
        )
        #expect(decision.invoke == nil)
        #expect(decision.response == .rejected(.malformed))
    }

    @Test func nonMCPFrameIsEvaluationFailed() {
        let fixture = MCPAdmissionFixture()
        let flag = VerdictFlag()
        var binding: RuntimeChannelBinding? = fixture.boundBinding
        let decision = RuntimeAdmissionGate.submitMCP(
            binding: &binding,
            frame: .success(fixture.shellFrame()),
            verdict: { _, _ in flag.calls += 1; return .approve },
            agentContext: fixture.activeContext
        )
        #expect(decision.invoke == nil)
        #expect(decision.response == .evaluationFailed)
        #expect(decision.event.authorization == .evaluationFailed)
        #expect(flag.calls == 0)
    }
}

// MARK: - Dispatch document shape (v2 intact)

// The T0a v2 document is the dispatch wire shape: admission arguments ride
// the admission frame, never the document. These pins prove the move plus
// the `argumentsJSON` field changed no document byte.
@Suite("RuntimeAdmissionMCPDocument")
struct RuntimeAdmissionMCPDocumentTests {
    @Test func v2DocumentBytesArePinned() throws {
        let action = MCPDispatchAction(
            address: "tools.demo.user.conn.read",
            argsDigest: "0123456789abcdef",
            idempotencyKey: "key-1",
            argumentsJSON: "{\"q\":1}"
        )
        let text = try #require(MCPDispatchCodec.encode(action))
        #expect(text == "{\"address\":\"tools.demo.user.conn.read\",\"argsDigest\":\"0123456789abcdef\",\"idempotencyKey\":\"key-1\",\"version\":2}")
    }

    @Test func v2DecodeFillsEmptyArguments() throws {
        let decoded = try MCPDispatchCodec.decode(
            "{\"address\":\"tools.demo.user.conn.read\",\"argsDigest\":\"0123456789abcdef\",\"idempotencyKey\":\"key-1\",\"version\":2}"
        )
        #expect(decoded.address == "tools.demo.user.conn.read")
        #expect(decoded.argsDigest == "0123456789abcdef")
        #expect(decoded.idempotencyKey == "key-1")
        #expect(decoded.argumentsJSON == "")
    }

    @Test func rollbackToV1IsUntouched() throws {
        let action = MCPDispatchAction(
            address: "tools.demo.user.conn.read",
            argsDigest: "0123456789abcdef",
            idempotencyKey: "key-1",
            argumentsJSON: "{\"q\":1}"
        )
        let v1 = try #require(MCPDispatchCodec.rollbackToV1(action))
        #expect(v1 == "{\"address\":\"tools.demo.user.conn.read\",\"argsDigest\":\"0123456789abcdef\",\"version\":1}")
        let migrated = try MCPDispatchCodec.decode(v1)
        #expect(migrated.idempotencyKey == "migrated-0123456789abcdef")
        #expect(migrated.argumentsJSON == "")
    }
}

// MARK: - Response codec

@Suite("RuntimeAdmissionMCPResponse")
struct RuntimeAdmissionMCPResponseTests {
    @Test func mcpResponseCarriesAddressAndBody() throws {
        let json = try responseJSON(
            .mcp(MCPExecutionReceipt(
                address: "tools.demo.user.conn.read",
                body: Data("hello".utf8)
            )),
            requestID: "req-9"
        )
        #expect(json["v"] as? Int == 1)
        #expect(json["id"] as? String == "req-9")
        #expect(json["status"] as? String == "mcp")
        #expect(json["destination"] as? String == "tools.demo.user.conn.read")
        #expect(json["body"] as? String == Data("hello".utf8).base64EncodedString())
        #expect(json["reason"] == nil)
        #expect(json["correlationID"] == nil)
    }

    @Test func oversizedBodyFailsTooLargeInsteadOfTruncating() throws {
        let json = try responseJSON(
            .mcp(MCPExecutionReceipt(
                address: "tools.demo.user.conn.read",
                body: Data(repeating: 0x62, count: RuntimeAdmissionCodec.maxResponseBytes)
            ))
        )
        #expect(json["status"] as? String == "mcpFailed")
        #expect(json["reason"] as? String == "responseTooLarge")
    }

    @Test func internalErrorCarriesOnlyTheCorrelationID() throws {
        let json = try responseJSON(.mcpFailed(.internalError(correlationID: "corr-1")))
        #expect(json["status"] as? String == "mcpFailed")
        #expect(json["reason"] as? String == "internalError")
        #expect(json["correlationID"] as? String == "corr-1")
    }

    @Test func typedFailuresCarryNoCorrelationID() throws {
        let json = try responseJSON(.mcpFailed(.unknownTool))
        #expect(json["status"] as? String == "mcpFailed")
        #expect(json["reason"] as? String == "unknownTool")
        #expect(json["correlationID"] == nil)
    }

    @Test func failureReasonLabelsArePinned() {
        let cases: [(MCPDispatchFailure, String)] = [
            (.unknownTool, "unknownTool"),
            (.crossResource, "crossResource"),
            (.invalidArguments, "invalidArguments"),
            (.elicitationTimeout, "elicitationTimeout"),
            (.elicitationUnavailable, "elicitationUnavailable"),
            (.elicitationDeclined, "elicitationDeclined"),
            (.credentialFailed, "credentialFailed"),
            (.auditFailed, "auditFailed"),
            (.policyDenied, "policyDenied"),
            (.internalError(correlationID: "x"), "internalError"),
            (.responseTooLarge, "responseTooLarge"),
            (.cancelled, "cancelled"),
        ]
        for (failure, label) in cases {
            #expect(failure.reasonLabel == label)
        }
    }
}
