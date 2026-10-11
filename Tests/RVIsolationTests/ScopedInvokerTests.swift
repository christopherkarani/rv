import Foundation
import RVDomain
import RVFileStore
import Synchronization
import Testing
@testable import RVIsolation

// MARK: - Helpers

private struct T8Counters: Sendable {
    var credentialCalls = 0
    var transportCalls = 0
    var oauthCalls = 0
    var phases: [ScopedInvokePhase] = []
    var audits: [SecretsAuditRecord] = []
    var causes: [String] = []
    var transportLog: [String] = []
}

private final class T8Box: Sendable {
    let mutex = Mutex(T8Counters())

    var sink: ScopedInvokerAuditSink {
        ScopedInvokerAuditSink(append: { events in
            self.mutex.withLock { $0.audits += events }
        })
    }

    var causeLog: MCPServerCauseLog {
        MCPServerCauseLog(sink: { line in self.mutex.withLock { $0.causes.append(line) } })
    }

    var log: MCPTransportLog {
        MCPTransportLog(sink: { line in self.mutex.withLock { $0.transportLog.append(line) } })
    }

    var phaseObserver: @Sendable (ScopedInvokePhase) -> Void {
        { phase in self.mutex.withLock { $0.phases.append(phase) } }
    }
}

private func t8Credentials(box: T8Box, values: [SecretRef: SecretValue], error: SecretsError? = nil) -> MCPCredentialResolver {
    MCPCredentialResolver(resolveConnectionValues: { _, _ in
        box.mutex.withLock { $0.credentialCalls += 1 }
        if let error {
            throw error
        }
        return values
    })
}

private final class T8ScriptBox: Sendable {
    let mutex: Mutex<[Result<String, MCPTransportError>]>

    init(_ script: [Result<String, MCPTransportError>]) {
        self.mutex = Mutex(script)
    }
}

private struct T8Transport: MCPTransport, Sendable {
    var box: T8Box
    var scriptBox: T8ScriptBox

    init(box: T8Box, script: [Result<String, MCPTransportError>]) {
        self.box = box
        self.scriptBox = T8ScriptBox(script)
    }

    func roundtrip(_ request: MCPTransportRequest, session: MCPTransportSession) async throws -> MCPTransportResponse {
        box.mutex.withLock { $0.transportCalls += 1 }
        let next = scriptBox.mutex.withLock { queue -> Result<String, MCPTransportError> in
            guard queue.isEmpty == false else { return .success("t8-default-ok") }
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

private func t8OAuth(box: T8Box, token: String? = nil, error: MCPOAuthRefreshError? = nil) -> MCPOAuthRefresher {
    MCPOAuthRefresher(refresh: { connection in
        box.mutex.withLock { $0.oauthCalls += 1 }
        if let error {
            throw error
        }
        return MCPOAuthToken(
            accessToken: token ?? "t8-refreshed-token",
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            connection: connection
        )
    })
}

private func t8Address(tool: String = "read") throws -> MCPToolAddress {
    try MCPToolAddress(integration: "demo", owner: "user", connection: "conn", tool: tool)
}

private func t8Registry(for address: MCPToolAddress) -> MCPRegistry {
    MCPRegistry(handlers: [
        MCPHandlerRecord(address: address, isStaticFqid: false, pluginDefault: .approve)
    ])
}

private func t8Policies(action: PolicyAction) -> MCPPolicyStore {
    MCPPolicyStore(
        policies: [
            ToolPolicy(
                id: "t8-rule",
                owner: .user,
                pattern: .any,
                action: action,
                position: FractionalIndex(value: 1)
            )
        ],
        pluginDefault: .approve
    )
}

private func t8Instance() -> AgentInstance {
    AgentInstance(
        id: AgentInstanceID(),
        owner: OwnerPrincipal(uid: 501),
        definitionID: AgentDefinitionID(rawValue: "t8-agent"),
        definitionRevision: AgentDefinitionRevision(digestHex: String(repeating: "b", count: 64)),
        workspaceSessionID: WorkspaceSessionID(),
        runtimeSessionID: RuntimeSessionID(),
        executableEvidence: .none,
        assurance: .launchObserved,
        groupLeader: RuntimeChildIdentity(pid: 100),
        workloadProcess: nil,
        parent: nil,
        effectiveAuthority: AgentAuthority(scopes: []),
        delegableAuthority: AgentAuthority(scopes: []),
        mintedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func t8Context(validity: AgentInstanceValidity = .active) -> AuthenticatedAgentContext {
    AuthenticatedAgentContext(instance: t8Instance(), validity: validity)
}

private func t8Session(resource: String = "conn", kind: MCPTransportKind = .streamableHTTP) -> MCPTransportSession {
    MCPTransportSession(
        id: MCPSessionID(),
        resource: MCPResourceID(rawValue: resource)!,
        callerToken: .random(),
        kind: kind
    )
}

private func t8Secret() throws -> (SecretRef, SecretValue) {
    let ref = try SecretRef(provider: "env", item: "TOKEN", field: nil)
    return (ref, .text("t8-connection-secret"))
}

private func t8Invoker(
    box: T8Box,
    address: MCPToolAddress,
    action: PolicyAction,
    elicitation: InMemoryElicitationBackend? = nil,
    credentials: MCPCredentialResolver? = nil,
    transport: T8Transport? = nil,
    oauth: MCPOAuthRefresher? = nil,
    policies: MCPPolicyStore? = nil
) throws -> ScopedInvoker {
    let (ref, value) = try t8Secret()
    return ScopedInvoker(
        registry: t8Registry(for: address),
        policies: policies ?? t8Policies(action: action),
        elicitation: elicitation ?? InMemoryElicitationBackend(),
        credentials: credentials ?? t8Credentials(box: box, values: [ref: value]),
        transport: transport ?? T8Transport(box: box, script: [.success("t8-ok")]),
        oauth: oauth ?? t8OAuth(box: box),
        audit: box.sink,
        causes: box.causeLog,
        phases: box.phaseObserver
    )
}

/// Resolves the first parked wait on `backend`, failing the test when none parks.
private func t8AnswerParked(_ backend: InMemoryElicitationBackend, decision: MCPElicitationDecision) async throws {
    var tickets: [MCPElicitationTicket] = []
    for _ in 0..<200 {
        tickets = await backend.parkedTickets()
        if tickets.isEmpty == false {
            break
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(tickets.isEmpty == false)
    for ticket in tickets {
        await backend.resolve(ticket, decision: decision)
    }
}

// MARK: - Ordering proof

@Suite struct ScopedInvokerOrderingTests {
    @Test func approvePathPhaseOrderIsExact() async throws {
        let box = T8Box()
        let address = try t8Address()
        let invoker = try t8Invoker(box: box, address: address, action: .approve)
        let result = try await invoker.invoke(
            addressLiteral: address.literal,
            argumentsJSON: "{}",
            session: t8Session(),
            ctx: t8Context(),
            options: ScopedInvokeOptions(idempotent: true)
        )
        #expect(result.body == "t8-ok")
        #expect(result.attempts == 1)
        let phases = box.mutex.withLock { $0.phases }
        #expect(phases == [.policyResolved, .argumentsValidated, .approvalSkipped, .credentialsResolved, .invoked])
    }

    @Test func requireApprovalAcceptPathPhaseOrderIsExact() async throws {
        let box = T8Box()
        let address = try t8Address()
        let backend = InMemoryElicitationBackend()
        let invoker = try t8Invoker(box: box, address: address, action: .requireApproval, elicitation: backend)
        async let invoked = invoker.invoke(
            addressLiteral: address.literal,
            argumentsJSON: "{\"q\":\"hi\"}",
            session: t8Session(),
            ctx: t8Context(),
            options: ScopedInvokeOptions(idempotent: true)
        )
        try await t8AnswerParked(backend, decision: .approved)
        let result = try await invoked
        #expect(result.body == "t8-ok")
        let phases = box.mutex.withLock { $0.phases }
        #expect(phases == [.policyResolved, .argumentsValidated, .approvalAccepted, .credentialsResolved, .invoked])
    }

    @Test func validationFailureTouchesNothingDownstream() async throws {
        let box = T8Box()
        let address = try t8Address()
        let backend = InMemoryElicitationBackend()
        let credentials = try { let (ref, value) = try t8Secret(); return t8Credentials(box: box, values: [ref: value]) }()
        let transport = T8Transport(box: box, script: [.success("must-not-run")])
        let invoker = try t8Invoker(box: box, address: address, action: .requireApproval, elicitation: backend, credentials: credentials, transport: transport)
        await #expect(throws: ScopedInvokeError.invalidArguments(.malformed)) {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "not-json",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
        #expect(await backend.parkedCount == 0)
        let counters = box.mutex.withLock { $0 }
        #expect(counters.credentialCalls == 0)
        #expect(counters.transportCalls == 0)
        #expect(counters.oauthCalls == 0)
        #expect(counters.phases == [.policyResolved])
    }

    @Test func blockTouchesNothingDownstream() async throws {
        let box = T8Box()
        let address = try t8Address()
        let backend = InMemoryElicitationBackend()
        let invoker = try t8Invoker(box: box, address: address, action: .block, elicitation: backend)
        await #expect(throws: ScopedInvokeError.policyDenied(matchedPolicyId: "t8-rule")) {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
        #expect(await backend.parkedCount == 0)
        let counters = box.mutex.withLock { $0 }
        #expect(counters.credentialCalls == 0)
        #expect(counters.transportCalls == 0)
        #expect(counters.phases.isEmpty)
    }

    @Test func blockViaStaticPinDeniesWithPinLiteral() async throws {
        let box = T8Box()
        let address = try t8Address()
        let policies = MCPPolicyStore(
            staticFqids: [StaticFqidPin(address: address, action: .block)],
            pluginDefault: .approve
        )
        let invoker = try t8Invoker(box: box, address: address, action: .approve, policies: policies)
        await #expect(throws: ScopedInvokeError.policyDenied(matchedPolicyId: address.literal)) {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
        let counters = box.mutex.withLock { $0 }
        #expect(counters.credentialCalls == 0)
        #expect(counters.transportCalls == 0)
        #expect(counters.phases.isEmpty)
    }

    @Test func blockViaFallbackDeniesWithNilMatch() async throws {
        let box = T8Box()
        let address = try t8Address()
        let policies = MCPPolicyStore(policies: [], pluginDefault: .block)
        let invoker = try t8Invoker(box: box, address: address, action: .approve, policies: policies)
        await #expect(throws: ScopedInvokeError.policyDenied(matchedPolicyId: nil)) {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
        let counters = box.mutex.withLock { $0 }
        #expect(counters.credentialCalls == 0)
        #expect(counters.transportCalls == 0)
        #expect(counters.phases.isEmpty)
    }

    @Test func declineTouchesZeroCredentials() async throws {
        let box = T8Box()
        let address = try t8Address()
        let backend = InMemoryElicitationBackend()
        let invoker = try t8Invoker(box: box, address: address, action: .requireApproval, elicitation: backend)
        let task = Task {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
        try await t8AnswerParked(backend, decision: .declined)
        await #expect(throws: ElicitationDeclinedError()) { try await task.value }
        let counters = box.mutex.withLock { $0 }
        #expect(counters.credentialCalls == 0)
        #expect(counters.transportCalls == 0)
        #expect(counters.oauthCalls == 0)
        #expect(counters.phases == [.policyResolved, .argumentsValidated])
    }

    @Test func timeoutTouchesZeroCredentials() async throws {
        let box = T8Box()
        let address = try t8Address()
        let invoker = try t8Invoker(box: box, address: address, action: .requireApproval)
        await #expect(throws: ScopedInvokeError.elicitationTimeout) {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true, elicitationTTLSeconds: 0.05, elicitationPollSeconds: 0.005)
            )
        }
        let counters = box.mutex.withLock { $0 }
        #expect(counters.credentialCalls == 0)
        #expect(counters.transportCalls == 0)
    }
}

// MARK: - Gates and typed failures

@Suite struct ScopedInvokerGateTests {
    @Test func principalLessRejectedBeforeAnything() async throws {
        let box = T8Box()
        let address = try t8Address()
        let backend = InMemoryElicitationBackend()
        let invoker = try t8Invoker(box: box, address: address, action: .approve, elicitation: backend)
        await #expect(throws: ScopedInvokeError.principalRequired) {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(validity: .revoking),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
        #expect(await backend.parkedCount == 0)
        let counters = box.mutex.withLock { $0 }
        #expect(counters.credentialCalls == 0)
        #expect(counters.transportCalls == 0)
        #expect(counters.phases.isEmpty)
        #expect(counters.audits.map(\.decision).contains(.denied))
    }

    @Test func malformedAddressIsUnknownTool() async throws {
        let box = T8Box()
        let address = try t8Address()
        let invoker = try t8Invoker(box: box, address: address, action: .approve)
        await #expect(throws: ScopedInvokeError.unknownTool) {
            try await invoker.invoke(
                addressLiteral: "tools.only-two",
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
        let counters = box.mutex.withLock { $0 }
        #expect(counters.transportCalls == 0)
    }

    @Test func unregisteredAddressIsUnknownTool() async throws {
        let box = T8Box()
        let address = try t8Address()
        let invoker = try t8Invoker(box: box, address: address, action: .approve)
        await #expect(throws: ScopedInvokeError.unknownTool) {
            try await invoker.invoke(
                addressLiteral: "tools.demo.user.conn.unregistered",
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
    }

    @Test func mismatchedSessionResourceIsCrossResource() async throws {
        let box = T8Box()
        let address = try MCPToolAddress(integration: "demo", owner: "user", connection: "other", tool: "read")
        let invoker = try t8Invoker(box: box, address: address, action: .approve)
        await #expect(throws: ScopedInvokeError.crossResource) {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(resource: "conn"),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
        let counters = box.mutex.withLock { $0 }
        #expect(counters.credentialCalls == 0)
        #expect(counters.transportCalls == 0)
        #expect(counters.oauthCalls == 0)
        #expect(counters.phases.isEmpty)
        #expect(counters.audits.map(\.decision).contains(.denied))
    }

    @Test func credentialFailureIsTypedAndSkipsTransport() async throws {
        let box = T8Box()
        let address = try t8Address()
        let (ref, value) = try t8Secret()
        let credentials = t8Credentials(box: box, values: [ref: value], error: .providerDown("env"))
        let invoker = try t8Invoker(box: box, address: address, action: .approve, credentials: credentials)
        await #expect(throws: ScopedInvokeError.credentialFailed(.providerDown("env"))) {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
        let counters = box.mutex.withLock { $0 }
        #expect(counters.credentialCalls == 1)
        #expect(counters.transportCalls == 0)
        #expect(counters.phases == [.policyResolved, .argumentsValidated, .approvalSkipped])
    }

    @Test func commitAuditFailureDeniesTheCall() async throws {
        let address = try t8Address()
        struct T8FailingSink {
            static var sink: ScopedInvokerAuditSink {
                ScopedInvokerAuditSink(append: { _ in throw SecretsLedgerError.ioFailed })
            }
        }
        let box = T8Box()
        let (ref, value) = try t8Secret()
        let invoker = ScopedInvoker(
            registry: t8Registry(for: address),
            policies: t8Policies(action: .approve),
            elicitation: InMemoryElicitationBackend(),
            credentials: t8Credentials(box: box, values: [ref: value]),
            transport: T8Transport(box: box, script: [.success("must-not-run")]),
            audit: T8FailingSink.sink
        )
        await #expect(throws: ScopedInvokeError.auditFailed) {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
        #expect(box.mutex.withLock { $0.transportCalls } == 0)
    }

    @Test func outcomeCommitFailureDeniesWithoutReinvoke() async throws {
        let address = try t8Address()
        struct T8OutcomeFailingSink {
            var box: T8Box
            var sink: ScopedInvokerAuditSink {
                ScopedInvokerAuditSink(append: { events in
                    if events.contains(where: { $0.kind == .toolOutcome && $0.decision == .succeeded }) {
                        throw SecretsLedgerError.ioFailed
                    }
                    self.box.mutex.withLock { $0.audits += events }
                })
            }
        }
        let box = T8Box()
        let (ref, value) = try t8Secret()
        let invoker = ScopedInvoker(
            registry: t8Registry(for: address),
            policies: t8Policies(action: .approve),
            elicitation: InMemoryElicitationBackend(),
            credentials: t8Credentials(box: box, values: [ref: value]),
            transport: T8Transport(box: box, script: [.success("t8-ok")]),
            audit: T8OutcomeFailingSink(box: box).sink
        )
        await #expect(throws: ScopedInvokeError.auditFailed) {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
        #expect(box.mutex.withLock { $0.transportCalls } == 1)
    }

    @Test func failurePathAuditFailureKeepsOriginalError() async throws {
        let address = try t8Address()
        struct T8FailingSink {
            static var sink: ScopedInvokerAuditSink {
                ScopedInvokerAuditSink(append: { _ in throw SecretsLedgerError.ioFailed })
            }
        }
        let box = T8Box()
        let invoker = ScopedInvoker(
            registry: t8Registry(for: address),
            policies: t8Policies(action: .block),
            elicitation: InMemoryElicitationBackend(),
            credentials: t8Credentials(box: box, values: [:]),
            transport: T8Transport(box: box, script: []),
            audit: T8FailingSink.sink
        )
        await #expect(throws: ScopedInvokeError.policyDenied(matchedPolicyId: "t8-rule")) {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
    }

    @Test func oversizedArgumentsRejected() async throws {
        let box = T8Box()
        let address = try t8Address()
        let invoker = try t8Invoker(box: box, address: address, action: .approve)
        let big = "{\"pad\":\"" + String(repeating: "x", count: 9_000) + "\"}"
        await #expect(throws: ScopedInvokeError.invalidArguments(.oversized)) {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: big,
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
    }

    @Test func missingRequiredKeyRejected() async throws {
        let box = T8Box()
        let address = try t8Address()
        let (ref, value) = try t8Secret()
        let invoker = ScopedInvoker(
            registry: t8Registry(for: address),
            policies: t8Policies(action: .approve),
            validator: MCPArgumentValidator(
                schemas: [address: MCPArgumentSchema(requiredKeys: ["query"])],
                defaultSchema: MCPArgumentSchema()
            ),
            elicitation: InMemoryElicitationBackend(),
            credentials: t8Credentials(box: box, values: [ref: value]),
            transport: T8Transport(box: box, script: [.success("must-not-run")]),
            audit: box.sink
        )
        await #expect(throws: ScopedInvokeError.invalidArguments(.missingRequired(key: "query"))) {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{\"other\":1}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
        #expect(box.mutex.withLock { $0.transportCalls } == 0)
    }
}

// MARK: - Elicitation

@Suite struct ScopedInvokerElicitationTests {
    @Test func promptShowsAddressPatternAndPreview() throws {
        let address = try t8Address()
        let store = t8Policies(action: .requireApproval)
        let policy = store.resolve(address)
        let prompt = MCPElicitationPrompt.build(
            address: address,
            policy: policy,
            arguments: MCPToolArguments(json: "{\"q\":\"hi\"}"),
            idempotencyKey: "key-1"
        )
        #expect(prompt.address == address.literal)
        #expect(prompt.matchedPattern == "policy:t8-rule")
        #expect(prompt.argumentPreview.contains("\"q\""))
        #expect(prompt.idempotencyKey == "key-1")
    }

    @Test func promptPreviewIsCappedAndRedacted() throws {
        let address = try t8Address()
        let store = MCPPolicyStore(pluginDefault: .requireApproval)
        let policy = store.resolve(address)
        let secret = "ghp_" + String(repeating: "a", count: 36)
        let pad = String(repeating: "word ", count: 150)
        let prompt = MCPElicitationPrompt.build(
            address: address,
            policy: policy,
            arguments: MCPToolArguments(json: "{\"token\":\"\(secret)\",\"pad\":\"\(pad)\"}"),
            idempotencyKey: "key-2"
        )
        #expect(prompt.matchedPattern == "plugin-default")
        #expect(prompt.argumentPreview.contains(secret) == false)
        #expect(prompt.argumentPreview.hasSuffix("...[truncated]"))
        #expect(prompt.argumentPreview.count <= MCPElicitationPrompt.maximumPreviewCharacters + "...[truncated]".count)
    }

    @Test func staticPinPromptLabelsThePin() throws {
        let address = try t8Address()
        let store = MCPPolicyStore(
            staticFqids: [StaticFqidPin(address: address, action: .requireApproval)],
            pluginDefault: .approve
        )
        let policy = store.resolve(address)
        let prompt = MCPElicitationPrompt.build(
            address: address,
            policy: policy,
            arguments: MCPToolArguments(json: "{}"),
            idempotencyKey: "key-3"
        )
        #expect(prompt.matchedPattern == "static:\(address.literal)")
    }

    @Test func ninthConcurrentParkFailsClosed() async throws {
        let backend = InMemoryElicitationBackend()
        let address = try t8Address()
        var tickets: [MCPElicitationTicket] = []
        for index in 0..<InMemoryElicitationBackend.maximumParks {
            let prompt = MCPElicitationPrompt(address: address.literal, matchedPattern: "any", argumentPreview: "{}", idempotencyKey: "k-\(index)")
            tickets.append(try await backend.park(prompt, ttl: 60))
        }
        #expect(await backend.parkedCount == 8)
        let extra = MCPElicitationPrompt(address: address.literal, matchedPattern: "any", argumentPreview: "{}", idempotencyKey: "k-extra")
        await #expect(throws: MCPElicitationError.parkFull) {
            try await backend.park(extra, ttl: 60)
        }
        #expect(tickets.count == 8)
    }

    @Test func doubleConsumeThrows() async throws {
        let backend = InMemoryElicitationBackend()
        let address = try t8Address()
        let prompt = MCPElicitationPrompt(address: address.literal, matchedPattern: "any", argumentPreview: "{}", idempotencyKey: "k-1")
        let ticket = try await backend.park(prompt, ttl: 60)
        await backend.resolve(ticket, decision: .approved)
        #expect(try await backend.consume(ticket) == .approved)
        await #expect(throws: MCPElicitationError.alreadyConsumed) {
            try await backend.consume(ticket)
        }
    }

    @Test func concurrentConsumeHasExactlyOneWinner() async throws {
        let backend = InMemoryElicitationBackend()
        let address = try t8Address()
        let prompt = MCPElicitationPrompt(address: address.literal, matchedPattern: "any", argumentPreview: "{}", idempotencyKey: "k-1")
        let ticket = try await backend.park(prompt, ttl: 60)
        await backend.resolve(ticket, decision: .approved)
        let wins = Mutex(0)
        let replays = Mutex(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    do {
                        let decision = try await backend.consume(ticket)
                        if decision == .approved {
                            wins.withLock { $0 += 1 }
                        }
                    } catch MCPElicitationError.alreadyConsumed {
                        replays.withLock { $0 += 1 }
                    } catch {
                        Issue.record("unexpected consume error: \(error)")
                    }
                }
            }
        }
        #expect(wins.withLock { $0 } == 1)
        #expect(replays.withLock { $0 } == 19)
    }

    @Test func resolveAfterTerminalIsANoOp() async throws {
        let backend = InMemoryElicitationBackend()
        let address = try t8Address()
        let prompt = MCPElicitationPrompt(address: address.literal, matchedPattern: "any", argumentPreview: "{}", idempotencyKey: "k-1")
        let ticket = try await backend.park(prompt, ttl: 60)
        await backend.resolve(ticket, decision: .approved)
        await backend.resolve(ticket, decision: .declined)
        #expect(await backend.poll(ticket) == .approved)
        #expect(try await backend.consume(ticket) == .approved)
    }

    @Test func sweepEvictsConsumedAndDeadParks() async throws {
        let backend = InMemoryElicitationBackend()
        let address = try t8Address()
        let first = MCPElicitationPrompt(address: address.literal, matchedPattern: "any", argumentPreview: "{}", idempotencyKey: "k-1")
        let ticket = try await backend.park(first, ttl: 60)
        await backend.resolve(ticket, decision: .approved)
        #expect(try await backend.consume(ticket) == .approved)
        let cancelled = MCPElicitationPrompt(address: address.literal, matchedPattern: "any", argumentPreview: "{}", idempotencyKey: "k-2")
        let cancelledTicket = try await backend.park(cancelled, ttl: 60)
        await backend.cancel(cancelledTicket)
        let fresh = MCPElicitationPrompt(address: address.literal, matchedPattern: "any", argumentPreview: "{}", idempotencyKey: "k-3")
        _ = try await backend.park(fresh, ttl: 60)
        await #expect(throws: MCPElicitationError.unknownTicket) {
            try await backend.consume(ticket)
        }
        #expect(await backend.poll(cancelledTicket) == .canceled)
        #expect(await backend.parkedTickets().count == 1)
    }

    @Test func consumeWaitingThrowsAndPollUnknownIsCanceled() async throws {
        let backend = InMemoryElicitationBackend()
        let address = try t8Address()
        let prompt = MCPElicitationPrompt(address: address.literal, matchedPattern: "any", argumentPreview: "{}", idempotencyKey: "k-1")
        let ticket = try await backend.park(prompt, ttl: 60)
        await #expect(throws: MCPElicitationError.unknownTicket) {
            try await backend.consume(ticket)
        }
        let ghost = MCPElicitationTicket(id: UUID(), idempotencyKey: "ghost")
        #expect(await backend.poll(ghost) == .canceled)
        await backend.resolve(ghost, decision: .approved)
        #expect(await backend.poll(ghost) == .canceled)
        await backend.cancel(ghost)
    }

    @Test func expiredWaitReadsExpired() async throws {
        let clock = Mutex(Date(timeIntervalSince1970: 1_700_000_000))
        let backend = InMemoryElicitationBackend(now: { clock.withLock { $0 } })
        let address = try t8Address()
        let prompt = MCPElicitationPrompt(address: address.literal, matchedPattern: "any", argumentPreview: "{}", idempotencyKey: "k-1")
        let ticket = try await backend.park(prompt, ttl: 10)
        clock.withLock { $0 = $0.addingTimeInterval(11) }
        #expect(await backend.poll(ticket) == .expired)
        #expect(await backend.parkedCount == 0)
    }

    @Test func ssePromptRoundtrip() throws {
        let address = try t8Address()
        let prompt = MCPElicitationPrompt(address: address.literal, matchedPattern: "policy:t8-rule", argumentPreview: "{\"q\":1}", idempotencyKey: "key-9")
        let frame = try #require(MCPElicitationSSE.renderPrompt(prompt))
        #expect(frame.contains("event: elicitation"))
        let parsed = try #require(MCPElicitationSSE.parsePrompt(frame))
        #expect(parsed == prompt)
    }

    @Test func sseDecisionRoundtripAndRejects() throws {
        let approved = MCPElicitationSSE.renderDecision(.approved)
        #expect(MCPElicitationSSE.parseDecision(approved) == .approved)
        let declined = MCPElicitationSSE.renderDecision(.declined)
        #expect(MCPElicitationSSE.parseDecision(declined) == .declined)
        #expect(MCPElicitationSSE.parseDecision("event: elicitation-decision\ndata: {\"decision\":\"maybe\"}\n\n") == nil)
        #expect(MCPElicitationSSE.parseDecision("event: wrong\ndata: {\"decision\":\"approved\"}\n\n") == nil)
        #expect(MCPElicitationSSE.parseDecision("data: {\"decision\":\"approved\"}\n\n") == nil)
    }

    @Test func sseFrameToleratesCommentsAndMultilineData() throws {
        let frame = MCPServerSentEvent(event: "message", data: "line-one\nline-two", id: "7").rendered()
        let parsed = try #require(MCPServerSentEvent.parsed(": comment\n" + frame))
        #expect(parsed.event == "message")
        #expect(parsed.data == "line-one\nline-two")
        #expect(parsed.id == "7")
        #expect(MCPServerSentEvent.parsed("event: a\nevent: b\ndata: x\n\n") == nil)
        #expect(MCPServerSentEvent.parsed("bogus line\n\n") == nil)
    }

    @Test func sseDuplicateIDFailsClosed() throws {
        #expect(MCPServerSentEvent.parsed("event: message\ndata: hi\nid: 1\nid: 2\n\n") == nil)
    }
}

// MARK: - Transports

@Suite struct ScopedInvokerTransportTests {
    @Test func stdioRoundtripEcho() async throws {
        let session = t8Session(kind: .stdio)
        let channel = MCPStdioChannel(session: session, send: { bytes in bytes })
        try await channel.start()
        let transport = MCPStdioTransport(channel: channel)
        let address = try t8Address()
        let response = try await transport.roundtrip(
            MCPTransportRequest(address: address, argumentsJSON: "{\"q\":1}", idempotencyKey: "k-1"),
            session: session
        )
        let envelope = try #require(MCPMessageEnvelope.decoded(Data(response.body.utf8)))
        #expect(envelope.address == address.literal)
        #expect(envelope.idempotencyKey == "k-1")
        #expect(await channel.lifecycle == .ready)
    }

    @Test func stdioLifecycleRefusesEarlyLateAndDoubleStart() async throws {
        let session = t8Session(kind: .stdio)
        let address = try t8Address()
        let channel = MCPStdioChannel(session: session, send: { bytes in bytes })
        let transport = MCPStdioTransport(channel: channel)
        let request = MCPTransportRequest(address: address, argumentsJSON: "{}", idempotencyKey: "k-1")
        await #expect(throws: MCPTransportError.transportClosed) {
            try await transport.roundtrip(request, session: session)
        }
        try await channel.start()
        await #expect(throws: MCPTransportError.lifecycleViolation) {
            try await channel.start()
        }
        await channel.close()
        await channel.close()
        #expect(await channel.lifecycle == .closed)
        await #expect(throws: MCPTransportError.transportClosed) {
            try await transport.roundtrip(request, session: session)
        }
    }

    @Test func stdioRefusesCrossResourceAndForeignSession() async throws {
        let session = t8Session(kind: .stdio)
        let channel = MCPStdioChannel(session: session, send: { bytes in bytes })
        try await channel.start()
        let other = MCPMessageEnvelope(resource: "other", address: "tools.demo.user.other.read", arguments: "{}", idempotencyKey: "k-1")
        await #expect(throws: MCPTransportError.crossResource) {
            try await channel.exchange(other)
        }
        let transport = MCPStdioTransport(channel: channel)
        let address = try t8Address()
        let request = MCPTransportRequest(address: address, argumentsJSON: "{}", idempotencyKey: "k-1")
        await #expect(throws: MCPTransportError.unknownSession) {
            try await transport.roundtrip(request, session: t8Session(kind: .stdio))
        }
    }

    @Test func stdioRefusesWrongCallerToken() async throws {
        let session = t8Session(kind: .stdio)
        let channel = MCPStdioChannel(session: session, send: { bytes in bytes })
        try await channel.start()
        let transport = MCPStdioTransport(channel: channel)
        let address = try t8Address()
        let request = MCPTransportRequest(address: address, argumentsJSON: "{}", idempotencyKey: "k-1")
        let impostor = MCPTransportSession(id: session.id, resource: session.resource, callerToken: .random(), kind: .stdio)
        await #expect(throws: MCPTransportError.unauthenticated) {
            try await transport.roundtrip(request, session: impostor)
        }
    }

    @Test func httpRoundtripThroughRouter() async throws {
        let box = T8Box()
        let session = t8Session()
        let router = MCPInMemoryRouter(
            handler: { request in MCPTransportResponse(body: "tool-said:\(request.address)") },
            log: box.log
        )
        await router.register(session)
        let client = MCPStreamableHTTPClient(
            baseURL: "http://127.0.0.1:18080",
            send: { http in await router.handleHTTP(http) },
            log: box.log
        )
        let address = try t8Address()
        let response = try await client.roundtrip(
            MCPTransportRequest(address: address, argumentsJSON: "{}", idempotencyKey: "k-1", authorization: .bearer("t8-conn-secret")),
            session: session
        )
        #expect(response.body == "tool-said:\(address.literal)")
        let lines = box.mutex.withLock { $0.transportLog }
        #expect(lines.isEmpty == false)
        #expect(lines.joined().contains("t8-conn-secret") == false)
        #expect(lines.joined().contains(session.callerToken.rawValue) == false)
    }

    @Test func httpCrossResourceIs403() async throws {
        let session = t8Session()
        let router = MCPInMemoryRouter(handler: { _ in MCPTransportResponse(body: "must-not-run") })
        await router.register(session)
        let client = MCPStreamableHTTPClient(
            baseURL: "http://127.0.0.1:18080",
            send: { http in await router.handleHTTP(http) }
        )
        let address = try t8Address()
        let crossed = MCPTransportSession(id: session.id, resource: MCPResourceID(rawValue: "other")!, callerToken: session.callerToken, kind: .streamableHTTP)
        await #expect(throws: MCPTransportError.crossResource) {
            try await client.roundtrip(
                MCPTransportRequest(address: address, argumentsJSON: "{}", idempotencyKey: "k-1"),
                session: crossed
            )
        }
        let raw = await router.handleHTTP(
            MCPHTTPRequest(
                method: .post,
                url: "http://127.0.0.1:18080/mcp/invoke",
                headers: [
                    MCPStreamableHTTPClient.sessionHeader: session.id.rawValue.uuidString,
                    MCPStreamableHTTPClient.authorizationHeader: "Bearer \(session.callerToken.rawValue)",
                ],
                body: MCPMessageEnvelope(resource: "other", address: address.literal, arguments: "{}", idempotencyKey: "k-1").encoded()!
            )
        )
        #expect(raw.status == 403)
        let body = try #require(String(data: raw.body, encoding: .utf8))
        #expect(MCPHTTPErrorBody.traceID(from: body) != nil)
    }

    @Test func httpWrongCallerIs401AndUnknownSessionIs404() async throws {
        let session = t8Session()
        let router = MCPInMemoryRouter(handler: { _ in MCPTransportResponse(body: "must-not-run") })
        await router.register(session)
        let client = MCPStreamableHTTPClient(
            baseURL: "http://127.0.0.1:18080",
            send: { http in await router.handleHTTP(http) }
        )
        let address = try t8Address()
        let impostor = MCPTransportSession(id: session.id, resource: session.resource, callerToken: .random(), kind: .streamableHTTP)
        await #expect(throws: MCPTransportError.unauthenticated) {
            try await client.roundtrip(
                MCPTransportRequest(address: address, argumentsJSON: "{}", idempotencyKey: "k-1"),
                session: impostor
            )
        }
        await #expect(throws: MCPTransportError.unknownSession) {
            try await client.roundtrip(
                MCPTransportRequest(address: address, argumentsJSON: "{}", idempotencyKey: "k-1"),
                session: t8Session()
            )
        }
    }

    @Test func nonLoopbackTargetsNeverSend() async throws {
        let address = try t8Address()
        for base in [
            "http://example.com:8080",
            "http://192.168.1.10:8080",
            "http://10.0.0.5:8080",
            "https://127.0.0.1:8080",
            "http://127.0.0.1",
            "http://[::1]:8080",
            "not-a-url",
        ] {
            let sent = Mutex(0)
            let client = MCPStreamableHTTPClient(
                baseURL: base,
                send: { _ in sent.withLock { $0 += 1 }; return .ok(Data("unreached".utf8)) }
            )
            await #expect(throws: MCPTransportError.nonLoopbackTarget) {
                try await client.roundtrip(
                    MCPTransportRequest(address: address, argumentsJSON: "{}", idempotencyKey: "k-1"),
                    session: t8Session()
                )
            }
            #expect(sent.withLock { $0 } == 0)
        }
        #expect(MCPHTTPRequest(method: .post, url: "http://localhost:8080/mcp/invoke", headers: [:], body: Data()).validatedLoopback() != nil)
        #expect(MCPHTTPRequest(method: .post, url: "http://127.0.0.1:8080/mcp/invoke", headers: [:], body: Data()).validatedLoopback() != nil)
    }

    @Test func requestPreviewRedactsURLAndHeaders() throws {
        let http = MCPHTTPRequest(
            method: .post,
            url: "http://127.0.0.1:8080/mcp/invoke?token=t8-url-secret#t8-frag-secret",
            headers: ["Authorization": "Bearer t8-header-secret", "Content-Type": "application/json"],
            body: Data()
        )
        let preview = http.redactedPreview
        #expect(preview.contains("t8-url-secret") == false)
        #expect(preview.contains("t8-frag-secret") == false)
        #expect(preview.contains("t8-header-secret") == false)
        #expect(preview.contains("token="))
        #expect(preview.contains("application/json"))
    }

    @Test func envelopeRejectsUnknownFieldsAndOversize() throws {
        let address = try t8Address()
        let good = MCPMessageEnvelope(resource: "conn", address: address.literal, arguments: "{}", idempotencyKey: "k-1")
        let bytes = try #require(good.encoded())
        #expect(MCPMessageEnvelope.decoded(bytes) == good)
        let smuggled = "{\"resource\":\"conn\",\"address\":\"\(address.literal)\",\"arguments\":\"{}\",\"idempotencyKey\":\"k-1\",\"extra\":1}"
        #expect(MCPMessageEnvelope.decoded(Data(smuggled.utf8)) == nil)
        let big = Data(repeating: 0x61, count: MCPMessageEnvelope.maximumBytes + 1)
        #expect(MCPMessageEnvelope.decoded(big) == nil)
    }

    @Test func tokenDescriptionsNeverLeakBearers() throws {
        let caller = MCPCallerToken(rawValue: "t8-caller-bearer")
        #expect("\(caller)".contains("t8-caller-bearer") == false)
        let oauth = MCPOAuthToken(accessToken: "t8-oauth-bearer", expiresAt: Date(), connection: "conn")
        #expect("\(oauth)".contains("t8-oauth-bearer") == false)
        #expect("\(oauth)".contains("conn"))
        let auth = MCPTransportAuthorization.bearer("t8-conn-bearer")
        #expect("\(auth)".contains("t8-conn-bearer") == false)
    }

    @Test func multiTextAuthorizationPicksRefOrderFirst() throws {
        let beta = try SecretRef(provider: "env", item: "BETA", field: nil)
        let alpha = try SecretRef(provider: "env", item: "ALPHA", field: nil)
        let fielded = try SecretRef(provider: "env", item: "ALPHA", field: "a-field")
        let reversed: [SecretRef: SecretValue] = [
            beta: .text("t8-beta-secret"),
            fielded: .text("t8-fielded-secret"),
            alpha: .text("t8-alpha-secret"),
        ]
        #expect(ScopedInvoker.authorization(values: reversed) == .bearer("t8-alpha-secret"))
        let filesOnly: [SecretRef: SecretValue] = [beta: .filePath("/tmp/t8-staged")]
        #expect(ScopedInvoker.authorization(values: filesOnly) == nil)
        #expect(ScopedInvoker.authorization(values: [:]) == nil)
    }

    @Test func splitLoopbackURLWithoutPathUsesWholeAuthority() throws {
        let parts = try #require(MCPHTTPRequest.splitLoopbackURL("http://127.0.0.1:8080"))
        #expect(parts.host == "127.0.0.1")
        #expect(parts.port == 8080)
    }

    @Test func splitLoopbackURLRejectsBadPortAndEmptyHost() throws {
        #expect(MCPHTTPRequest.splitLoopbackURL("http://127.0.0.1:notaport/mcp") == nil)
        #expect(MCPHTTPRequest.splitLoopbackURL("http://127.0.0.1:/mcp") == nil)
        #expect(MCPHTTPRequest.splitLoopbackURL("http://:8080/mcp") == nil)
    }

    @Test func authorizationSortsAcrossProvidersAndFields() throws {
        let envRef = try SecretRef(provider: "env", item: "TOKEN")
        let fileRef = try SecretRef(provider: "file", item: "TOKEN")
        let multi: [SecretRef: SecretValue] = [fileRef: .text("t8-file-secret"), envRef: .text("t8-env-secret")]
        #expect(ScopedInvoker.authorization(values: multi) == .bearer("t8-env-secret"))
        let plain = try SecretRef(provider: "env", item: "SHARED")
        let fielded = try SecretRef(provider: "env", item: "SHARED", field: "sub")
        let pair: [SecretRef: SecretValue] = [fielded: .text("t8-fielded-secret"), plain: .text("t8-plain-secret")]
        #expect(ScopedInvoker.authorization(values: pair) == .bearer("t8-plain-secret"))
    }

    @Test func retryableClassification() throws {
        #expect(MCPTransportError.requestTimeout.isRetryable)
        #expect(MCPTransportError.remoteFailed(status: 503).isRetryable)
        #expect(MCPTransportError.remoteFailed(status: 500).isRetryable)
        #expect(MCPTransportError.remoteFailed(status: 400).isRetryable == false)
        #expect(MCPTransportError.remoteFailed(status: 404).isRetryable == false)
        #expect(MCPTransportError.unauthenticated.isRetryable == false)
        #expect(MCPTransportError.crossResource.isRetryable == false)
        #expect(MCPTransportError.unknownSession.isRetryable == false)
        #expect(MCPTransportError.malformedEnvelope.isRetryable == false)
        #expect(MCPTransportError.transportClosed.isRetryable == false)
        #expect(MCPTransportError.nonLoopbackTarget.isRetryable == false)
        #expect(MCPTransportError.lifecycleViolation.isRetryable == false)
    }
}

// MARK: - OAuth refresh and the single retry

@Suite struct ScopedInvokerRetryTests {
    @Test func refreshThenRetrySucceedsOnce() async throws {
        let box = T8Box()
        let address = try t8Address()
        let transport = T8Transport(box: box, script: [.failure(.unauthenticated), .success("t8-recovered")])
        let oauth = t8OAuth(box: box, token: "t8-fresh-token")
        let invoker = try t8Invoker(box: box, address: address, action: .approve, transport: transport, oauth: oauth)
        let result = try await invoker.invoke(
            addressLiteral: address.literal,
            argumentsJSON: "{}",
            session: t8Session(),
            ctx: t8Context(),
            options: ScopedInvokeOptions(idempotent: true)
        )
        #expect(result.body == "t8-recovered")
        #expect(result.attempts == 2)
        let counters = box.mutex.withLock { $0 }
        #expect(counters.oauthCalls == 1)
        #expect(counters.transportCalls == 2)
        #expect(counters.phases.contains(.retried))
    }

    @Test func nonIdempotentNeverRefreshesNorRetries() async throws {
        let box = T8Box()
        let address = try t8Address()
        let transport = T8Transport(box: box, script: [.failure(.unauthenticated), .success("must-not-run")])
        let invoker = try t8Invoker(box: box, address: address, action: .approve, transport: transport)
        await #expect(throws: ScopedInvokeError.self) {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: false)
            )
        }
        let counters = box.mutex.withLock { $0 }
        #expect(counters.oauthCalls == 0)
        #expect(counters.transportCalls == 1)
        #expect(counters.phases.contains(.retried) == false)
    }

    @Test func retryableBlipRetriesOnceThenSucceeds() async throws {
        let box = T8Box()
        let address = try t8Address()
        let transport = T8Transport(box: box, script: [.failure(.remoteFailed(status: 503)), .success("t8-blip-ok")])
        let invoker = try t8Invoker(box: box, address: address, action: .approve, transport: transport)
        let result = try await invoker.invoke(
            addressLiteral: address.literal,
            argumentsJSON: "{}",
            session: t8Session(),
            ctx: t8Context(),
            options: ScopedInvokeOptions(idempotent: true)
        )
        #expect(result.body == "t8-blip-ok")
        #expect(result.attempts == 2)
        #expect(box.mutex.withLock { $0.oauthCalls } == 0)
    }

    @Test func persistentBlipSpendsExactlyTwoAttempts() async throws {
        let box = T8Box()
        let address = try t8Address()
        let transport = T8Transport(box: box, script: [.failure(.requestTimeout), .failure(.requestTimeout), .failure(.requestTimeout)])
        let invoker = try t8Invoker(box: box, address: address, action: .approve, transport: transport)
        await #expect(throws: ScopedInvokeError.self) {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
        #expect(box.mutex.withLock { $0.transportCalls } == 2)
    }

    @Test func nonRetryableFailureNeverRetries() async throws {
        let box = T8Box()
        let address = try t8Address()
        let transport = T8Transport(box: box, script: [.failure(.crossResource), .success("must-not-run")])
        let invoker = try t8Invoker(box: box, address: address, action: .approve, transport: transport)
        await #expect(throws: ScopedInvokeError.self) {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
        let counters = box.mutex.withLock { $0 }
        #expect(counters.transportCalls == 1)
        #expect(counters.oauthCalls == 0)
    }

    @Test func failedRefreshCollapsesToOpaque() async throws {
        let box = T8Box()
        let address = try t8Address()
        let transport = T8Transport(box: box, script: [.failure(.unauthenticated), .success("must-not-run")])
        let oauth = t8OAuth(box: box, error: .refreshFailed)
        let invoker = try t8Invoker(box: box, address: address, action: .approve, transport: transport, oauth: oauth)
        do {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
            Issue.record("expected opaque defect")
        } catch let error as ScopedInvokeError {
            #expect(error.isOpaque)
        }
        let counters = box.mutex.withLock { $0 }
        #expect(counters.oauthCalls == 1)
        #expect(counters.transportCalls == 1)
    }

    @Test func second401AfterRefreshIsOpaqueWithOneRefresh() async throws {
        let box = T8Box()
        let address = try t8Address()
        let transport = T8Transport(box: box, script: [.failure(.unauthenticated), .failure(.unauthenticated)])
        let oauth = t8OAuth(box: box, token: "t8-fresh-token")
        let invoker = try t8Invoker(box: box, address: address, action: .approve, transport: transport, oauth: oauth)
        do {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
            Issue.record("expected opaque defect")
        } catch let error as ScopedInvokeError {
            #expect(error.isOpaque)
        }
        let counters = box.mutex.withLock { $0 }
        #expect(counters.oauthCalls == 1)
        #expect(counters.transportCalls == 2)
        #expect(counters.phases.contains(.retried))
    }

    @Test func refreshThenBlipIsOpaqueAfterTwoAttempts() async throws {
        let box = T8Box()
        let address = try t8Address()
        let transport = T8Transport(box: box, script: [.failure(.unauthenticated), .failure(.requestTimeout)])
        let oauth = t8OAuth(box: box, token: "t8-fresh-token")
        let invoker = try t8Invoker(box: box, address: address, action: .approve, transport: transport, oauth: oauth)
        do {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
            Issue.record("expected opaque defect")
        } catch let error as ScopedInvokeError {
            #expect(error.isOpaque)
        }
        let counters = box.mutex.withLock { $0 }
        #expect(counters.oauthCalls == 1)
        #expect(counters.transportCalls == 2)
    }

    @Test func wrongConnectionTokenSkipsTheRetry() async throws {
        let box = T8Box()
        let address = try t8Address()
        let (ref, value) = try t8Secret()
        let crossedOAuth = MCPOAuthRefresher(refresh: { _ in
            box.mutex.withLock { $0.oauthCalls += 1 }
            return MCPOAuthToken(
                accessToken: "t8-crossed-token",
                expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
                connection: "some-other-connection"
            )
        })
        let invoker = ScopedInvoker(
            registry: t8Registry(for: address),
            policies: t8Policies(action: .approve),
            elicitation: InMemoryElicitationBackend(),
            credentials: t8Credentials(box: box, values: [ref: value]),
            transport: T8Transport(box: box, script: [.failure(.unauthenticated), .success("must-not-run")]),
            oauth: crossedOAuth,
            audit: box.sink,
            causes: box.causeLog,
            phases: box.phaseObserver
        )
        do {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
            Issue.record("expected opaque defect")
        } catch let error as ScopedInvokeError {
            #expect(error.isOpaque)
        }
        let counters = box.mutex.withLock { $0 }
        #expect(counters.oauthCalls == 1)
        #expect(counters.transportCalls == 1)
        #expect(counters.phases.contains(.retried) == false)
    }

    @Test func unavailableRefresherIsTheDefault() async throws {
        let box = T8Box()
        let address = try t8Address()
        let (ref, value) = try t8Secret()
        let invoker = ScopedInvoker(
            registry: t8Registry(for: address),
            policies: t8Policies(action: .approve),
            elicitation: InMemoryElicitationBackend(),
            credentials: t8Credentials(box: box, values: [ref: value]),
            transport: T8Transport(box: box, script: [.failure(.unauthenticated)]),
            audit: box.sink
        )
        do {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
            Issue.record("expected opaque defect")
        } catch let error as ScopedInvokeError {
            #expect(error.isOpaque)
        }
        #expect(box.mutex.withLock { $0.transportCalls } == 1)
    }
}

// MARK: - Opacity and audit

private func makeInvokerTempDir(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
}

private func makeInvokerAuditEvent() -> SecretsAuditRecord {
    SecretsAuditRecord.toolDispatch(
        executionID: SecretsExecutionID(),
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        principal: SecretsAuditPrincipal(
            instanceID: AgentInstanceID(), definitionID: "t8", ownerUID: 501
        ),
        toolLiteral: "tools.demo.user.conn.read",
        decision: .allowed,
        correlationID: SecretsCorrelationID()
    )
}

@Suite struct ScopedInvokerOpacityAuditTests {
    @Test func toolFailureIsOpaqueWithServerSideCause() async throws {
        let box = T8Box()
        let address = try t8Address()
        struct T8SensitiveError: Error, CustomStringConvertible {
            var description: String { "upstream blew up on password=hunter2" }
        }
        struct T8SensitiveTransport: MCPTransport, Sendable {
            var box: T8Box
            func roundtrip(_ request: MCPTransportRequest, session: MCPTransportSession) async throws -> MCPTransportResponse {
                box.mutex.withLock { $0.transportCalls += 1 }
                throw T8SensitiveError()
            }
        }
        let (ref, value) = try t8Secret()
        let invoker = ScopedInvoker(
            registry: t8Registry(for: address),
            policies: t8Policies(action: .approve),
            elicitation: InMemoryElicitationBackend(),
            credentials: t8Credentials(box: box, values: [ref: value]),
            transport: T8SensitiveTransport(box: box),
            audit: box.sink,
            causes: box.causeLog
        )
        var message = ""
        do {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: false)
            )
            Issue.record("expected opaque defect")
        } catch let error as ScopedInvokeError {
            if case .internalError(let defect) = error {
                message = defect.message
                #expect(UUID(uuidString: defect.correlationID.rawValue.uuidString) != nil)
            } else {
                Issue.record("expected internalError, got \(error)")
            }
        }
        #expect(message.hasPrefix("Internal tool error ["))
        #expect(message.hasSuffix("]"))
        #expect(message.contains("hunter2") == false)
        let counters = box.mutex.withLock { $0 }
        #expect(counters.causes.count == 1)
        #expect(counters.causes.joined().contains("hunter2") == false)
        let outcomes = counters.audits.filter { $0.kind == .toolOutcome }
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.decision == .failed)
    }

    @Test func successAuditsDispatchAndOutcomeWithJoinedExecution() async throws {
        let box = T8Box()
        let address = try t8Address()
        let invoker = try t8Invoker(box: box, address: address, action: .approve)
        let result = try await invoker.invoke(
            addressLiteral: address.literal,
            argumentsJSON: "{}",
            session: t8Session(),
            ctx: t8Context(),
            options: ScopedInvokeOptions(idempotent: true)
        )
        let audits = box.mutex.withLock { $0.audits }
        #expect(audits.count == 2)
        #expect(audits.map(\.kind) == [.toolDispatch, .toolOutcome])
        #expect(audits.map(\.decision) == [.allowed, .succeeded])
        #expect(Set(audits.map(\.executionID)) == [result.executionID])
        #expect(audits.allSatisfy { $0.addressOrRef == .tool(address) })
    }

    @Test func approvalPathAuditsAllThreeRows() async throws {
        let box = T8Box()
        let address = try t8Address()
        let backend = InMemoryElicitationBackend()
        let invoker = try t8Invoker(box: box, address: address, action: .requireApproval, elicitation: backend)
        async let invoked = invoker.invoke(
            addressLiteral: address.literal,
            argumentsJSON: "{}",
            session: t8Session(),
            ctx: t8Context(),
            options: ScopedInvokeOptions(idempotent: true)
        )
        try await t8AnswerParked(backend, decision: .approved)
        let result = try await invoked
        let audits = box.mutex.withLock { $0.audits }
        #expect(audits.map(\.kind) == [.toolDispatch, .toolApproval, .toolOutcome])
        #expect(audits.map(\.decision) == [.pendingApproval, .approved, .succeeded])
        #expect(Set(audits.map(\.executionID)) == [result.executionID])
    }

    @Test func declineAuditsDeclinedApprovalAndFailedOutcome() async throws {
        let box = T8Box()
        let address = try t8Address()
        let backend = InMemoryElicitationBackend()
        let invoker = try t8Invoker(box: box, address: address, action: .requireApproval, elicitation: backend)
        let task = Task {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
        try await t8AnswerParked(backend, decision: .declined)
        await #expect(throws: ElicitationDeclinedError()) { try await task.value }
        let audits = box.mutex.withLock { $0.audits }
        #expect(audits.map(\.kind) == [.toolDispatch, .toolDispatch, .toolApproval, .toolOutcome])
        #expect(audits.map(\.decision) == [.pendingApproval, .denied, .declined, .failed])
    }

    @Test func auditRowsCarryLabelsOnly() async throws {
        let box = T8Box()
        let address = try t8Address()
        let secret = "ghp_" + String(repeating: "z", count: 36)
        let invoker = try t8Invoker(box: box, address: address, action: .approve)
        _ = try await invoker.invoke(
            addressLiteral: address.literal,
            argumentsJSON: "{\"token\":\"\(secret)\"}",
            session: t8Session(),
            ctx: t8Context(),
            options: ScopedInvokeOptions(idempotent: true)
        )
        let audits = box.mutex.withLock { $0.audits }
        let encoder = JSONEncoder()
        for row in audits {
            let line = try #require(String(data: encoder.encode(row), encoding: .utf8))
            #expect(line.contains(secret) == false)
            #expect(line.contains("t8-connection-secret") == false)
        }
    }

    @Test func auditCauseTruncatesPastCap() throws {
        let cause = SecretsAuditCause(redacting: String(repeating: "c", count: 5_000))
        #expect(cause.redacted.hasSuffix("...[truncated]"))
        #expect(cause.redacted.count == SecretsAuditCause.maxLength + "...[truncated]".count)
    }

    @Test func causeLabelPinsFallbackAndOpaqueCases() throws {
        #expect(ScopedInvoker.causeLabel(for: .policyDenied(matchedPolicyId: nil)) == "policyDenied:fallback")
        #expect(ScopedInvoker.causeLabel(for: .auditFailed) == "auditFailed")
        let defect = MCPOpaqueDefect(correlationID: SecretsCorrelationID(rawValue: try #require(UUID(uuidString: "12345678-1234-1234-1234-1234567890ab"))))
        #expect(ScopedInvoker.causeLabel(for: .internalError(defect)) == "internalError:12345678-1234-1234-1234-1234567890AB")
    }

    @Test func fileSinkAppendsDecodableLinesAndSkipsEmptyBatches() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("t8-audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = SecretsAuditRecord.toolDispatch(
            executionID: SecretsExecutionID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            principal: SecretsAuditPrincipal(
                instanceID: AgentInstanceID(), definitionID: "t8", ownerUID: 501
            ),
            address: try t8Address(),
            decision: .allowed,
            correlationID: SecretsCorrelationID()
        )
        try SecretsLedger.append([], directory: directory, retention: .default)
        #expect(FileManager.default.fileExists(atPath: directory.path) == false)
        try SecretsLedger.append([event], directory: directory, retention: .default)
        let url = directory.appendingPathComponent("secrets-audit.jsonl")
        let text = try #require(String(data: FileManager.default.contents(atPath: url.path) ?? Data(), encoding: .utf8))
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 1)
        #expect(lines[0].contains("\"executionId\""))
        #expect(lines[0].contains("\"tool.dispatch\""))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SecretsAuditRecord.self, from: Data(lines[0].utf8))
        #expect(decoded == event)
    }

    @Test func fileAuditRawLiteralDecodesAsCanonicalToolRaw() throws {
        // Loss-vector closure proof: a row with an unparseable attempted
        // literal decodes as the shared record's raw target.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("t8-rawliteral-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = SecretsAuditRecord.toolDispatch(
            executionID: SecretsExecutionID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            principal: SecretsAuditPrincipal(
                instanceID: AgentInstanceID(), definitionID: "t8", ownerUID: 501
            ),
            toolLiteral: "nope...(",
            decision: .denied,
            correlationID: SecretsCorrelationID()
        )
        try SecretsLedger.append([event], directory: directory, retention: .default)
        let url = directory.appendingPathComponent("secrets-audit.jsonl")
        let text = try #require(String(data: FileManager.default.contents(atPath: url.path) ?? Data(), encoding: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(SecretsAuditRecord.self, from: Data(text.utf8))
        #expect(record.kind == .toolDispatch)
        #expect(record.decision == .denied)
        #expect(record.addressOrRef == .toolRaw("nope...("))
    }

    @Test func symlinkedLockFileDeniesInvokerAppend() throws {
        let dir = try makeInvokerTempDir(prefix: "rv-invoker-locklink")
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("real.lock")
        try Data("x".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent(SecretsAuditPaths.lockFileName),
            withDestinationURL: target
        )
        #expect(throws: SecretsLedgerError.lockFailed) {
            try SecretsLedger.append([makeInvokerAuditEvent()], directory: dir, retention: .default)
        }
    }

    @Test func fifoLockFileTripsInvokerTypeGuard() throws {
        let dir = try makeInvokerTempDir(prefix: "rv-invoker-lockfifo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = dir.appendingPathComponent(SecretsAuditPaths.lockFileName)
        #expect(Darwin.mkfifo(lock.path, 0o600) == 0)
        #expect(throws: SecretsLedgerError.lockFailed) {
            try SecretsLedger.append([makeInvokerAuditEvent()], directory: dir, retention: .default)
        }
    }

    @Test func symlinkedLedgerFileDeniesInvokerAppend() throws {
        let dir = try makeInvokerTempDir(prefix: "rv-invoker-ledgerlink")
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("real-ledger.jsonl")
        try "".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent(SecretsAuditPaths.fileName),
            withDestinationURL: target
        )
        #expect(throws: SecretsLedgerError.ioFailed) {
            try SecretsLedger.append([makeInvokerAuditEvent()], directory: dir, retention: .default)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "")
    }

    @Test func fifoLedgerFileTripsInvokerTypeGuard() throws {
        let dir = try makeInvokerTempDir(prefix: "rv-invoker-ledgerfifo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = dir.appendingPathComponent(SecretsAuditPaths.fileName)
        #expect(Darwin.mkfifo(ledger.path, 0o600) == 0)
        // Held reader so the O_WRONLY open succeeds instead of blocking;
        // the fstat type guard below it is what must deny.
        let reader = Darwin.open(ledger.path, O_RDONLY | O_NONBLOCK)
        try #require(reader >= 0)
        defer { Darwin.close(reader) }
        #expect(throws: SecretsLedgerError.ioFailed) {
            try SecretsLedger.append([makeInvokerAuditEvent()], directory: dir, retention: .default)
        }
    }
}

// MARK: - Dispatch codec

@Suite struct ScopedInvokerCodecTests {
    @Test func v2Roundtrip() throws {
        let address = try t8Address()
        let action = MCPDispatchAction.build(address: address, arguments: MCPToolArguments(json: "{\"q\":1}"), idempotencyKey: "key-1")
        let text = try #require(MCPDispatchCodec.encode(action))
        #expect(text.contains("\"version\":2"))
        #expect(try MCPDispatchCodec.decode(text) == action)
    }

    @Test func v1MigratesDeterministically() throws {
        let v1 = "{\"address\":\"tools.demo.user.conn.read\",\"argsDigest\":\"abc123\",\"version\":1}"
        let action = try MCPDispatchCodec.decode(v1)
        #expect(action.address == "tools.demo.user.conn.read")
        #expect(action.argsDigest == "abc123")
        #expect(action.idempotencyKey == "migrated-abc123")
        #expect(try MCPDispatchCodec.decode(v1).idempotencyKey == action.idempotencyKey)
    }

    @Test func rollbackDropsTheKey() throws {
        let address = try t8Address()
        let action = MCPDispatchAction.build(address: address, arguments: MCPToolArguments(json: "{}"), idempotencyKey: "key-7")
        let v1 = try #require(MCPDispatchCodec.rollbackToV1(action))
        #expect(v1.contains("\"version\":1"))
        #expect(v1.contains("idempotencyKey") == false)
        let migrated = try MCPDispatchCodec.decode(v1)
        #expect(migrated.address == action.address)
        #expect(migrated.argsDigest == action.argsDigest)
    }

    @Test func unknownVersionFieldAndShapeFailClosed() throws {
        #expect(throws: MCPDispatchCodecError.unsupportedVersion(9)) {
            try MCPDispatchCodec.decode("{\"version\":9,\"address\":\"a\",\"argsDigest\":\"b\",\"idempotencyKey\":\"c\"}")
        }
        #expect(throws: MCPDispatchCodecError.unknownField("smuggled")) {
            try MCPDispatchCodec.decode("{\"version\":2,\"address\":\"a\",\"argsDigest\":\"b\",\"idempotencyKey\":\"c\",\"smuggled\":1}")
        }
        #expect(throws: MCPDispatchCodecError.malformed) {
            try MCPDispatchCodec.decode("{\"version\":2,\"address\":\"a\"}")
        }
        #expect(throws: MCPDispatchCodecError.malformed) {
            try MCPDispatchCodec.decode("not-json")
        }
        #expect(throws: MCPDispatchCodecError.malformed) {
            try MCPDispatchCodec.decode("{\"version\":2,\"address\":\"a\",\"argsDigest\":\"b\",\"idempotencyKey\":\"\"}")
        }
    }

    @Test func digestIsDeterministicAndSensitive() throws {
        #expect(MCPDispatchDigest.hex(of: "{\"q\":1}") == MCPDispatchDigest.hex(of: "{\"q\":1}"))
        #expect(MCPDispatchDigest.hex(of: "{\"q\":1}") != MCPDispatchDigest.hex(of: "{\"q\":2}"))
        #expect(MCPDispatchDigest.hex(of: "{}").count == 16)
    }
}

// MARK: - Stress and adversarial shapes

@Suite struct ScopedInvokerStressTests {
    @Test func concurrentInvokesOnDistinctSessionsSucceed() async throws {
        let box = T8Box()
        let address = try t8Address()
        let invoker = try t8Invoker(box: box, address: address, action: .approve)
        let executions = try await withThrowingTaskGroup(of: SecretsExecutionID.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let result = try await invoker.invoke(
                        addressLiteral: address.literal,
                        argumentsJSON: "{}",
                        session: t8Session(),
                        ctx: t8Context(),
                        options: ScopedInvokeOptions(idempotent: true)
                    )
                    return result.executionID
                }
            }
            var ids: [SecretsExecutionID] = []
            for try await id in group {
                ids.append(id)
            }
            return ids
        }
        #expect(Set(executions).count == 20)
        #expect(box.mutex.withLock { $0.transportCalls } == 20)
        #expect(box.mutex.withLock { $0.audits.count } == 40)
    }

    @Test func concurrentParksCapAtEight() async throws {
        let backend = InMemoryElicitationBackend()
        let address = try t8Address()
        let parked = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<16 {
                group.addTask {
                    let prompt = MCPElicitationPrompt(
                        address: address.literal,
                        matchedPattern: "any",
                        argumentPreview: "{}",
                        idempotencyKey: "stress-\(index)"
                    )
                    do {
                        try await backend.park(prompt, ttl: 60)
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var count = 0
            for await won in group where won {
                count += 1
            }
            return count
        }
        #expect(parked == 8)
        #expect(await backend.parkedCount == 8)
    }

    @Test func unicodeAndEmptyArgumentsBehave() async throws {
        let box = T8Box()
        let address = try t8Address()
        let invoker = try t8Invoker(box: box, address: address, action: .approve)
        let unicode = try await invoker.invoke(
            addressLiteral: address.literal,
            argumentsJSON: "{\"emoji\":\"🎉\",\"cjk\":\"日本語\",\"rtl\":\"مرحبا\"}",
            session: t8Session(),
            ctx: t8Context(),
            options: ScopedInvokeOptions(idempotent: true)
        )
        #expect(unicode.body == "t8-ok")
        await #expect(throws: ScopedInvokeError.invalidArguments(.malformed)) {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "[1,2]",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
        await #expect(throws: ScopedInvokeError.invalidArguments(.malformed)) {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
    }

    @Test func dotTolerantToolSegmentInvokes() async throws {
        let box = T8Box()
        let address = try t8Address(tool: "my.tool.v2")
        let invoker = try t8Invoker(box: box, address: address, action: .approve)
        let result = try await invoker.invoke(
            addressLiteral: address.literal,
            argumentsJSON: "{}",
            session: t8Session(),
            ctx: t8Context(),
            options: ScopedInvokeOptions(idempotent: true)
        )
        #expect(result.body == "t8-ok")
        #expect(address.literal == "tools.demo.user.conn.my.tool.v2")
    }

    @Test func nonpositiveTransportBudgetNeverSends() async throws {
        let box = T8Box()
        let address = try t8Address()
        let invoker = try t8Invoker(box: box, address: address, action: .approve)
        await #expect(throws: ScopedInvokeError.self) {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true, transportTimeoutSeconds: 0)
            )
        }
        #expect(box.mutex.withLock { $0.transportCalls } == 0)
    }
}

// MARK: - Edge coverage

private struct T8ForeignError: Error {}

private struct T8ParkThrowingBackend: MCPElicitationBackend, Sendable {
    func park(_ prompt: MCPElicitationPrompt, ttl: TimeInterval) async throws -> MCPElicitationTicket {
        throw T8ForeignError()
    }

    func poll(_ ticket: MCPElicitationTicket) async -> MCPElicitationStatus {
        .canceled
    }

    func consume(_ ticket: MCPElicitationTicket) async throws -> MCPElicitationDecision {
        throw MCPElicitationError.unknownTicket
    }

    func cancel(_ ticket: MCPElicitationTicket) async {}
}

private struct T8ConsumeThrowingBackend: MCPElicitationBackend, Sendable {
    var inner: InMemoryElicitationBackend

    func park(_ prompt: MCPElicitationPrompt, ttl: TimeInterval) async throws -> MCPElicitationTicket {
        try await inner.park(prompt, ttl: ttl)
    }

    func poll(_ ticket: MCPElicitationTicket) async -> MCPElicitationStatus {
        await inner.poll(ticket)
    }

    func consume(_ ticket: MCPElicitationTicket) async throws -> MCPElicitationDecision {
        throw T8ForeignError()
    }

    func cancel(_ ticket: MCPElicitationTicket) async {
        await inner.cancel(ticket)
    }
}

private struct T8SlowBackend: MCPElicitationBackend, Sendable {
    var inner: InMemoryElicitationBackend

    func park(_ prompt: MCPElicitationPrompt, ttl: TimeInterval) async throws -> MCPElicitationTicket {
        try await inner.park(prompt, ttl: 60)
    }

    func poll(_ ticket: MCPElicitationTicket) async -> MCPElicitationStatus {
        await inner.poll(ticket)
    }

    func consume(_ ticket: MCPElicitationTicket) async throws -> MCPElicitationDecision {
        try await inner.consume(ticket)
    }

    func cancel(_ ticket: MCPElicitationTicket) async {
        await inner.cancel(ticket)
    }
}

private func t8ForeignCredentials() -> MCPCredentialResolver {
    MCPCredentialResolver(resolveConnectionValues: { _, _ in throw T8ForeignError() })
}

private struct T8MapProvider: SecretsProvider, Sendable {
    var id: String
    var values: [SecretRef: SecretValue]

    func resolve(_ ref: SecretRef) async throws -> SecretValue {
        guard let value = values[ref] else {
            throw SecretsError.notFound(id)
        }
        return value
    }

    func health() async -> ProviderHealth {
        ProviderHealth(ok: true)
    }
}

@Suite struct ScopedInvokerEdgeTests {
    @Test func resourceIDValidation() throws {
        #expect(MCPResourceID(rawValue: "conn")?.rawValue == "conn")
        #expect(MCPResourceID(rawValue: "") == nil)
        #expect(MCPResourceID(rawValue: "has.dot") == nil)
        #expect(MCPResourceID(rawValue: "has space") == nil)
        #expect(MCPResourceID(rawValue: String(repeating: "x", count: 129)) == nil)
    }

    @Test func envelopeKeyIndexedArmsAreNil() throws {
        #expect(MCPEnvelopeKey("resource").intValue == nil)
        #expect(MCPEnvelopeKey(intValue: 0) == nil)
    }

    @Test func toolPatternLabels() throws {
        let address = try t8Address()
        #expect(ToolPattern.exact(address).elicitationLabel == "exact:\(address.literal)")
        #expect(ToolPattern.any.elicitationLabel == "any")
        #expect(ToolPattern.trailingPrefix("tools.demo.").elicitationLabel == "prefix:tools.demo.")
        #expect(ToolPattern.singleMid(prefix: "tools.a.", suffix: ".read").elicitationLabel == "mid:tools.a.*.read")
    }

    @Test func validatorTooManyKeysAndBadKey() throws {
        let address = try t8Address()
        let validator = MCPArgumentValidator(
            schemas: [address: MCPArgumentSchema(maximumKeys: 1)],
            defaultSchema: MCPArgumentSchema()
        )
        #expect(throws: MCPArgumentValidationError.tooManyKeys) {
            try validator.validate("{\"a\":1,\"b\":2}", for: address)
        }
        #expect(throws: MCPArgumentValidationError.badKey(index: 0)) {
            try validator.validate("{\"\":1}", for: address)
        }
    }

    @Test func validatorRequiredKeysSatisfied() throws {
        let address = try t8Address()
        let validator = MCPArgumentValidator(
            schemas: [address: MCPArgumentSchema(requiredKeys: ["query"])],
            defaultSchema: MCPArgumentSchema()
        )
        let args = try validator.validate("{\"query\":\"hi\"}", for: address)
        #expect(args.json == "{\"query\":\"hi\"}")
    }

    @Test func invokeLevelTooManyKeysAndBadKey() async throws {
        let box = T8Box()
        let address = try t8Address()
        let (ref, value) = try t8Secret()
        let invoker = ScopedInvoker(
            registry: t8Registry(for: address),
            policies: t8Policies(action: .approve),
            validator: MCPArgumentValidator(defaultSchema: MCPArgumentSchema(maximumKeys: 1)),
            elicitation: InMemoryElicitationBackend(),
            credentials: t8Credentials(box: box, values: [ref: value]),
            transport: T8Transport(box: box, script: []),
            audit: box.sink
        )
        await #expect(throws: ScopedInvokeError.invalidArguments(.tooManyKeys)) {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{\"a\":1,\"b\":2}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
        await #expect(throws: ScopedInvokeError.invalidArguments(.badKey(index: 0))) {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{\"\":1}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
    }

    @Test func parsePromptRejectsWrongEventAndCorruptData() throws {
        #expect(MCPElicitationSSE.parsePrompt("event: message\ndata: {}\n\n") == nil)
        #expect(MCPElicitationSSE.parsePrompt("event: elicitation\ndata: not-json\n\n") == nil)
        #expect(MCPElicitationSSE.parsePrompt("not-a-frame") == nil)
    }

    @Test func consumeUnknownTicketThrows() async throws {
        let backend = InMemoryElicitationBackend()
        let ghost = MCPElicitationTicket(id: UUID(), idempotencyKey: "ghost")
        await #expect(throws: MCPElicitationError.unknownTicket) {
            try await backend.consume(ghost)
        }
    }

    @Test func consumeAfterExpiryThrows() async throws {
        let clock = Mutex(Date(timeIntervalSince1970: 1_700_000_000))
        let backend = InMemoryElicitationBackend(now: { clock.withLock { $0 } })
        let address = try t8Address()
        let prompt = MCPElicitationPrompt(address: address.literal, matchedPattern: "any", argumentPreview: "{}", idempotencyKey: "k-1")
        let ticket = try await backend.park(prompt, ttl: 10)
        clock.withLock { $0 = $0.addingTimeInterval(11) }
        await #expect(throws: MCPElicitationError.unknownTicket) {
            try await backend.consume(ticket)
        }
    }

    @Test func cancelWaitingReadsCanceledAndSweepExpires() async throws {
        let clock = Mutex(Date(timeIntervalSince1970: 1_700_000_000))
        let backend = InMemoryElicitationBackend(now: { clock.withLock { $0 } })
        let address = try t8Address()
        let first = MCPElicitationPrompt(address: address.literal, matchedPattern: "any", argumentPreview: "{}", idempotencyKey: "k-1")
        let ticket = try await backend.park(first, ttl: 60)
        await backend.cancel(ticket)
        #expect(await backend.poll(ticket) == .canceled)
        let short = MCPElicitationPrompt(address: address.literal, matchedPattern: "any", argumentPreview: "{}", idempotencyKey: "k-2")
        _ = try await backend.park(short, ttl: 10)
        clock.withLock { $0 = $0.addingTimeInterval(11) }
        let fresh = MCPElicitationPrompt(address: address.literal, matchedPattern: "any", argumentPreview: "{}", idempotencyKey: "k-3")
        _ = try await backend.park(fresh, ttl: 60)
        #expect(await backend.parkedCount == 1)
    }

    @Test func brokerBackedResolverServesEndToEnd() async throws {
        let box = T8Box()
        let address = try t8Address()
        let ref = try SecretRef(provider: "env", item: "TOKEN", field: nil)
        let broker = SecretBroker(
            providers: [T8MapProvider(id: "env", values: [ref: .text("t8-broker-secret")])],
            audit: SecretBrokerAuditSink(append: { _ in }),
            liveness: .usableOnly
        )
        let invoker = ScopedInvoker(
            registry: t8Registry(for: address),
            policies: t8Policies(action: .approve),
            elicitation: InMemoryElicitationBackend(),
            credentials: MCPCredentialResolver.broker(broker, refs: { _ in [ref] }),
            transport: T8Transport(box: box, script: [.success("t8-ok")]),
            audit: box.sink
        )
        let result = try await invoker.invoke(
            addressLiteral: address.literal,
            argumentsJSON: "{}",
            session: t8Session(),
            ctx: t8Context(),
            options: ScopedInvokeOptions(idempotent: true)
        )
        #expect(result.body == "t8-ok")
    }

    @Test func isOpaqueFalseOnTypedErrors() throws {
        #expect(ScopedInvokeError.principalRequired.isOpaque == false)
        #expect(ScopedInvokeError.elicitationTimeout.isOpaque == false)
    }

    @Test func auditPrincipalRejectsBadUUID() throws {
        let json = "{\"definitionID\":\"t8\",\"instanceID\":\"not-a-uuid\",\"ownerUID\":501}"
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SecretsAuditPrincipal.self, from: Data(json.utf8))
        }
    }

    @Test func auditCauseCodableRoundtrip() throws {
        let cause = SecretsAuditCause(redacting: "label-only cause")
        let data = try JSONEncoder().encode(cause)
        #expect(try JSONDecoder().decode(SecretsAuditCause.self, from: data) == cause)
    }

    @Test func fileSinkWritesThroughToLedger() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("t8-sink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = SecretsAuditRecord.toolOutcome(
            executionID: SecretsExecutionID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            principal: SecretsAuditPrincipal(
                instanceID: AgentInstanceID(), definitionID: "t8", ownerUID: 501
            ),
            address: try t8Address(),
            decision: .succeeded,
            correlationID: SecretsCorrelationID(),
            cause: SecretsAuditCause(redacting: "ok-cause")
        )
        let sink = ScopedInvokerAuditSink.file(directory: directory)
        try await sink.append([event])
        let url = directory.appendingPathComponent(SecretsAuditPaths.fileName)
        let text = try #require(String(data: FileManager.default.contents(atPath: url.path) ?? Data(), encoding: .utf8))
        let line = try #require(text.split(separator: "\n").map(String.init).first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(SecretsAuditRecord.self, from: Data(line.utf8))
        #expect(record.kind == .toolOutcome)
        #expect(record.decision == .succeeded)
        #expect(record.cause?.redacted == "ok-cause")
        #expect(record.executionID == event.executionID)
        #expect(record.correlationID == event.correlationID)
        #expect(record.principal.definitionID == "t8")
        #expect(record.principal.ownerUID == 501)
        #expect(record.addressOrRef == .tool(try t8Address()))
    }

    @Test func ledgerFullDeniesDirectly() async throws {
        let dir = try makeInvokerTempDir(prefix: "rv-invoker-ledgerfull")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tiny = SecretsAuditRetention(maxRows: 100, maxAge: 1_000_000, maxBytes: 64, maxGenerations: 0)
        let sink = ScopedInvokerAuditSink.file(directory: dir, retention: tiny)
        await #expect(throws: SecretsLedgerError.ledgerFull) {
            try await sink.append([makeInvokerAuditEvent()])
        }
    }

    @Test func fileAuditRejectsSymlinkedAndFileDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t8-dirs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let file = root.appendingPathComponent("file")
        try Data("x".utf8).write(to: file)
        let event = SecretsAuditRecord.toolDispatch(
            executionID: SecretsExecutionID(),
            timestamp: Date(),
            principal: SecretsAuditPrincipal(
                instanceID: AgentInstanceID(), definitionID: "t8", ownerUID: 501
            ),
            address: try t8Address(),
            decision: .denied,
            correlationID: SecretsCorrelationID()
        )
        #expect(throws: SecretsLedgerError.ioFailed) {
            try SecretsLedger.append([event], directory: link, retention: .default)
        }
        #expect(throws: SecretsLedgerError.ioFailed) {
            try SecretsLedger.append([event], directory: file, retention: .default)
        }
    }

    @Test func codecRejectsNonIntegerVersion() throws {
        #expect(throws: MCPDispatchCodecError.malformed) {
            try MCPDispatchCodec.decode("{\"version\":\"2\",\"address\":\"a\",\"argsDigest\":\"b\",\"idempotencyKey\":\"c\"}")
        }
    }

    @Test func foreignCredentialErrorMapsToProviderDown() async throws {
        let box = T8Box()
        let address = try t8Address()
        let invoker = ScopedInvoker(
            registry: t8Registry(for: address),
            policies: t8Policies(action: .approve),
            elicitation: InMemoryElicitationBackend(),
            credentials: t8ForeignCredentials(),
            transport: T8Transport(box: box, script: []),
            audit: box.sink
        )
        await #expect(throws: ScopedInvokeError.credentialFailed(.providerDown("conn"))) {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
    }

    @Test func parkThrowingBackendIsUnavailable() async throws {
        let box = T8Box()
        let address = try t8Address()
        let (ref, value) = try t8Secret()
        let invoker = ScopedInvoker(
            registry: t8Registry(for: address),
            policies: t8Policies(action: .requireApproval),
            elicitation: T8ParkThrowingBackend(),
            credentials: t8Credentials(box: box, values: [ref: value]),
            transport: T8Transport(box: box, script: []),
            audit: box.sink
        )
        await #expect(throws: ScopedInvokeError.elicitationUnavailable) {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
        #expect(box.mutex.withLock { $0.credentialCalls } == 0)
    }

    @Test func consumeThrowingBackendIsUnavailable() async throws {
        let box = T8Box()
        let address = try t8Address()
        let inner = InMemoryElicitationBackend()
        let (ref, value) = try t8Secret()
        let invoker = ScopedInvoker(
            registry: t8Registry(for: address),
            policies: t8Policies(action: .requireApproval),
            elicitation: T8ConsumeThrowingBackend(inner: inner),
            credentials: t8Credentials(box: box, values: [ref: value]),
            transport: T8Transport(box: box, script: []),
            audit: box.sink
        )
        let task = Task {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
        try await t8AnswerParked(inner, decision: .approved)
        await #expect(throws: ScopedInvokeError.elicitationUnavailable) { try await task.value }
        #expect(box.mutex.withLock { $0.credentialCalls } == 0)
    }

    @Test func invokerDeadlineBeatsSlowBackend() async throws {
        let box = T8Box()
        let address = try t8Address()
        let inner = InMemoryElicitationBackend()
        let (ref, value) = try t8Secret()
        let invoker = ScopedInvoker(
            registry: t8Registry(for: address),
            policies: t8Policies(action: .requireApproval),
            elicitation: T8SlowBackend(inner: inner),
            credentials: t8Credentials(box: box, values: [ref: value]),
            transport: T8Transport(box: box, script: []),
            audit: box.sink
        )
        await #expect(throws: ScopedInvokeError.elicitationTimeout) {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true, elicitationTTLSeconds: 0.05, elicitationPollSeconds: 0.005)
            )
        }
        #expect(await inner.parkedCount == 0)
    }

    @Test func cancelDuringWaitPropagatesCancellation() async throws {
        let box = T8Box()
        let address = try t8Address()
        let backend = InMemoryElicitationBackend()
        let invoker = try t8Invoker(box: box, address: address, action: .requireApproval, elicitation: backend)
        let task = Task {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
        var parked = false
        for _ in 0..<200 {
            if await backend.parkedCount > 0 {
                parked = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(parked)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cancelThrowingSinkPropagatesCancellation() async throws {
        struct T8CancelSink {
            static var sink: ScopedInvokerAuditSink {
                ScopedInvokerAuditSink(append: { _ in throw CancellationError() })
            }
        }
        let box = T8Box()
        let address = try t8Address()
        let (ref, value) = try t8Secret()
        let invoker = ScopedInvoker(
            registry: t8Registry(for: address),
            policies: t8Policies(action: .approve),
            elicitation: InMemoryElicitationBackend(),
            credentials: t8Credentials(box: box, values: [ref: value]),
            transport: T8Transport(box: box, script: []),
            audit: T8CancelSink.sink
        )
        await #expect(throws: CancellationError.self) {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
    }

    @Test func spontaneousTransportCancellationRethrows() async throws {
        struct T8CancelTransport: MCPTransport, Sendable {
            func roundtrip(_ request: MCPTransportRequest, session: MCPTransportSession) async throws -> MCPTransportResponse {
                throw CancellationError()
            }
        }
        let box = T8Box()
        let address = try t8Address()
        let (ref, value) = try t8Secret()
        let invoker = ScopedInvoker(
            registry: t8Registry(for: address),
            policies: t8Policies(action: .approve),
            elicitation: InMemoryElicitationBackend(),
            credentials: t8Credentials(box: box, values: [ref: value]),
            transport: T8CancelTransport(),
            audit: box.sink
        )
        await #expect(throws: CancellationError.self) {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
    }

    @Test func cancellationThrowingDoublesPropagate() async throws {
        let cancelCredentials = MCPCredentialResolver(resolveConnectionValues: { _, _ in
            throw CancellationError()
        })
        struct T8CancelParkBackend: MCPElicitationBackend, Sendable {
            func park(_ prompt: MCPElicitationPrompt, ttl: TimeInterval) async throws -> MCPElicitationTicket {
                throw CancellationError()
            }

            func poll(_ ticket: MCPElicitationTicket) async -> MCPElicitationStatus {
                .canceled
            }

            func consume(_ ticket: MCPElicitationTicket) async throws -> MCPElicitationDecision {
                throw CancellationError()
            }

            func cancel(_ ticket: MCPElicitationTicket) async {}
        }
        let box = T8Box()
        let address = try t8Address()
        let (ref, value) = try t8Secret()
        let credentialed = ScopedInvoker(
            registry: t8Registry(for: address),
            policies: t8Policies(action: .approve),
            elicitation: InMemoryElicitationBackend(),
            credentials: cancelCredentials,
            transport: T8Transport(box: box, script: []),
            audit: box.sink
        )
        await #expect(throws: CancellationError.self) {
            try await credentialed.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
        let parked = ScopedInvoker(
            registry: t8Registry(for: address),
            policies: t8Policies(action: .requireApproval),
            elicitation: T8CancelParkBackend(),
            credentials: t8Credentials(box: box, values: [ref: value]),
            transport: T8Transport(box: box, script: []),
            audit: box.sink
        )
        await #expect(throws: CancellationError.self) {
            try await parked.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
        struct T8CancelConsumeBackend: MCPElicitationBackend, Sendable {
            var inner: InMemoryElicitationBackend

            func park(_ prompt: MCPElicitationPrompt, ttl: TimeInterval) async throws -> MCPElicitationTicket {
                try await inner.park(prompt, ttl: ttl)
            }

            func poll(_ ticket: MCPElicitationTicket) async -> MCPElicitationStatus {
                await inner.poll(ticket)
            }

            func consume(_ ticket: MCPElicitationTicket) async throws -> MCPElicitationDecision {
                throw CancellationError()
            }

            func cancel(_ ticket: MCPElicitationTicket) async {
                await inner.cancel(ticket)
            }
        }
        let inner = InMemoryElicitationBackend()
        let consuming = ScopedInvoker(
            registry: t8Registry(for: address),
            policies: t8Policies(action: .requireApproval),
            elicitation: T8CancelConsumeBackend(inner: inner),
            credentials: t8Credentials(box: box, values: [ref: value]),
            transport: T8Transport(box: box, script: []),
            audit: box.sink
        )
        let task = Task {
            try await consuming.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: true)
            )
        }
        try await t8AnswerParked(inner, decision: .approved)
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func slowTransportTimesOutToOpaque() async throws {
        struct T8SleepTransport: MCPTransport, Sendable {
            func roundtrip(_ request: MCPTransportRequest, session: MCPTransportSession) async throws -> MCPTransportResponse {
                try await Task.sleep(for: .seconds(5))
                return MCPTransportResponse(body: "too-late")
            }
        }
        let box = T8Box()
        let address = try t8Address()
        let (ref, value) = try t8Secret()
        let invoker = ScopedInvoker(
            registry: t8Registry(for: address),
            policies: t8Policies(action: .approve),
            elicitation: InMemoryElicitationBackend(),
            credentials: t8Credentials(box: box, values: [ref: value]),
            transport: T8SleepTransport(),
            audit: box.sink
        )
        do {
            try await invoker.invoke(
                addressLiteral: address.literal,
                argumentsJSON: "{}",
                session: t8Session(),
                ctx: t8Context(),
                options: ScopedInvokeOptions(idempotent: false, transportTimeoutSeconds: 0.05)
            )
            Issue.record("expected opaque defect")
        } catch let error as ScopedInvokeError {
            #expect(error.isOpaque)
        }
    }

    @Test func filePathOnlyValuesInvokeWithoutAuthHeader() async throws {
        final class T8SeenBox: Sendable {
            let mutex = Mutex<MCPTransportAuthorization??>(nil)
        }
        struct T8CaptureTransport: MCPTransport, Sendable {
            var seen: T8SeenBox

            func roundtrip(_ request: MCPTransportRequest, session: MCPTransportSession) async throws -> MCPTransportResponse {
                seen.mutex.withLock { $0 = .some(request.authorization) }
                return MCPTransportResponse(body: "t8-ok")
            }
        }
        let box = T8Box()
        let address = try t8Address()
        let ref = try SecretRef(provider: "file", item: "key", field: nil)
        let seen = T8SeenBox()
        let invoker = ScopedInvoker(
            registry: t8Registry(for: address),
            policies: t8Policies(action: .approve),
            elicitation: InMemoryElicitationBackend(),
            credentials: t8Credentials(box: box, values: [ref: .filePath("/tmp/staged-key")]),
            transport: T8CaptureTransport(seen: seen),
            audit: box.sink
        )
        let result = try await invoker.invoke(
            addressLiteral: address.literal,
            argumentsJSON: "{}",
            session: t8Session(),
            ctx: t8Context(),
            options: ScopedInvokeOptions(idempotent: true)
        )
        #expect(result.body == "t8-ok")
        let captured = seen.mutex.withLock { $0 }
        #expect(captured != nil)
        #expect(captured! == nil)
    }
}

// MARK: - Transport edges

@Suite struct ScopedInvokerTransportEdgeTests {
    @Test func routerRejectsGetAndWrongPath() async throws {
        let session = t8Session()
        let router = MCPInMemoryRouter(handler: { _ in MCPTransportResponse(body: "must-not-run") })
        await router.register(session)
        let get = await router.handleHTTP(
            MCPHTTPRequest(method: .get, url: "http://127.0.0.1:18080/mcp/invoke", headers: [:], body: Data())
        )
        #expect(get.status == 400)
        let wrongPath = await router.handleHTTP(
            MCPHTTPRequest(method: .post, url: "http://127.0.0.1:18080/other", headers: [:], body: Data())
        )
        #expect(wrongPath.status == 400)
    }

    @Test func routerRejectsGarbageBodyAndMissingHeaders() async throws {
        let session = t8Session()
        let router = MCPInMemoryRouter(handler: { _ in MCPTransportResponse(body: "must-not-run") })
        await router.register(session)
        let garbage = await router.handleHTTP(
            MCPHTTPRequest(
                method: .post,
                url: "http://127.0.0.1:18080/mcp/invoke",
                headers: [
                    MCPStreamableHTTPClient.sessionHeader: session.id.rawValue.uuidString,
                    MCPStreamableHTTPClient.authorizationHeader: "Bearer \(session.callerToken.rawValue)",
                ],
                body: Data("not-json".utf8)
            )
        )
        #expect(garbage.status == 400)
        let noSession = await router.handleHTTP(
            MCPHTTPRequest(method: .post, url: "http://127.0.0.1:18080/mcp/invoke", headers: [:], body: Data())
        )
        #expect(noSession.status == 404)
        let noAuth = await router.handleHTTP(
            MCPHTTPRequest(
                method: .post,
                url: "http://127.0.0.1:18080/mcp/invoke",
                headers: [MCPStreamableHTTPClient.sessionHeader: session.id.rawValue.uuidString],
                body: Data()
            )
        )
        #expect(noAuth.status == 401)
    }

    @Test func routerHandlerFailureIs500WithCauseAndTrace() async throws {
        final class T8CauseBox: Sendable {
            let mutex = Mutex<[String]>([])
        }
        let causes = T8CauseBox()
        let session = t8Session()
        let router = MCPInMemoryRouter(
            handler: { _ in throw T8ForeignError() },
            causeLog: { line in causes.mutex.withLock { $0.append(line) } }
        )
        await router.register(session)
        let address = try t8Address()
        let response = await router.handleHTTP(
            MCPHTTPRequest(
                method: .post,
                url: "http://127.0.0.1:18080/mcp/invoke",
                headers: [
                    MCPStreamableHTTPClient.sessionHeader: session.id.rawValue.uuidString,
                    MCPStreamableHTTPClient.authorizationHeader: "Bearer \(session.callerToken.rawValue)",
                ],
                body: MCPMessageEnvelope(resource: "conn", address: address.literal, arguments: "{}", idempotencyKey: "k-1").encoded()!
            )
        )
        #expect(response.status == 500)
        let body = try #require(String(data: response.body, encoding: .utf8))
        #expect(MCPHTTPErrorBody.traceID(from: body) != nil)
        #expect(MCPHTTPErrorBody.traceID(from: "garbage") == nil)
        #expect(causes.mutex.withLock { $0.count } == 1)
    }

    @Test func routerDefaultCauseLogAndOversizeReply() async throws {
        let session = t8Session()
        let failing = MCPInMemoryRouter(handler: { _ in throw T8ForeignError() })
        await failing.register(session)
        let address = try t8Address()
        let request = MCPHTTPRequest(
            method: .post,
            url: "http://127.0.0.1:18080/mcp/invoke",
            headers: [
                MCPStreamableHTTPClient.sessionHeader: session.id.rawValue.uuidString,
                MCPStreamableHTTPClient.authorizationHeader: "Bearer \(session.callerToken.rawValue)",
            ],
            body: MCPMessageEnvelope(resource: "conn", address: address.literal, arguments: "{}", idempotencyKey: "k-1").encoded()!
        )
        #expect(await failing.handleHTTP(request).status == 500)
        let huge = MCPInMemoryRouter(handler: { _ in
            MCPTransportResponse(body: String(repeating: "x", count: MCPMessageEnvelope.maximumBytes + 1))
        })
        await huge.register(session)
        #expect(await huge.handleHTTP(request).status == 400)
    }

    @Test func routerUnregisterDropsSession() async throws {
        let session = t8Session()
        let router = MCPInMemoryRouter(handler: { _ in MCPTransportResponse(body: "must-not-run") })
        await router.register(session)
        await router.unregister(session.id)
        let response = await router.handleHTTP(
            MCPHTTPRequest(
                method: .post,
                url: "http://127.0.0.1:18080/mcp/invoke",
                headers: [
                    MCPStreamableHTTPClient.sessionHeader: session.id.rawValue.uuidString,
                    MCPStreamableHTTPClient.authorizationHeader: "Bearer \(session.callerToken.rawValue)",
                ],
                body: Data()
            )
        )
        #expect(response.status == 404)
    }

    @Test func typedTransportErrorsRethrowUnchanged() async throws {
        let session = t8Session(kind: .stdio)
        let address = try t8Address()
        let request = MCPTransportRequest(address: address, argumentsJSON: "{}", idempotencyKey: "k-1")
        let stdio = MCPStdioChannel(session: session, send: { _ in throw MCPTransportError.requestTimeout })
        try await stdio.start()
        await #expect(throws: MCPTransportError.requestTimeout) {
            try await MCPStdioTransport(channel: stdio).roundtrip(request, session: session)
        }
        let http = MCPStreamableHTTPClient(baseURL: "http://127.0.0.1:18080", send: { _ in throw MCPTransportError.requestTimeout })
        await #expect(throws: MCPTransportError.requestTimeout) {
            try await http.roundtrip(request, session: t8Session())
        }
    }

    @Test func stdioForeignErrorAndBadReply() async throws {
        let session = t8Session(kind: .stdio)
        let address = try t8Address()
        let request = MCPTransportRequest(address: address, argumentsJSON: "{}", idempotencyKey: "k-1")
        let failing = MCPStdioChannel(session: session, send: { _ in throw T8ForeignError() })
        try await failing.start()
        let failingTransport = MCPStdioTransport(channel: failing)
        await #expect(throws: MCPTransportError.remoteFailed(status: 0)) {
            try await failingTransport.roundtrip(request, session: session)
        }
        let binary = MCPStdioChannel(session: session, send: { _ in Data([0xff, 0xfe]) })
        try await binary.start()
        let binaryTransport = MCPStdioTransport(channel: binary)
        await #expect(throws: MCPTransportError.malformedEnvelope) {
            try await binaryTransport.roundtrip(request, session: session)
        }
    }

    @Test func httpForeignErrorAndStatusMapping() async throws {
        let address = try t8Address()
        let request = MCPTransportRequest(address: address, argumentsJSON: "{}", idempotencyKey: "k-1")
        let failing = MCPStreamableHTTPClient(baseURL: "http://127.0.0.1:18080", send: { _ in throw T8ForeignError() })
        await #expect(throws: MCPTransportError.remoteFailed(status: 0)) {
            try await failing.roundtrip(request, session: t8Session())
        }
        let badBody = MCPStreamableHTTPClient(baseURL: "http://127.0.0.1:18080", send: { _ in
            MCPHTTPResponse(status: 200, headers: [:], body: Data([0xff]))
        })
        await #expect(throws: MCPTransportError.malformedEnvelope) {
            try await badBody.roundtrip(request, session: t8Session())
        }
        for (status, error) in [
            (400, MCPTransportError.malformedEnvelope),
            (408, MCPTransportError.requestTimeout),
            (418, MCPTransportError.remoteFailed(status: 418)),
        ] {
            let client = MCPStreamableHTTPClient(baseURL: "http://127.0.0.1:18080", send: { _ in
                MCPHTTPResponse(status: status, headers: [:], body: Data())
            })
            await #expect(throws: error) {
                try await client.roundtrip(request, session: t8Session())
            }
        }
    }
}
