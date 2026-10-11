import Foundation
import RVDomain
import RVFileStore
import Synchronization
import Testing
@testable import RVIsolation

// MARK: - Doubles

private struct E1ECounters: Sendable {
    var normalizeCalls = 0
    var credentialCalls = 0
    var transportCalls = 0
    var audits: [SecretsAuditRecord] = []
    var causes: [String] = []
    var transportKeys: [String] = []
}

private final class E1EBox: Sendable {
    let mutex = Mutex(E1ECounters())

    var sink: ScopedInvokerAuditSink {
        ScopedInvokerAuditSink(append: { records in
            self.mutex.withLock { $0.audits += records }
        })
    }

    var causeLog: MCPServerCauseLog {
        MCPServerCauseLog(sink: { line in self.mutex.withLock { $0.causes.append(line) } })
    }
}

private final class E1EScriptBox: Sendable {
    let mutex: Mutex<[Result<String, any Error>]>

    init(_ script: [Result<String, any Error>]) {
        self.mutex = Mutex(script)
    }
}

/// Scripted transport with a session edge check. Mirrors
/// `MCPStdioTransport`: only the provisioned session id is served, and
/// anything else fails as `.unknownSession` before the script runs — so
/// fallback sessions can never ride a bound channel.
private struct E1ETransport: MCPTransport, Sendable {
    var box: E1EBox
    var scriptBox: E1EScriptBox
    var acceptedSession: MCPSessionID

    func roundtrip(_ request: MCPTransportRequest, session: MCPTransportSession) async throws -> MCPTransportResponse {
        box.mutex.withLock {
            $0.transportCalls += 1
            $0.transportKeys.append(request.idempotencyKey)
        }
        guard session.id == acceptedSession else {
            throw MCPTransportError.unknownSession
        }
        let next = scriptBox.mutex.withLock { queue -> Result<String, any Error> in
            guard queue.isEmpty == false else { return .success("e1e-default-ok") }
            return queue.removeFirst()
        }
        switch next {
        case .success(let body):
            return MCPTransportResponse(body: body)
        case .failure(let error):
            throw error
        }
    }
}

/// Transport failure whose description carries a marker the wire must never
/// echo. Plain words, so log redaction keeps it server-side while the
/// channel response must not contain it.
private struct E1EBoom: Error, CustomStringConvertible {
    var description: String { "E1E-BOOM-MARKER-7f3a9c" }
}

/// Transport that parks until its task is cancelled, then throws the
/// cancellation. Proves `finish()` releases a blocked submit: without the
/// teardown cancel, the waiter would sit until `bridgeTimeoutSeconds`.
private struct E1EBlockingTransport: MCPTransport, Sendable {
    var box: E1EBox

    func roundtrip(_ request: MCPTransportRequest, session: MCPTransportSession) async throws -> MCPTransportResponse {
        box.mutex.withLock { $0.transportCalls += 1 }
        while true {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private func e1eDispatch(
    address: String,
    arguments: String = "{\"q\":1}",
    key: String = UUID().uuidString
) -> MCPDispatchAction {
    MCPDispatchAction(
        address: address,
        argsDigest: MCPDispatchDigest.hex(of: arguments),
        idempotencyKey: key,
        argumentsJSON: arguments
    )
}

// MARK: - Harness

private enum E1EHarnessError: Error {
    case announceFailed
    case activateFailed
    case bindFailed
}

private struct MCPDispatchHarness: Sendable {
    static let connectionSecret = "e1e-connection-secret-value"

    let root: URL
    let runtime: RuntimeSession
    let capability: RuntimeCapability
    let box: E1EBox
    let session: RuntimeAdmissionSession
    let evidence: RuntimeAdmissionEvidence
    let toolAddress: MCPToolAddress
    let otherAddress: MCPToolAddress
    let unresolvedAddress: MCPToolAddress
    let mcpSession: MCPTransportSession

    init(
        bound: Bool = true,
        verdict: PolicyAction = .approve,
        script: [Result<String, any Error>] = [.success("e1e-tool-ok")],
        credentialError: SecretsError? = nil,
        refuseExecutor: Bool = false,
        blockingTransport: Bool = false
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-mcp-dispatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = try #require(WorkingDirectory(validating: root.path))
        let runtime = RuntimeSession(
            id: RuntimeSessionID(),
            workspaceSessionID: WorkspaceSessionID(),
            host: .opencode,
            workspace: workspace,
            backend: .seatbelt,
            startedAt: Date(timeIntervalSince1970: 0),
            child: nil
        )
        let capability = RuntimeCapability()
        let box = E1EBox()
        let toolAddress = try MCPToolAddress(integration: "demo", owner: "user", connection: "conn", tool: "read")
        let otherAddress = try MCPToolAddress(integration: "demo", owner: "user", connection: "other", tool: "read")
        let unresolvedAddress = try MCPToolAddress(integration: "demo", owner: "user", connection: "unresolved", tool: "probe")
        let mcpSession = MCPTransportSession(
            id: MCPSessionID(),
            resource: MCPResourceID(rawValue: "conn")!,
            callerToken: .random(),
            kind: .streamableHTTP
        )
        let policies = MCPPolicyStore(
            policies: [
                ToolPolicy(
                    id: "e1e-rule",
                    owner: .user,
                    pattern: .any,
                    action: verdict,
                    position: FractionalIndex(value: 1)
                )
            ],
            pluginDefault: .approve
        )
        let ref = try SecretRef(provider: "env", item: "TOKEN", field: nil)
        let mcp = RuntimeMCPConfiguration(
            registry: MCPRegistry(handlers: [
                MCPHandlerRecord(address: toolAddress, isStaticFqid: false, pluginDefault: .approve),
                MCPHandlerRecord(address: otherAddress, isStaticFqid: false, pluginDefault: .approve),
                MCPHandlerRecord(address: unresolvedAddress, isStaticFqid: false, pluginDefault: .approve),
            ]),
            policies: policies,
            elicitation: InMemoryElicitationBackend(),
            credentials: MCPCredentialResolver(resolveConnectionValues: { _, _ in
                box.mutex.withLock { $0.credentialCalls += 1 }
                if let credentialError {
                    throw credentialError
                }
                return [ref: .text(Self.connectionSecret)]
            }),
            transport: blockingTransport
                ? E1EBlockingTransport(box: box)
                : E1ETransport(box: box, scriptBox: E1EScriptBox(script), acceptedSession: mcpSession.id),
            audit: box.sink,
            causes: box.causeLog,
            sessionFor: { _, dispatch in
                guard let parsed = try? MCPToolAddress.parse(dispatch.address),
                    parsed.connection == "conn"
                else {
                    return nil
                }
                return mcpSession
            },
            bridgeTimeoutSeconds: 30
        )
        let evidence = RuntimeAdmissionEvidence()
        let configuration = RuntimeAdmissionConfiguration(
            normalize: { _, _ in
                box.mutex.withLock { $0.normalizeCalls += 1 }
                return .failure(.failed)
            },
            executor: .refuse,
            approval: { _, _ in nil },
            policy: { _ in .empty },
            evidence: evidence,
            mcpPolicy: { _, address in policies.resolve(address).action },
            mcp: refuseExecutor ? .refuse : .invoke(mcp)
        )
        let admission = RuntimeAdmissionSession(
            binding: RuntimeChannelBinding(session: runtime, capability: capability),
            configuration: configuration,
            launch: AdmittedLaunchContext(
                plan: compileContainedPlan(workspace: workspace),
                profileSource: "(deny file-link)",
                workspacePath: workspace.rawValue
            ),
            requestRead: -1,
            responseWrite: -1
        )
        if bound {
            let definition = AgentDefinition(
                id: AgentDefinitionID(rawValue: "e1e-agent"),
                displayName: "E1E",
                blurb: "",
                executableRequirement: ExecutableRequirement(allowsUnsigned: true),
                hookHost: .opencode,
                agentTag: "opencode",
                resourceProfile: RuntimeResourceProfile(id: "e1e", projects: []),
                credentialBindings: [],
                requiredAssurance: .launchObserved,
                authorityCeiling: AgentAuthority(scopes: [])
            )
            let registry = AgentInstanceRegistry(
                journal: .file(root.appendingPathComponent("agent-instances.jsonl")))
            let instance = AgentInstance(
                id: AgentInstanceID(),
                owner: OwnerPrincipal(uid: 501),
                definitionID: definition.id,
                definitionRevision: AgentDefinitionRevision.resolve(definition),
                workspaceSessionID: runtime.workspaceSessionID,
                runtimeSessionID: runtime.id,
                executableEvidence: .none,
                assurance: .launchObserved,
                groupLeader: RuntimeChildIdentity(pid: 100),
                workloadProcess: nil,
                parent: nil,
                effectiveAuthority: definition.authorityCeiling,
                delegableAuthority: definition.authorityCeiling,
                mintedAt: Date()
            )
            guard registry.announce(instance) else { throw E1EHarnessError.announceFailed }
            guard let established = EstablishedRuntimeSession(
                session: runtime, instance: instance, establishedAt: Date()),
                registry.activate(established) != nil
            else {
                throw E1EHarnessError.activateFailed
            }
            guard admission.bindAgentInstance(instance.id, registry: registry) else {
                throw E1EHarnessError.bindFailed
            }
        }
        self.root = root
        self.runtime = runtime
        self.capability = capability
        self.box = box
        self.session = admission
        self.evidence = evidence
        self.toolAddress = toolAddress
        self.otherAddress = otherAddress
        self.unresolvedAddress = unresolvedAddress
        self.mcpSession = mcpSession
    }

    func frame(_ dispatch: MCPDispatchAction, id: UUID = UUID()) -> RuntimeActionFrame {
        RuntimeActionFrame(
            version: 1,
            requestID: RuntimeActionRequestID(validating: id.uuidString)!,
            capability: capability,
            claimedSession: RuntimeSessionClaim(validating: runtime.id.rawValue.uuidString)!,
            action: .mcp(dispatch: dispatch)
        )
    }

    func bytes(_ dispatch: MCPDispatchAction, id: UUID = UUID()) throws -> Data {
        try RuntimeAdmissionCodec.encodeRequest(frame(dispatch, id: id)).get()
    }

    func counters() -> E1ECounters {
        box.mutex.withLock { $0 }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func encodedResponse(_ response: RuntimeAdmissionResponse) throws -> String {
    let wire = try RuntimeAdmissionCodec.encodeResponse(response, requestID: "req-1").get()
    var buffer = wire
    let taken = try #require(RuntimeAdmissionCodec.takeFrame(from: &buffer))
    return String(data: try taken.get(), encoding: .utf8) ?? ""
}

// MARK: - Dispatch

/// Runs one `accept` on a dedicated thread while the test suspends,
/// mirroring production (the off-pool supervise pump in
/// `IsolationBlockingWork`). swift-testing runs tests on the cooperative
/// pool, and `accept` blocks in the MCP bridge while the invoke task needs
/// pool threads — awaiting it here instead of blocking keeps the pool free
/// under parallel load. Liveness still bounds on the test bridge (30s).
private func acceptOffPool(
    session: RuntimeAdmissionSession, bytes: Data
) async -> [RuntimeAdmissionDecision] {
    await withCheckedContinuation { continuation in
        Thread {
            continuation.resume(returning: session.accept(bytes))
        }.start()
    }
}

@Suite("RuntimeAdmissionMCPDispatch")
struct RuntimeAdmissionMCPDispatchTests {
    @Test func successAnswersToolResultWithParsedRows() async throws {
        let harness = try MCPDispatchHarness()
        defer { harness.cleanup() }
        let decisions = try await acceptOffPool(session: harness.session, bytes: harness.bytes(e1eDispatch(address: harness.toolAddress.literal)))
        let decision = try #require(decisions.first)
        guard case .mcp(let receipt) = decision.response else {
            Issue.record("expected .mcp, got \(decision.response)")
            return
        }
        #expect(receipt.address == harness.toolAddress.literal)
        #expect(receipt.body == Data("e1e-tool-ok".utf8))
        #expect(decision.event.authorization == .allowed)
        #expect(decision.event.executionAttempted == true)
        #expect(decision.event.result == "mcp:succeeded")
        #expect(decision.event.mcpAddress == harness.toolAddress.literal)
        #expect(decision.event.mcpConnection == "conn")
        #expect(harness.evidence.snapshot().count == 1)
        let counters = harness.counters()
        #expect(counters.transportCalls == 1)
        #expect(counters.credentialCalls == 1)
        #expect(counters.normalizeCalls == 0)
        #expect(counters.audits.count == 2)
        let dispatchAudit = try #require(counters.audits.first)
        let outcomeAudit = try #require(counters.audits.dropFirst().first)
        #expect(dispatchAudit.kind == .toolDispatch)
        #expect(dispatchAudit.decision == .allowed)
        #expect(dispatchAudit.addressOrRef == .tool(harness.toolAddress))
        #expect(outcomeAudit.kind == .toolOutcome)
        #expect(outcomeAudit.decision == .succeeded)
        #expect(outcomeAudit.addressOrRef == .tool(harness.toolAddress))
        #expect(dispatchAudit.executionID == outcomeAudit.executionID)
    }

    @Test func transportFailureIsAnOpaqueDefect() async throws {
        let harness = try MCPDispatchHarness(script: [.failure(E1EBoom())])
        defer { harness.cleanup() }
        let decisions = try await acceptOffPool(session: harness.session, bytes: harness.bytes(e1eDispatch(address: harness.toolAddress.literal)))
        let decision = try #require(decisions.first)
        guard case .mcpFailed(.internalError(let id)) = decision.response else {
            Issue.record("expected opaque internalError, got \(decision.response)")
            return
        }
        #expect(UUID(uuidString: id) != nil)
        #expect(decision.event.authorization == .executorFailed)
        #expect(decision.event.executionAttempted == true)
        #expect(decision.event.result == "internalError:\(id)")
        // The wire carries the linkage id only: the cause marker and the
        // connection secret must not appear in the channel bytes.
        let wire = try encodedResponse(decision.response)
        #expect(wire.contains(id))
        #expect(wire.contains("E1E-BOOM-MARKER-7f3a9c") == false)
        #expect(wire.contains(MCPDispatchHarness.connectionSecret) == false)
        // The cause lives server-side, and the audit row closes the call.
        let counters = harness.counters()
        #expect(counters.causes.count == 1)
        let cause = try #require(counters.causes.first)
        #expect(cause.contains(id))
        #expect(cause.contains("E1E-BOOM-MARKER-7f3a9c"))
        #expect(cause.contains(MCPDispatchHarness.connectionSecret) == false)
        let outcomes = counters.audits.filter { $0.kind == .toolOutcome }
        #expect(outcomes.count == 1)
        let outcome = try #require(outcomes.first)
        #expect(outcome.decision == .failed)
        #expect(outcome.addressOrRef == .tool(harness.toolAddress))
        let auditJSON = String(data: (try? JSONEncoder().encode(counters.audits)) ?? Data(), encoding: .utf8) ?? ""
        #expect(auditJSON.contains(MCPDispatchHarness.connectionSecret) == false)
    }

    @Test func blockVerdictDeniesBeforeInvoke() async throws {
        let harness = try MCPDispatchHarness(verdict: .block)
        defer { harness.cleanup() }
        let decisions = try await acceptOffPool(session: harness.session, bytes: harness.bytes(e1eDispatch(address: harness.toolAddress.literal)))
        let decision = try #require(decisions.first)
        guard case .denied(let deny) = decision.response else {
            Issue.record("expected .denied, got \(decision.response)")
            return
        }
        #expect(deny.ruleID.rawValue == "core.mcp:tool-blocked")
        #expect(decision.event.authorization == .denied)
        #expect(decision.event.executionAttempted == false)
        let counters = harness.counters()
        #expect(counters.transportCalls == 0)
        #expect(counters.credentialCalls == 0)
        #expect(counters.normalizeCalls == 0)
        #expect(counters.audits.isEmpty)
    }

    @Test func unparseableAddressAuditsRawRows() async throws {
        let harness = try MCPDispatchHarness()
        defer { harness.cleanup() }
        let decisions = try await acceptOffPool(session: harness.session, bytes: harness.bytes(e1eDispatch(address: "!!!not-an-address")))
        let decision = try #require(decisions.first)
        #expect(decision.response == .mcpFailed(.unknownTool))
        #expect(decision.event.mcpAddress == "!!!not-an-address")
        #expect(decision.event.mcpConnection == nil)
        let counters = harness.counters()
        #expect(counters.transportCalls == 0)
        #expect(counters.credentialCalls == 0)
        #expect(counters.audits.count == 2)
        let dispatchAudit = try #require(counters.audits.first)
        let outcomeAudit = try #require(counters.audits.dropFirst().first)
        #expect(dispatchAudit.kind == .toolDispatch)
        #expect(dispatchAudit.decision == .denied)
        #expect(dispatchAudit.addressOrRef == .toolRaw("!!!not-an-address"))
        #expect(outcomeAudit.kind == .toolOutcome)
        #expect(outcomeAudit.decision == .failed)
        #expect(outcomeAudit.addressOrRef == .toolRaw("!!!not-an-address"))
    }

    @Test func unprovisionedConnectionIsCrossResource() async throws {
        let harness = try MCPDispatchHarness()
        defer { harness.cleanup() }
        let decisions = try await acceptOffPool(session: harness.session, bytes: harness.bytes(e1eDispatch(address: harness.otherAddress.literal)))
        let decision = try #require(decisions.first)
        #expect(decision.response == .mcpFailed(.crossResource))
        #expect(decision.event.result == "crossResource")
        let counters = harness.counters()
        #expect(counters.transportCalls == 0)
        let dispatches = counters.audits.filter { $0.kind == .toolDispatch }
        #expect(dispatches.count == 1)
        let dispatch = try #require(dispatches.first)
        #expect(dispatch.addressOrRef == .tool(harness.otherAddress))
    }

    @Test func fallbackResourceLiteralStillFailsClosed() async throws {
        let harness = try MCPDispatchHarness()
        defer { harness.cleanup() }
        // Registered and policy-approved, but no session is provisioned
        // for the connection: the fallback session's minted id cannot
        // match the bound channel, so the edge refuses with an opaque
        // defect instead of invoking.
        let decisions = try await acceptOffPool(session: harness.session, bytes: harness.bytes(e1eDispatch(address: harness.unresolvedAddress.literal)))
        let decision = try #require(decisions.first)
        guard case .mcpFailed(.internalError(let id)) = decision.response else {
            Issue.record("expected opaque internalError, got \(decision.response)")
            return
        }
        #expect(UUID(uuidString: id) != nil)
        let counters = harness.counters()
        #expect(counters.transportCalls == 1)
        #expect(counters.audits.contains { $0.kind == .toolOutcome && $0.decision == .failed })
    }

    @Test func principalLessChannelIsRejected() async throws {
        let harness = try MCPDispatchHarness(bound: false)
        defer { harness.cleanup() }
        let decisions = try await acceptOffPool(session: harness.session, bytes: harness.bytes(e1eDispatch(address: harness.toolAddress.literal)))
        let decision = try #require(decisions.first)
        #expect(decision.response == .rejected(.principalRequired))
        let counters = harness.counters()
        #expect(counters.transportCalls == 0)
        #expect(counters.credentialCalls == 0)
        #expect(counters.audits.isEmpty)
    }

    @Test func refuseExecutorFailsClosedAfterAdmission() async throws {
        let harness = try MCPDispatchHarness(refuseExecutor: true)
        defer { harness.cleanup() }
        let decisions = try await acceptOffPool(session: harness.session, bytes: harness.bytes(e1eDispatch(address: harness.toolAddress.literal)))
        let decision = try #require(decisions.first)
        #expect(decision.response == .executorFailed(.unavailable))
        #expect(decision.event.authorization == .executorFailed)
        #expect(decision.event.executionAttempted == false)
        let counters = harness.counters()
        #expect(counters.transportCalls == 0)
        #expect(counters.audits.isEmpty)
    }

    @Test func invalidArgumentsFailTypedWithRows() async throws {
        let harness = try MCPDispatchHarness()
        defer { harness.cleanup() }
        let decisions = try await acceptOffPool(session: harness.session, bytes: harness.bytes(e1eDispatch(
            address: harness.toolAddress.literal,
            arguments: "not-json"
        )))
        let decision = try #require(decisions.first)
        #expect(decision.response == .mcpFailed(.invalidArguments))
        #expect(decision.event.result == "invalidArguments:malformed")
        let counters = harness.counters()
        #expect(counters.transportCalls == 0)
        #expect(counters.credentialCalls == 0)
        #expect(counters.audits.count == 2)
        #expect(counters.audits.allSatisfy { $0.addressOrRef == .tool(harness.toolAddress) })
    }

    @Test func credentialFailureMapsTyped() async throws {
        let harness = try MCPDispatchHarness(credentialError: .providerDown("env"))
        defer { harness.cleanup() }
        let decisions = try await acceptOffPool(session: harness.session, bytes: harness.bytes(e1eDispatch(address: harness.toolAddress.literal)))
        let decision = try #require(decisions.first)
        #expect(decision.response == .mcpFailed(.credentialFailed))
        #expect(decision.event.result.hasPrefix("credentialFailed"))
        let counters = harness.counters()
        #expect(counters.transportCalls == 0)
        #expect(counters.credentialCalls == 1)
    }

    @Test func replayedDispatchIsRejected() async throws {
        let harness = try MCPDispatchHarness()
        defer { harness.cleanup() }
        let dispatch = e1eDispatch(address: harness.toolAddress.literal, key: "replay-key")
        let id = UUID()
        let first = harness.session.submitLegacy(.success(harness.frame(dispatch, id: id)))
        guard case .mcp = first.response else {
            Issue.record("expected .mcp, got \(first.response)")
            return
        }
        let replay = harness.session.submitLegacy(.success(harness.frame(dispatch, id: id)))
        #expect(replay.response == .rejected(.replay))
        let fingerprintReplay = harness.session.submitLegacy(.success(harness.frame(dispatch)))
        #expect(fingerprintReplay.response == .rejected(.replay))
        #expect(harness.counters().transportCalls == 1)
    }

    @Test func malformedDigestBytesAreRejected() async throws {
        let harness = try MCPDispatchHarness()
        defer { harness.cleanup() }
        let dispatch = e1eDispatch(address: harness.toolAddress.literal)
        let body = Data(
            """
            {"v":1,"id":"\(UUID().uuidString)","capability":"\(harness.capability.rawValue)","session":"\(harness.runtime.id.rawValue.uuidString)","address":\(jsonQuotedE1E(dispatch.address)),"argsDigest":"0000000000000000","idempotencyKey":\(jsonQuotedE1E(dispatch.idempotencyKey)),"arguments":\(jsonQuotedE1E(dispatch.argumentsJSON))}
            """.utf8
        )
        var framed = Data()
        var header = UInt32(body.count).bigEndian
        framed.append(Data(bytes: &header, count: 4))
        framed.append(body)
        let decisions = try await acceptOffPool(session: harness.session, bytes: framed)
        let decision = try #require(decisions.first)
        #expect(decision.response == .rejected(.malformed))
        #expect(harness.counters().transportCalls == 0)
    }

    @Test func admissionCapMatchesInvokerCap() {
        #expect(MCPDispatchWireLimits.maxArgumentsUTF8Bytes == MCPToolArguments.maximumBytes)
    }

    @Test func invokeThreadsTheAdmittedIdempotencyKey() async throws {
        let harness = try MCPDispatchHarness()
        defer { harness.cleanup() }
        let decisions = try await acceptOffPool(session: harness.session, bytes: harness.bytes(e1eDispatch(
            address: harness.toolAddress.literal,
            key: "e1e-wire-key-9"
        )))
        let decision = try #require(decisions.first)
        guard case .mcp = decision.response else {
            Issue.record("expected .mcp, got \(decision.response)")
            return
        }
        // The invoker's transport envelope carries the admitted wire key —
        // not a minted one — so elicitation, transport, and the admission
        // fingerprint join on one value.
        #expect(harness.counters().transportKeys == ["e1e-wire-key-9"])
    }

    @Test func finishCancelsInFlightInvoke() async throws {
        let harness = try MCPDispatchHarness(blockingTransport: true)
        defer { harness.cleanup() }
        let bytes = try harness.bytes(e1eDispatch(address: harness.toolAddress.literal))
        final class DecisionsBox: Sendable {
            let decisions = Mutex<[RuntimeAdmissionDecision]?>(nil)
        }
        let box = DecisionsBox()
        Thread {
            box.decisions.withLock { $0 = harness.session.accept(bytes) }
        }.start()
        // Wait until the invoke parks inside the transport, then tear the
        // channel down. The blocked submit must answer promptly — not at
        // the 30-second bridge timeout.
        let entered = Date(timeIntervalSinceNow: 5)
        while harness.counters().transportCalls == 0, Date() < entered {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(harness.counters().transportCalls == 1)
        harness.session.finish()
        let joined = Date(timeIntervalSinceNow: 10)
        while box.decisions.withLock({ $0 == nil }), Date() < joined {
            try await Task.sleep(for: .milliseconds(5))
        }
        let arrived = box.decisions.withLock({ $0 })
        #expect(arrived != nil)
        let decision = try #require(arrived?.first)
        #expect(decision.response == .mcpFailed(.cancelled))
        #expect(decision.event.executionAttempted == true)
    }

    @Test func concurrentSecondSubmitRefusesWithoutInvoking() async throws {
        let harness = try MCPDispatchHarness(blockingTransport: true)
        defer { harness.cleanup() }
        let bytes = try harness.bytes(e1eDispatch(address: harness.toolAddress.literal))
        final class DecisionsBox: Sendable {
            let decisions = Mutex<[RuntimeAdmissionDecision]?>(nil)
        }
        let box = DecisionsBox()
        Thread {
            box.decisions.withLock { $0 = harness.session.accept(bytes) }
        }.start()
        // Wait until the first invoke parks inside the transport: it now
        // holds the channel's single MCP slot.
        let entered = Date(timeIntervalSinceNow: 5)
        while harness.counters().transportCalls == 0, Date() < entered {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(harness.counters().transportCalls == 1)
        // A second submit while the first invoke is in flight fails
        // closed without invoking. Fresh id and key, so only the
        // single-flight guard can refuse it.
        let refused = harness.session.submitLegacy(
            .success(harness.frame(e1eDispatch(address: harness.toolAddress.literal)))
        )
        #expect(refused.response == .mcpFailed(.cancelled))
        #expect(refused.event.authorization == .executorFailed)
        #expect(refused.event.executionAttempted == false)
        #expect(refused.event.result == "cancelled")
        #expect(harness.counters().transportCalls == 1)
        harness.session.finish()
        let joined = Date(timeIntervalSinceNow: 10)
        while box.decisions.withLock({ $0 == nil }), Date() < joined {
            try await Task.sleep(for: .milliseconds(5))
        }
        let joinedOk = box.decisions.withLock({ $0 != nil })
        #expect(joinedOk)
    }
}

private func jsonQuotedE1E(_ text: String) -> String {
    String(data: (try? JSONEncoder().encode(text))!, encoding: .utf8)!
}
