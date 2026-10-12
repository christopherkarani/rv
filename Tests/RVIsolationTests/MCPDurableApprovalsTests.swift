import Foundation
import RVDomain
import RVPolicy
import Synchronization
import Testing
@testable import RVIsolation

// MARK: - X1-R helpers

private struct X1RBoom: Error {}

private struct X1RLeakyBoom: Error, CustomStringConvertible {
    var description: String { "refused: api_key=supersecret123" }
}

private struct X1RHostileBoom: Error, CustomStringConvertible {
    var text: String
    var description: String { text }
}

private final class X1RClock: Sendable {
    private let mutex: Mutex<Date>

    init(at date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.mutex = Mutex(date)
    }

    func now() -> Date {
        mutex.withLock { $0 }
    }

    func advance(by interval: TimeInterval) {
        mutex.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}

private func x1rTempDir() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("x1r-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func x1rIdentity() -> ApprovalIdentity {
    ApprovalIdentity(session: SessionID(validating: "x1r-session")!, agent: .opencode)
}

private func x1rForeignIdentity() -> ApprovalIdentity {
    ApprovalIdentity(session: SessionID(validating: "x1r-stranger")!, agent: .pi)
}

private func x1rPrompt(
    address: String = "tools.demo.org.main.echo",
    matchedPattern: String = "policy:test",
    preview: String = #"{"k":"v"}"#,
    key: String = "idem-1"
) -> MCPElicitationPrompt {
    MCPElicitationPrompt(
        address: address,
        matchedPattern: matchedPattern,
        argumentPreview: preview,
        idempotencyKey: key
    )
}

/// Scriptable `PendingApprovalCoordinating`: pure-ledger records plus a
/// per-method failure injector. Every method fails only with
/// `PendingApprovalError` (the protocol has no untyped channel).
private actor X1RFakeCoordinator: PendingApprovalCoordinating {
    private var records: [PendingApproval] = []
    private var createError: PendingApprovalError?
    private var listError: PendingApprovalError?
    private var loadError: PendingApprovalError?
    private var resolveError: PendingApprovalError?
    private var cancelError: PendingApprovalError?
    private var consumeError: PendingApprovalError?
    private var cancelAttempts = 0

    func setCreateError(_ error: PendingApprovalError?) { createError = error }
    func setListError(_ error: PendingApprovalError?) { listError = error }
    func setLoadError(_ error: PendingApprovalError?) { loadError = error }
    func setResolveError(_ error: PendingApprovalError?) { resolveError = error }
    func setCancelError(_ error: PendingApprovalError?) { cancelError = error }
    func setConsumeError(_ error: PendingApprovalError?) { consumeError = error }

    func recordCount() -> Int { records.count }
    func cancelsAttempted() -> Int { cancelAttempts }
    func record(id: ApprovalID) -> PendingApproval? { records.first { $0.id == id } }

    func create(_ request: PendingApprovalRequest, now: Date) async throws(PendingApprovalError) -> PendingApproval {
        if let error = createError { throw error }
        let (record, next) = try PendingApprovalLedger.create(records: records, request: request, now: now)
        records = next
        return record
    }

    func list(now: Date) async throws(PendingApprovalError) -> [PendingApproval] {
        if let error = listError { throw error }
        let swept = PendingApprovalLedger.sweep(records, now: now)
        records = swept
        return PendingApprovalLedger.awaitingHuman(swept, now: now)
    }

    func load(id: ApprovalID, now: Date) async throws(PendingApprovalError) -> PendingApproval {
        if let error = loadError { throw error }
        let (record, next) = try PendingApprovalLedger.record(in: records, id: id, now: now)
        records = next
        return record
    }

    func resolve(
        id: ApprovalID,
        decision: ApprovalDecision,
        fingerprint: ActionFingerprint,
        identity: ApprovalIdentity,
        now: Date
    ) async throws(PendingApprovalError) -> PendingApproval {
        if let error = resolveError { throw error }
        let (record, next) = try PendingApprovalLedger.resolve(
            records: records, id: id, decision: decision,
            fingerprint: fingerprint, identity: identity, now: now
        )
        records = next
        return record
    }

    func expire(id: ApprovalID, now: Date) async throws(PendingApprovalError) -> PendingApproval {
        let (record, next) = try PendingApprovalLedger.expire(records: records, id: id, now: now)
        records = next
        return record
    }

    func cancel(id: ApprovalID, now: Date) async throws(PendingApprovalError) -> PendingApproval {
        cancelAttempts += 1
        if let error = cancelError { throw error }
        let (record, next) = try PendingApprovalLedger.cancel(records: records, id: id, now: now)
        records = next
        return record
    }

    func consume(
        id: ApprovalID,
        fingerprint: ActionFingerprint,
        identity: ApprovalIdentity,
        now: Date
    ) async throws(PendingApprovalError) -> ApprovalConsumption {
        if let error = consumeError { throw error }
        let (consumption, next) = try PendingApprovalLedger.consume(
            records: records, id: id, fingerprint: fingerprint, identity: identity, now: now
        )
        records = next
        return consumption
    }

    func events() async -> AsyncStream<PendingApprovalEvent> {
        AsyncStream { $0.finish() }
    }
}

private func x1rSeedRequest(
    id: String,
    identity: ApprovalIdentity,
    fingerprint: String,
    continuation: ApprovalContinuation,
    ttl: TimeInterval = 900
) -> PendingApprovalRequest {
    PendingApprovalRequest(
        id: ApprovalID(rawValue: id),
        identity: identity,
        action: .shell(.effectOnly(EffectShell(fingerprint: ActionFingerprint(rawValue: fingerprint)))),
        reason: .hostAsk,
        continuation: continuation,
        timeoutPolicy: .failTask,
        ttl: ttl
    )
}

// MARK: - Source, prompt wrapper, handler, decline payload

@Suite("X1-R source and handler seam")
struct X1RSourceTests {
    @Test func absentSourceReadsAsTool() {
        #expect(MCPApprovalPrompt(prompt: x1rPrompt()).effectiveSource == .tool)
        #expect(MCPApprovalPrompt(prompt: x1rPrompt(), source: nil).effectiveSource == .tool)
    }

    @Test func explicitSourcePassesThrough() {
        #expect(MCPApprovalPrompt(prompt: x1rPrompt(), source: .policy).effectiveSource == .policy)
        #expect(MCPApprovalPrompt(prompt: x1rPrompt(), source: .tool).effectiveSource == .tool)
    }

    @Test func missingSourceKeyDecodesToTool() throws {
        let text = #"{"prompt":{"address":"a","matchedPattern":"m","argumentPreview":"p","idempotencyKey":"k"}}"#
        let decoded = try JSONDecoder().decode(MCPApprovalPrompt.self, from: Data(text.utf8))
        #expect(decoded.source == nil)
        #expect(decoded.effectiveSource == .tool)
    }

    @Test func sourceRoundTripsOnTheWire() throws {
        for source in [MCPElicitationSource.policy, .tool] {
            let prompt = MCPApprovalPrompt(prompt: x1rPrompt(), source: source)
            let data = try JSONEncoder().encode(prompt)
            let decoded = try JSONDecoder().decode(MCPApprovalPrompt.self, from: data)
            #expect(decoded == prompt)
        }
    }

    @Test func acceptAllAcceptsPolicyButNeverTool() async throws {
        let policy = MCPApprovalPrompt(prompt: x1rPrompt(), source: .policy)
        let tool = MCPApprovalPrompt(prompt: x1rPrompt(), source: .tool)
        let absent = MCPApprovalPrompt(prompt: x1rPrompt(), source: nil)
        #expect(try await MCPApprovalHandler.acceptAll.resolve(policy) == .accept)
        #expect(try await MCPApprovalHandler.acceptAll.resolve(tool) == .decline)
        #expect(try await MCPApprovalHandler.acceptAll.resolve(absent) == .decline)
    }

    @Test func customHandlerPassesThrough() async throws {
        for answer in [MCPApprovalResponse.accept, .decline, .cancel] {
            let handler = MCPApprovalHandler.handler { _ in answer }
            #expect(try await handler.resolve(MCPApprovalPrompt(prompt: x1rPrompt())) == answer)
        }
    }

    @Test func declineMessageNamesAddress() {
        let error = MCPApprovalDeclinedError(address: "tools.demo.org.main.echo", action: .decline)
        #expect(error.message == "Tool approval declined: tools.demo.org.main.echo")
    }

    @Test func cancelMessageUsesExecutorSpelling() {
        let error = MCPApprovalDeclinedError(address: "tools.demo.org.main.echo", action: .cancel)
        #expect(error.message == "Tool approval cancelled: tools.demo.org.main.echo")
    }
}

// MARK: - Envelope codec

@Suite("X1-R prompt envelope")
struct X1REnvelopeTests {
    @Test func roundTripPreservesEveryField() {
        let envelope = MCPDurablePromptEnvelope(
            address: "tools.demo.org.main.echo",
            matchedPattern: "policy:abc",
            argumentPreview: #"{"a":1,"b":"x:y\n🔥"}"#,
            idempotencyKey: "idem-9",
            source: .policy
        )
        #expect(MCPDurablePromptEnvelope.decode(envelope.encoded()) == envelope)
        #expect(envelope.prompt() == MCPElicitationPrompt(
            address: "tools.demo.org.main.echo",
            matchedPattern: "policy:abc",
            argumentPreview: #"{"a":1,"b":"x:y\n🔥"}"#,
            idempotencyKey: "idem-9"
        ))
    }

    @Test func roundTripPreservesNilAndToolSource() {
        let absent = MCPDurablePromptEnvelope(
            address: "a", matchedPattern: "m", argumentPreview: "p",
            idempotencyKey: "k", source: nil
        )
        #expect(MCPDurablePromptEnvelope.decode(absent.encoded()) == absent)
        let tool = MCPDurablePromptEnvelope(
            address: "a", matchedPattern: "m", argumentPreview: "p",
            idempotencyKey: "k", source: .tool
        )
        #expect(MCPDurablePromptEnvelope.decode(tool.encoded()) == tool)
    }

    @Test func emptyFieldsRoundTrip() {
        let envelope = MCPDurablePromptEnvelope(
            address: "", matchedPattern: "", argumentPreview: "",
            idempotencyKey: "", source: nil
        )
        #expect(MCPDurablePromptEnvelope.decode(envelope.encoded()) == envelope)
    }

    @Test func badPrefixFails() {
        #expect(MCPDurablePromptEnvelope.decode("xxx1:1:a:1:b:1:c:1:d:0:") == nil)
        #expect(MCPDurablePromptEnvelope.decode("") == nil)
    }

    @Test func truncatedTokenFails() {
        #expect(MCPDurablePromptEnvelope.decode("mcp1") == nil)
        let full = MCPDurablePromptEnvelope(
            address: "tools.demo.org.main.echo", matchedPattern: "policy:test",
            argumentPreview: "preview", idempotencyKey: "idem-1", source: .policy
        ).encoded()
        #expect(MCPDurablePromptEnvelope.decode(String(full.prefix(10))) == nil)
        #expect(MCPDurablePromptEnvelope.decode(String(full.prefix(full.count - 1))) == nil)
    }

    @Test func missingSeparatorFails() {
        #expect(MCPDurablePromptEnvelope.decode("mcp1X:1:a") == nil)
    }

    @Test func unterminatedCountFails() {
        #expect(MCPDurablePromptEnvelope.decode("mcp1:12") == nil)
    }

    @Test func badCountFails() {
        #expect(MCPDurablePromptEnvelope.decode("mcp1:x:ab") == nil)
        #expect(MCPDurablePromptEnvelope.decode("mcp1::ab") == nil)
        #expect(MCPDurablePromptEnvelope.decode("mcp1:-1:a") == nil)
    }

    @Test func shortBodyFails() {
        #expect(MCPDurablePromptEnvelope.decode("mcp1:5:ab") == nil)
    }

    @Test func splitCharacterFails() {
        #expect(MCPDurablePromptEnvelope.decode("mcp1:1:é:1:b:1:c:1:d:0:") == nil)
    }

    @Test func trailingGarbageFails() {
        let full = MCPDurablePromptEnvelope(
            address: "a", matchedPattern: "m", argumentPreview: "p",
            idempotencyKey: "k", source: .policy
        ).encoded()
        #expect(MCPDurablePromptEnvelope.decode(full + "ZZ") == nil)
    }

    @Test func unknownSourceReadsAsAbsent() {
        let decoded = MCPDurablePromptEnvelope.decode("mcp1:1:a:1:b:1:c:1:d:7:unknown")
        #expect(decoded?.source == nil)
        #expect(decoded?.address == "a")
        #expect(decoded?.idempotencyKey == "d")
    }
}

// MARK: - Mapping units

@Suite("X1-R state and error mappings")
struct X1RMappingTests {
    private var now: Date { Date(timeIntervalSince1970: 1_700_000_000) }

    @Test func awaitingMapsToWaiting() {
        #expect(MCPDurableApprovalBackend.status(for: .awaitingHuman) == .waiting)
    }

    @Test func resolvedMapsByAuthority() {
        #expect(MCPDurableApprovalBackend.status(for: .resolved(.init(decision: .allowOnce, resolvedAt: now))) == .approved)
        #expect(MCPDurableApprovalBackend.status(for: .resolved(.init(decision: .createRule, resolvedAt: now))) == .approved)
        #expect(MCPDurableApprovalBackend.status(for: .resolved(.init(decision: .deny, resolvedAt: now))) == .declined)
    }

    @Test func consumedMapsByAuthority() {
        #expect(MCPDurableApprovalBackend.status(for: .consumed(.init(decision: .allowOnce, resolvedAt: now), at: now)) == .approved)
        #expect(MCPDurableApprovalBackend.status(for: .consumed(.init(decision: .deny, resolvedAt: now), at: now)) == .declined)
    }

    @Test func terminalStatesMapDistinctlyExceptTimeoutCollapse() {
        #expect(MCPDurableApprovalBackend.status(for: .expired(at: now)) == .expired)
        #expect(MCPDurableApprovalBackend.status(for: .canceled(at: now)) == .canceled)
        #expect(MCPDurableApprovalBackend.status(for: .timedOut(.init(policy: .failTask, at: now))) == .expired)
        #expect(MCPDurableApprovalBackend.status(for: .timedOut(.init(policy: .autoDeny, at: now))) == .expired)
    }

    @Test func createFullAndInvalidMapToParkFull() {
        #expect(MCPDurableApprovalBackend.mapCreateError(.storeFull) as? MCPElicitationError == .parkFull)
        #expect(MCPDurableApprovalBackend.mapCreateError(.invalidRequest) as? MCPElicitationError == .parkFull)
    }

    @Test func createOutageMapsToTypedStoreFailure() {
        let mapped = MCPDurableApprovalBackend.mapCreateError(.lockFailed)
        #expect(mapped as? MCPDurableApprovalError == .storeFailed(.lockFailed))
    }

    @Test func consumeRaceMapsToDistinctErrors() {
        let address = "tools.demo.org.main.echo"
        #expect(MCPDurableApprovalBackend.mapConsumeStoreError(.alreadyConsumed, address: address) as? MCPElicitationError == .alreadyConsumed)
        #expect(MCPDurableApprovalBackend.mapConsumeStoreError(.expired, address: address) as? MCPDurableApprovalError == .expired(address: address))
        #expect(MCPDurableApprovalBackend.mapConsumeStoreError(.timedOut, address: address) as? MCPDurableApprovalError == .expired(address: address))
        #expect(MCPDurableApprovalBackend.mapConsumeStoreError(.canceled, address: address) as? MCPDurableApprovalError == .canceled(address: address))
        #expect(MCPDurableApprovalBackend.mapConsumeStoreError(.notFound, address: address) as? MCPElicitationError == .unknownTicket)
        #expect(MCPDurableApprovalBackend.mapConsumeStoreError(.notResolved, address: address) as? MCPElicitationError == .unknownTicket)
        #expect(MCPDurableApprovalBackend.mapConsumeStoreError(.lockFailed, address: address) as? MCPDurableApprovalError == .storeFailed(.lockFailed))
    }
}

// MARK: - Durable flows over the real store

@Suite("X1-R durable flows")
struct X1RDurableFlowTests {
    private func rig() throws -> (PendingApprovalStore, MCPDurableApprovalBackend, X1RClock) {
        let dir = try x1rTempDir()
        let clock = X1RClock()
        let store = PendingApprovalStore(baseDirectory: dir)
        let backend = MCPDurableApprovalBackend(store: store, identity: x1rIdentity(), now: { clock.now() })
        return (store, backend, clock)
    }

    @Test func approveFlow() async throws {
        let (_, backend, _) = try rig()
        let prompt = x1rPrompt()
        let ticket = try await backend.park(prompt, ttl: 600)
        #expect(ticket.idempotencyKey == prompt.idempotencyKey)
        #expect(await backend.poll(ticket) == .waiting)
        try await backend.resolve(ticket, decision: .approved)
        #expect(await backend.poll(ticket) == .approved)
        #expect(try await backend.consume(ticket) == .approved)
    }

    @Test func denyFlowConsumesDurably() async throws {
        let (store, backend, clock) = try rig()
        let prompt = x1rPrompt()
        let ticket = try await backend.park(prompt, ttl: 600)
        try await backend.resolve(ticket, decision: .declined)
        #expect(await backend.poll(ticket) == .declined)
        #expect(try await backend.consume(ticket) == .declined)
        let record = try await store.load(id: ApprovalID(rawValue: ticket.id.uuidString), now: clock.now())
        guard case .consumed = record.state else {
            Issue.record("deny consume must durably mark the record consumed")
            return
        }
    }

    @Test func parkWritesExpectedRecordShape() async throws {
        let (store, backend, clock) = try rig()
        let prompt = x1rPrompt()
        let ticket = try await backend.park(prompt, ttl: 600)
        let record = try await store.load(id: ApprovalID(rawValue: ticket.id.uuidString), now: clock.now())
        #expect(record.id.rawValue == ticket.id.uuidString)
        #expect(record.identity == x1rIdentity())
        #expect(record.fingerprint.rawValue.hasPrefix("mcp:"))
        #expect(record.fingerprint.rawValue.contains(prompt.address))
        #expect(record.fingerprint.rawValue.contains(ticket.id.uuidString))
        #expect(record.reason == .hostAsk)
        #expect(record.timeoutPolicy == .failTask)
        #expect(record.state == .awaitingHuman)
        guard case .resume(let token) = record.continuation else {
            Issue.record("MCP records must carry the prompt in a resume token")
            return
        }
        let envelope = MCPDurablePromptEnvelope.decode(token.rawValue)
        #expect(envelope?.address == prompt.address)
        #expect(envelope?.matchedPattern == prompt.matchedPattern)
        #expect(envelope?.argumentPreview == prompt.argumentPreview)
        #expect(envelope?.idempotencyKey == prompt.idempotencyKey)
        #expect(envelope?.source == .policy)
    }

    @Test func consumeWaitingThrowsUnknownTicket() async throws {
        let (_, backend, _) = try rig()
        let ticket = try await backend.park(x1rPrompt(), ttl: 600)
        await #expect(throws: MCPElicitationError.unknownTicket) {
            try await backend.consume(ticket)
        }
    }

    @Test func consumeUnknownThrowsUnknownTicket() async throws {
        let (_, backend, _) = try rig()
        let ticket = MCPElicitationTicket(id: UUID(), idempotencyKey: "nope")
        await #expect(throws: MCPElicitationError.unknownTicket) {
            try await backend.consume(ticket)
        }
    }

    @Test func doubleConsumeApproveThrowsAlreadyConsumed() async throws {
        let (_, backend, _) = try rig()
        let ticket = try await backend.park(x1rPrompt(), ttl: 600)
        try await backend.resolve(ticket, decision: .approved)
        #expect(try await backend.consume(ticket) == .approved)
        await #expect(throws: MCPElicitationError.alreadyConsumed) {
            try await backend.consume(ticket)
        }
    }

    @Test func doubleConsumeDenyThrowsAlreadyConsumed() async throws {
        let (_, backend, _) = try rig()
        let ticket = try await backend.park(x1rPrompt(), ttl: 600)
        try await backend.resolve(ticket, decision: .declined)
        #expect(try await backend.consume(ticket) == .declined)
        await #expect(throws: MCPElicitationError.alreadyConsumed) {
            try await backend.consume(ticket)
        }
    }

    @Test func cancelFlowThrowsDistinctCanceled() async throws {
        let (_, backend, _) = try rig()
        let prompt = x1rPrompt()
        let ticket = try await backend.park(prompt, ttl: 600)
        await backend.cancel(ticket)
        #expect(await backend.poll(ticket) == .canceled)
        await #expect(throws: MCPDurableApprovalError.canceled(address: prompt.address)) {
            try await backend.consume(ticket)
        }
    }

    @Test func expireFlowThrowsDistinctExpired() async throws {
        let (store, backend, clock) = try rig()
        let prompt = x1rPrompt()
        let ticket = try await backend.park(prompt, ttl: 600)
        _ = try await store.expire(id: ApprovalID(rawValue: ticket.id.uuidString), now: clock.now())
        #expect(await backend.poll(ticket) == .expired)
        await #expect(throws: MCPDurableApprovalError.expired(address: prompt.address)) {
            try await backend.consume(ticket)
        }
    }

    @Test func ttlExpiryReadsExpired() async throws {
        let (_, backend, clock) = try rig()
        let prompt = x1rPrompt()
        let ticket = try await backend.park(prompt, ttl: 60)
        #expect(await backend.poll(ticket) == .waiting)
        clock.advance(by: 61)
        #expect(await backend.poll(ticket) == .expired)
        await #expect(throws: MCPDurableApprovalError.expired(address: prompt.address)) {
            try await backend.consume(ticket)
        }
    }

    @Test func nonpositiveTTLThrowsParkFullAndWritesNothing() async throws {
        let (store, backend, clock) = try rig()
        for ttl in [0.0, -5.0] {
            await #expect(throws: MCPElicitationError.parkFull) {
                try await backend.park(x1rPrompt(), ttl: ttl)
            }
        }
        #expect(try await store.list(now: clock.now()).isEmpty)
    }

    @Test func pollUnknownReadsCanceled() async throws {
        let (_, backend, _) = try rig()
        #expect(await backend.poll(MCPElicitationTicket(id: UUID(), idempotencyKey: "nope")) == .canceled)
    }

    @Test func cancelUnknownIsNoop() async throws {
        let (_, backend, _) = try rig()
        await backend.cancel(MCPElicitationTicket(id: UUID(), idempotencyKey: "nope"))
    }

    @Test func resolveUnknownIsNoop() async throws {
        let (_, backend, _) = try rig()
        try await backend.resolve(MCPElicitationTicket(id: UUID(), idempotencyKey: "nope"), decision: .approved)
    }

    @Test func resolveTerminalIsNoop() async throws {
        let (_, backend, _) = try rig()
        let approved = try await backend.park(x1rPrompt(key: "a"), ttl: 600)
        try await backend.resolve(approved, decision: .approved)
        try await backend.resolve(approved, decision: .declined)
        #expect(await backend.poll(approved) == .approved)
        let canceled = try await backend.park(x1rPrompt(key: "b"), ttl: 600)
        await backend.cancel(canceled)
        try await backend.resolve(canceled, decision: .approved)
        #expect(await backend.poll(canceled) == .canceled)
    }

    @Test func pollAfterConsumeKeepsDecision() async throws {
        let (_, backend, _) = try rig()
        let approved = try await backend.park(x1rPrompt(key: "a"), ttl: 600)
        try await backend.resolve(approved, decision: .approved)
        #expect(try await backend.consume(approved) == .approved)
        #expect(await backend.poll(approved) == .approved)
        let declined = try await backend.park(x1rPrompt(key: "b"), ttl: 600)
        try await backend.resolve(declined, decision: .declined)
        #expect(try await backend.consume(declined) == .declined)
        #expect(await backend.poll(declined) == .declined)
    }

    @Test func createRuleAuthorizesOneCall() async throws {
        let (store, backend, clock) = try rig()
        let ticket = try await backend.park(x1rPrompt(), ttl: 600)
        let id = ApprovalID(rawValue: ticket.id.uuidString)
        let loaded = try await store.load(id: id, now: clock.now())
        _ = try await store.resolve(
            id: id, decision: .createRule,
            fingerprint: loaded.fingerprint, identity: x1rIdentity(), now: clock.now()
        )
        #expect(await backend.poll(ticket) == .approved)
        #expect(try await backend.consume(ticket) == .approved)
    }

    @Test func backendServesThroughTheProtocol() async throws {
        let (_, backend, _) = try rig()
        let existential: any MCPElicitationBackend = backend
        let prompt = x1rPrompt()
        let ticket = try await existential.park(prompt, ttl: 600)
        #expect(await existential.poll(ticket) == .waiting)
        try await backend.resolve(ticket, decision: .approved)
        #expect(try await existential.consume(ticket) == .approved)
        await existential.cancel(ticket)
    }
}

// MARK: - Crash recovery

@Suite("X1-R crash recovery")
struct X1RRebindTests {
    private func rig() throws -> (URL, X1RClock) {
        (try x1rTempDir(), X1RClock())
    }

    private func backend(store: PendingApprovalStore, identity: ApprovalIdentity, clock: X1RClock) -> MCPDurableApprovalBackend {
        MCPDurableApprovalBackend(store: store, identity: identity, now: { clock.now() })
    }

    @Test func reboundBackendSeesPendingParkFullFidelity() async throws {
        let (dir, clock) = try rig()
        let first = backend(store: PendingApprovalStore(baseDirectory: dir), identity: x1rIdentity(), clock: clock)
        let prompt = x1rPrompt(preview: #"{"tool":"echo","args":{"n":3}}"#)
        let ticket = try await first.park(prompt, source: .tool, ttl: 600, onApproval: nil)

        let rebound = backend(store: PendingApprovalStore(baseDirectory: dir), identity: x1rIdentity(), clock: clock)
        #expect(await rebound.poll(ticket) == .waiting)
        let listed = try await rebound.parkedTickets()
        #expect(listed.map(\.id) == [ticket.id])
        #expect(listed.first?.idempotencyKey == prompt.idempotencyKey)
        #expect(try await rebound.prompt(for: ticket) == MCPApprovalPrompt(prompt: prompt, source: .tool))
    }

    @Test func reboundBackendResolvesAndConsumes() async throws {
        let (dir, clock) = try rig()
        let first = backend(store: PendingApprovalStore(baseDirectory: dir), identity: x1rIdentity(), clock: clock)
        let ticket = try await first.park(x1rPrompt(), ttl: 600)

        let rebound = backend(store: PendingApprovalStore(baseDirectory: dir), identity: x1rIdentity(), clock: clock)
        try await rebound.resolve(ticket, decision: .approved)
        #expect(try await rebound.consume(ticket) == .approved)
        await #expect(throws: MCPElicitationError.alreadyConsumed) {
            try await rebound.consume(ticket)
        }
    }

    @Test func foreignIdentitySeesNothingAfterRebind() async throws {
        let (dir, clock) = try rig()
        let first = backend(store: PendingApprovalStore(baseDirectory: dir), identity: x1rIdentity(), clock: clock)
        let ticket = try await first.park(x1rPrompt(), ttl: 600)

        let stranger = backend(store: PendingApprovalStore(baseDirectory: dir), identity: x1rForeignIdentity(), clock: clock)
        #expect(await stranger.poll(ticket) == .canceled)
        #expect(try await stranger.parkedTickets().isEmpty)
        #expect(try await stranger.prompt(for: ticket) == nil)
        await #expect(throws: MCPElicitationError.unknownTicket) {
            try await stranger.consume(ticket)
        }
    }

    @Test func reboundBackendSeesTTLExpiry() async throws {
        let (dir, clock) = try rig()
        let first = backend(store: PendingApprovalStore(baseDirectory: dir), identity: x1rIdentity(), clock: clock)
        let prompt = x1rPrompt()
        let ticket = try await first.park(prompt, ttl: 60)
        clock.advance(by: 61)

        let rebound = backend(store: PendingApprovalStore(baseDirectory: dir), identity: x1rIdentity(), clock: clock)
        #expect(await rebound.poll(ticket) == .expired)
        #expect(try await rebound.parkedTickets().isEmpty)
        await #expect(throws: MCPDurableApprovalError.expired(address: prompt.address)) {
            try await rebound.consume(ticket)
        }
    }

    @Test func resolvedParkSurvivesRebind() async throws {
        let (dir, clock) = try rig()
        let first = backend(store: PendingApprovalStore(baseDirectory: dir), identity: x1rIdentity(), clock: clock)
        let ticket = try await first.park(x1rPrompt(), ttl: 600)
        try await first.resolve(ticket, decision: .declined)

        let rebound = backend(store: PendingApprovalStore(baseDirectory: dir), identity: x1rIdentity(), clock: clock)
        #expect(await rebound.poll(ticket) == .declined)
        #expect(try await rebound.consume(ticket) == .declined)
    }
}

// MARK: - Concurrent consume

@Suite("X1-R concurrent consume")
struct X1RConcurrencyTests {
    @Test func concurrentApproveConsumeWinsOnce() async throws {
        let dir = try x1rTempDir()
        let clock = X1RClock()
        let backend = MCPDurableApprovalBackend(
            store: PendingApprovalStore(baseDirectory: dir), identity: x1rIdentity(), now: { clock.now() }
        )
        let ticket = try await backend.park(x1rPrompt(), ttl: 600)
        try await backend.resolve(ticket, decision: .approved)

        let outcomes = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do {
                        _ = try await backend.consume(ticket)
                        return "won"
                    } catch let error as MCPElicitationError {
                        return error == .alreadyConsumed ? "replay" : "other"
                    } catch {
                        return "other"
                    }
                }
            }
            var collected: [String] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }
        #expect(outcomes.filter { $0 == "won" }.count == 1)
        #expect(outcomes.filter { $0 == "replay" }.count == 7)
        await #expect(throws: MCPElicitationError.alreadyConsumed) {
            try await backend.consume(ticket)
        }
    }

    @Test func concurrentDenyConsumeWinsOnce() async throws {
        let dir = try x1rTempDir()
        let clock = X1RClock()
        let backend = MCPDurableApprovalBackend(
            store: PendingApprovalStore(baseDirectory: dir), identity: x1rIdentity(), now: { clock.now() }
        )
        let ticket = try await backend.park(x1rPrompt(), ttl: 600)
        try await backend.resolve(ticket, decision: .declined)

        let outcomes = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do {
                        _ = try await backend.consume(ticket)
                        return "won"
                    } catch let error as MCPElicitationError {
                        return error == .alreadyConsumed ? "replay" : "other"
                    } catch {
                        return "other"
                    }
                }
            }
            var collected: [String] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }
        #expect(outcomes.filter { $0 == "won" }.count == 1)
        #expect(outcomes.filter { $0 == "replay" }.count == 7)
    }
}

// MARK: - Handler seam matrix

@Suite("X1-R handler seam")
struct X1RHandlerSeamTests {
    private func rig(handler: MCPApprovalHandler? = nil) throws -> (MCPDurableApprovalBackend, X1RClock) {
        let dir = try x1rTempDir()
        let clock = X1RClock()
        let backend = MCPDurableApprovalBackend(
            store: PendingApprovalStore(baseDirectory: dir),
            identity: x1rIdentity(),
            defaultHandler: handler,
            now: { clock.now() }
        )
        return (backend, clock)
    }

    @Test func protocolParkUnderAcceptAllApprovesPolicyGate() async throws {
        let (backend, _) = try rig(handler: .acceptAll)
        let ticket = try await backend.park(x1rPrompt(), ttl: 600)
        #expect(await backend.poll(ticket) == .approved)
        #expect(try await backend.consume(ticket) == .approved)
    }

    @Test func sourcedPolicyUnderAcceptAllApproves() async throws {
        let (backend, _) = try rig()
        let ticket = try await backend.park(x1rPrompt(), source: .policy, ttl: 600, onApproval: .acceptAll)
        #expect(await backend.poll(ticket) == .approved)
        #expect(try await backend.consume(ticket) == .approved)
    }

    @Test func sourcedToolUnderAcceptAllDeclines() async throws {
        let (backend, _) = try rig()
        let ticket = try await backend.park(x1rPrompt(), source: .tool, ttl: 600, onApproval: .acceptAll)
        #expect(await backend.poll(ticket) == .declined)
        #expect(try await backend.consume(ticket) == .declined)
    }

    @Test func absentSourceUnderAcceptAllDeclines() async throws {
        let (backend, _) = try rig()
        let ticket = try await backend.park(x1rPrompt(), source: nil, ttl: 600, onApproval: .acceptAll)
        #expect(await backend.poll(ticket) == .declined)
    }

    @Test func perCallOverrideBeatsConstructor() async throws {
        let (backend, _) = try rig(handler: .acceptAll)
        let declined = try await backend.park(
            x1rPrompt(key: "a"), source: .policy, ttl: 600,
            onApproval: .handler { _ in .decline }
        )
        #expect(await backend.poll(declined) == .declined)
        let accepted = try await backend.park(x1rPrompt(key: "b"), source: .policy, ttl: 600, onApproval: nil)
        #expect(await backend.poll(accepted) == .approved)
    }

    @Test func perCallAcceptAllBeatsCustomConstructor() async throws {
        let (backend, _) = try rig(handler: .handler { _ in .accept })
        let ticket = try await backend.park(
            x1rPrompt(), source: .tool, ttl: 600, onApproval: .acceptAll
        )
        #expect(await backend.poll(ticket) == .declined)
    }

    @Test func constructorHandlerAppliesWithoutOverride() async throws {
        let (backend, _) = try rig(handler: .handler { _ in .decline })
        let ticket = try await backend.park(x1rPrompt(), source: .policy, ttl: 600, onApproval: nil)
        #expect(await backend.poll(ticket) == .declined)
    }

    @Test func handlerCancelAbandonsTheWait() async throws {
        let (backend, _) = try rig()
        let prompt = x1rPrompt()
        let ticket = try await backend.park(
            prompt, source: .policy, ttl: 600, onApproval: .handler { _ in .cancel }
        )
        #expect(await backend.poll(ticket) == .canceled)
        await #expect(throws: MCPDurableApprovalError.canceled(address: prompt.address)) {
            try await backend.consume(ticket)
        }
    }

    @Test func noHandlerParksForHuman() async throws {
        let (backend, _) = try rig()
        let ticket = try await backend.park(x1rPrompt(), source: .policy, ttl: 600, onApproval: nil)
        #expect(await backend.poll(ticket) == .waiting)
    }

    @Test func handlerThrowFailsTypedAndWritesNothing() async throws {
        let fake = X1RFakeCoordinator()
        let backend = MCPDurableApprovalBackend(store: fake, identity: x1rIdentity(), now: { Date(timeIntervalSince1970: 1_700_000_000) })
        await #expect(throws: MCPDurableApprovalError.handlerFailed("X1RBoom()")) {
            try await backend.park(
                x1rPrompt(), source: .policy, ttl: 600,
                onApproval: .handler { _ in throw X1RBoom() }
            )
        }
        #expect(await fake.recordCount() == 0)
    }

    @Test func handlerCancellationPropagatesUnwrapped() async throws {
        let fake = X1RFakeCoordinator()
        let backend = MCPDurableApprovalBackend(store: fake, identity: x1rIdentity(), now: { Date(timeIntervalSince1970: 1_700_000_000) })
        do {
            _ = try await backend.park(
                x1rPrompt(), source: .policy, ttl: 600,
                onApproval: .handler { _ in throw CancellationError() }
            )
            Issue.record("expected CancellationError")
        } catch is CancellationError {
        } catch {
            Issue.record("cancellation must not wrap, got \(error)")
        }
        #expect(await fake.recordCount() == 0)
    }
}

// MARK: - Failure injection

@Suite("X1-R failure injection")
struct X1RFailureInjectionTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func rig() -> (X1RFakeCoordinator, MCPDurableApprovalBackend) {
        let fake = X1RFakeCoordinator()
        let backend = MCPDurableApprovalBackend(store: fake, identity: x1rIdentity(), now: { Self.now })
        return (fake, backend)
    }

    @Test func parkCreateFailureThrowsTyped() async throws {
        let (fake, backend) = rig()
        await fake.setCreateError(.lockFailed)
        await #expect(throws: MCPDurableApprovalError.storeFailed(.lockFailed)) {
            try await backend.park(x1rPrompt(), ttl: 600)
        }
    }

    @Test func parkStoreFullThrowsParkFull() async throws {
        let (fake, backend) = rig()
        await fake.setCreateError(.storeFull)
        await #expect(throws: MCPElicitationError.parkFull) {
            try await backend.park(x1rPrompt(), ttl: 600)
        }
    }

    @Test func consumeLoadFailureThrowsTyped() async throws {
        let (fake, backend) = rig()
        let ticket = try await backend.park(x1rPrompt(), ttl: 600)
        await fake.setLoadError(.lockFailed)
        await #expect(throws: MCPDurableApprovalError.storeFailed(.lockFailed)) {
            try await backend.consume(ticket)
        }
    }

    @Test func pollLoadFailureReadsCanceled() async throws {
        let (fake, backend) = rig()
        let ticket = try await backend.park(x1rPrompt(), ttl: 600)
        await fake.setLoadError(.lockFailed)
        #expect(await backend.poll(ticket) == .canceled)
        await fake.setLoadError(nil)
        #expect(await backend.poll(ticket) == .waiting)
    }

    @Test func handlerTransitionFailureCancelsOrphanAndThrowsTyped() async throws {
        let (fake, backend) = rig()
        await fake.setResolveError(.lockFailed)
        await #expect(throws: MCPDurableApprovalError.storeFailed(.lockFailed)) {
            try await backend.park(
                x1rPrompt(), source: .policy, ttl: 600,
                onApproval: .handler { _ in .accept }
            )
        }
        #expect(await fake.cancelsAttempted() == 1)
        #expect(await fake.recordCount() == 1)
    }

    @Test func handlerTransitionFailureWithDeadCancelStillThrowsTyped() async throws {
        let (fake, backend) = rig()
        await fake.setResolveError(.lockFailed)
        await fake.setCancelError(.lockFailed)
        await #expect(throws: MCPDurableApprovalError.storeFailed(.lockFailed)) {
            try await backend.park(
                x1rPrompt(), source: .policy, ttl: 600,
                onApproval: .handler { _ in .accept }
            )
        }
        #expect(await fake.cancelsAttempted() == 1)
        #expect(await fake.recordCount() == 1)
    }

    @Test func resolveLoadFailureThrowsTyped() async throws {
        let (fake, backend) = rig()
        let ticket = try await backend.park(x1rPrompt(), ttl: 600)
        await fake.setLoadError(.encodeFailed)
        await #expect(throws: MCPDurableApprovalError.storeFailed(.encodeFailed)) {
            try await backend.resolve(ticket, decision: .approved)
        }
    }

    @Test func resolveRaceToTerminalIsSilent() async throws {
        let (fake, backend) = rig()
        let ticket = try await backend.park(x1rPrompt(), ttl: 600)
        await fake.setResolveError(.alreadyResolved)
        try await backend.resolve(ticket, decision: .approved)
    }

    @Test func resolveRaceToOutageThrowsTyped() async throws {
        let (fake, backend) = rig()
        let ticket = try await backend.park(x1rPrompt(), ttl: 600)
        await fake.setResolveError(.lockFailed)
        await #expect(throws: MCPDurableApprovalError.storeFailed(.lockFailed)) {
            try await backend.resolve(ticket, decision: .approved)
        }
    }

    @Test func denyConsumeRaceMapsToDistinctError() async throws {
        let (fake, backend) = rig()
        let ticket = try await backend.park(x1rPrompt(), ttl: 600)
        try await backend.resolve(ticket, decision: .declined)
        await fake.setConsumeError(.alreadyConsumed)
        await #expect(throws: MCPElicitationError.alreadyConsumed) {
            try await backend.consume(ticket)
        }
    }

    @Test func listingFailureThrowsTyped() async throws {
        let (fake, backend) = rig()
        _ = try await backend.park(x1rPrompt(), ttl: 600)
        await fake.setListError(.lockFailed)
        await #expect(throws: MCPDurableApprovalError.storeFailed(.lockFailed)) {
            try await backend.parkedTickets()
        }
    }

    @Test func promptLoadFailureThrowsTyped() async throws {
        let (fake, backend) = rig()
        let ticket = try await backend.park(x1rPrompt(), ttl: 600)
        let cold = MCPDurableApprovalBackend(store: fake, identity: x1rIdentity(), now: { Self.now })
        await fake.setLoadError(.lockFailed)
        await #expect(throws: MCPDurableApprovalError.storeFailed(.lockFailed)) {
            try await cold.prompt(for: ticket)
        }
    }

    @Test func cancelOutageIsSwallowed() async throws {
        let (fake, backend) = rig()
        let ticket = try await backend.park(x1rPrompt(), ttl: 600)
        await fake.setCancelError(.lockFailed)
        await backend.cancel(ticket)
        #expect(await fake.cancelsAttempted() == 1)
    }
}

// MARK: - Listing, prompts, foreign records

@Suite("X1-R listing and isolation")
struct X1RIsolationTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func rig() -> (X1RFakeCoordinator, MCPDurableApprovalBackend) {
        let fake = X1RFakeCoordinator()
        let backend = MCPDurableApprovalBackend(store: fake, identity: x1rIdentity(), now: { Self.now })
        return (fake, backend)
    }

    @Test func emptyStoreListsNothing() async throws {
        let (_, backend) = rig()
        #expect(try await backend.parkedTickets().isEmpty)
    }

    @Test func defaultClockAndHandlerServe() async throws {
        let fake = X1RFakeCoordinator()
        let backend = MCPDurableApprovalBackend(store: fake, identity: x1rIdentity())
        let ticket = try await backend.park(x1rPrompt(), ttl: 600)
        #expect(await backend.poll(ticket) == .waiting)
        #expect(try await backend.prompt(for: ticket)?.prompt == x1rPrompt())
    }

    @Test func listingFiltersForeignAndMalformed() async throws {
        let (fake, backend) = rig()
        let goodID = UUID().uuidString
        let goodToken = MCPDurablePromptEnvelope(
            address: "tools.demo.org.main.echo", matchedPattern: "policy:test",
            argumentPreview: "p", idempotencyKey: "good-key", source: .policy
        ).encoded()
        _ = try await fake.create(x1rSeedRequest(
            id: goodID, identity: x1rIdentity(),
            fingerprint: "mcp:tools.demo.org.main.echo:\(goodID)",
            continuation: .resume(ApprovalResumeToken(rawValue: goodToken))
        ), now: Self.now)
        let badTokenID = UUID().uuidString
        _ = try await fake.create(x1rSeedRequest(
            id: badTokenID, identity: x1rIdentity(),
            fingerprint: "mcp:tools.demo.org.main.echo:\(badTokenID)",
            continuation: .resume(ApprovalResumeToken(rawValue: "garbage"))
        ), now: Self.now)
        let nativeID = UUID().uuidString
        _ = try await fake.create(x1rSeedRequest(
            id: nativeID, identity: x1rIdentity(),
            fingerprint: "mcp:tools.demo.org.main.echo:\(nativeID)",
            continuation: .hostNative
        ), now: Self.now)
        _ = try await fake.create(x1rSeedRequest(
            id: UUID().uuidString, identity: x1rForeignIdentity(),
            fingerprint: "mcp:tools.demo.org.main.echo:foreign",
            continuation: .hostNative
        ), now: Self.now)
        _ = try await fake.create(x1rSeedRequest(
            id: UUID().uuidString, identity: x1rIdentity(),
            fingerprint: "shell:opencode:sess:cwd:echo",
            continuation: .hostNative
        ), now: Self.now)
        _ = try await fake.create(x1rSeedRequest(
            id: "not-a-uuid", identity: x1rIdentity(),
            fingerprint: "mcp:tools.demo.org.main.echo:bad-id",
            continuation: .hostNative
        ), now: Self.now)

        let listed = try await backend.parkedTickets()
        #expect(Set(listed.map(\.id.uuidString)) == Set([goodID, badTokenID, nativeID]))
        let keys = Dictionary(uniqueKeysWithValues: listed.map { ($0.id.uuidString, $0.idempotencyKey) })
        #expect(keys[goodID] == "good-key")
        #expect(keys[badTokenID] == "")
        #expect(keys[nativeID] == "")
    }

    @Test func resolvedParksLeaveTheListing() async throws {
        let (_, backend) = rig()
        let ticket = try await backend.park(x1rPrompt(), ttl: 600)
        #expect(try await backend.parkedTickets().map(\.id) == [ticket.id])
        try await backend.resolve(ticket, decision: .approved)
        #expect(try await backend.parkedTickets().isEmpty)
    }

    @Test func promptReadsMemoryThenStore() async throws {
        let (fake, backend) = rig()
        let prompt = x1rPrompt()
        let ticket = try await backend.park(prompt, ttl: 600)
        #expect(try await backend.prompt(for: ticket) == MCPApprovalPrompt(prompt: prompt, source: .policy))
        let cold = MCPDurableApprovalBackend(store: fake, identity: x1rIdentity(), now: { Self.now })
        #expect(try await cold.prompt(for: ticket) == MCPApprovalPrompt(prompt: prompt, source: .policy))
    }

    @Test func promptUnknownIsNil() async throws {
        let (_, backend) = rig()
        #expect(try await backend.prompt(for: MCPElicitationTicket(id: UUID(), idempotencyKey: "nope")) == nil)
    }

    @Test func promptForeignIsNil() async throws {
        let (fake, backend) = rig()
        let id = UUID().uuidString
        _ = try await fake.create(x1rSeedRequest(
            id: id, identity: x1rForeignIdentity(),
            fingerprint: "mcp:tools.demo.org.main.echo:foreign",
            continuation: .hostNative
        ), now: Self.now)
        let ticket = MCPElicitationTicket(id: UUID(uuidString: id)!, idempotencyKey: "x")
        #expect(try await backend.prompt(for: ticket) == nil)
    }

    @Test func promptUndecodableIsNil() async throws {
        let (fake, backend) = rig()
        let id = UUID().uuidString
        _ = try await fake.create(x1rSeedRequest(
            id: id, identity: x1rIdentity(),
            fingerprint: "mcp:tools.demo.org.main.echo:\(id)",
            continuation: .resume(ApprovalResumeToken(rawValue: "garbage"))
        ), now: Self.now)
        let cold = MCPDurableApprovalBackend(store: fake, identity: x1rIdentity(), now: { Self.now })
        #expect(try await cold.prompt(for: MCPElicitationTicket(id: UUID(uuidString: id)!, idempotencyKey: "x")) == nil)
    }

    @Test func pollForeignReadsCanceled() async throws {
        let (fake, backend) = rig()
        let id = UUID().uuidString
        _ = try await fake.create(x1rSeedRequest(
            id: id, identity: x1rForeignIdentity(),
            fingerprint: "mcp:tools.demo.org.main.echo:foreign",
            continuation: .hostNative
        ), now: Self.now)
        #expect(await backend.poll(MCPElicitationTicket(id: UUID(uuidString: id)!, idempotencyKey: "x")) == .canceled)
    }

    @Test func pollNonMCPReadsCanceled() async throws {
        let (fake, backend) = rig()
        let id = UUID().uuidString
        _ = try await fake.create(x1rSeedRequest(
            id: id, identity: x1rIdentity(),
            fingerprint: "shell:opencode:sess:cwd:echo",
            continuation: .hostNative
        ), now: Self.now)
        #expect(await backend.poll(MCPElicitationTicket(id: UUID(uuidString: id)!, idempotencyKey: "x")) == .canceled)
    }

    @Test func consumeForeignThrowsUnknownTicket() async throws {
        let (fake, backend) = rig()
        let id = UUID().uuidString
        _ = try await fake.create(x1rSeedRequest(
            id: id, identity: x1rForeignIdentity(),
            fingerprint: "mcp:tools.demo.org.main.echo:foreign",
            continuation: .hostNative
        ), now: Self.now)
        let ticket = MCPElicitationTicket(id: UUID(uuidString: id)!, idempotencyKey: "x")
        await #expect(throws: MCPElicitationError.unknownTicket) {
            try await backend.consume(ticket)
        }
    }

    @Test func resolveForeignIsNoop() async throws {
        let (fake, backend) = rig()
        let id = UUID().uuidString
        _ = try await fake.create(x1rSeedRequest(
            id: id, identity: x1rForeignIdentity(),
            fingerprint: "mcp:tools.demo.org.main.echo:foreign",
            continuation: .hostNative
        ), now: Self.now)
        try await backend.resolve(MCPElicitationTicket(id: UUID(uuidString: id)!, idempotencyKey: "x"), decision: .approved)
        let record = await fake.record(id: ApprovalID(rawValue: id))
        #expect(record?.state == .awaitingHuman)
    }

    @Test func corruptExpiredFallsBackToTicketID() async throws {
        let (fake, _) = rig()
        let id = UUID().uuidString
        _ = try await fake.create(x1rSeedRequest(
            id: id, identity: x1rIdentity(),
            fingerprint: "mcp:tools.demo.org.main.echo:\(id)",
            continuation: .hostNative
        ), now: Self.now)
        _ = try await fake.expire(id: ApprovalID(rawValue: id), now: Self.now)
        let cold = MCPDurableApprovalBackend(store: fake, identity: x1rIdentity(), now: { Self.now })
        let ticket = MCPElicitationTicket(id: UUID(uuidString: id)!, idempotencyKey: "x")
        await #expect(throws: MCPDurableApprovalError.expired(address: id)) {
            try await cold.consume(ticket)
        }
    }
}

// MARK: - TTL validation at the seam

@Suite("X1-R TTL validation")
struct X1RTTLValidationTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func nonFiniteTTLThrowsParkFullWithoutInvokingHandler() async throws {
        let fake = X1RFakeCoordinator()
        let backend = MCPDurableApprovalBackend(store: fake, identity: x1rIdentity(), now: { Self.now })
        for ttl in [Double.nan, Double.infinity, -Double.infinity] {
            // A throwing handler proves non-invocation: had it run, this
            // would be handlerFailed, not parkFull.
            await #expect(throws: MCPElicitationError.parkFull) {
                try await backend.park(
                    x1rPrompt(), source: .policy, ttl: ttl,
                    onApproval: .handler { _ in throw X1RBoom() }
                )
            }
        }
        #expect(await fake.recordCount() == 0)
    }

    @Test func legacyNonFiniteTTLThrowsParkFull() async throws {
        let fake = X1RFakeCoordinator()
        let backend = MCPDurableApprovalBackend(store: fake, identity: x1rIdentity(), now: { Self.now })
        for ttl in [Double.nan, Double.infinity, -Double.infinity] {
            await #expect(throws: MCPElicitationError.parkFull) {
                try await backend.park(x1rPrompt(), ttl: ttl)
            }
        }
        #expect(await fake.recordCount() == 0)
    }

    @Test func sourcedNonpositiveTTLThrowsParkFullWithoutInvokingHandler() async throws {
        let fake = X1RFakeCoordinator()
        let backend = MCPDurableApprovalBackend(store: fake, identity: x1rIdentity(), now: { Self.now })
        for ttl in [0.0, -0.0, -5.0] {
            await #expect(throws: MCPElicitationError.parkFull) {
                try await backend.park(
                    x1rPrompt(), source: .tool, ttl: ttl,
                    onApproval: .handler { _ in throw X1RBoom() }
                )
            }
        }
        #expect(await fake.recordCount() == 0)
    }

    @Test func subnormalTTLParksThenReadsExpired() async throws {
        // Least nonzero magnitude rounds to now: the park succeeds (the TTL
        // is positive and finite) and the first poll already finds it timed
        // out. Fail-closed, never an immortal wait.
        let dir = try x1rTempDir()
        let clock = X1RClock()
        let backend = MCPDurableApprovalBackend(
            store: PendingApprovalStore(baseDirectory: dir), identity: x1rIdentity(), now: { clock.now() }
        )
        let ticket = try await backend.park(x1rPrompt(), ttl: Double.leastNonzeroMagnitude)
        #expect(await backend.poll(ticket) == .expired)
    }

    @Test func hugeFiniteTTLParksAndWaits() async throws {
        // Greatest finite magnitude round-trips the real store (ISO8601
        // far-future year) and stays waiting: no crash, no bypass.
        let dir = try x1rTempDir()
        let clock = X1RClock()
        let backend = MCPDurableApprovalBackend(
            store: PendingApprovalStore(baseDirectory: dir), identity: x1rIdentity(), now: { clock.now() }
        )
        let ticket = try await backend.park(x1rPrompt(), ttl: Double.greatestFiniteMagnitude)
        #expect(await backend.poll(ticket) == .waiting)
    }
}

// MARK: - Exhaustive error mappings

@Suite("X1-R exhaustive error mappings")
struct X1RExhaustiveMappingTests {
    private static let all: [PendingApprovalError] = [
        .invalidRequest, .duplicateID, .notFound, .alreadyResolved, .expired,
        .canceled, .timedOut, .fingerprintMismatch, .identityMismatch,
        .continuationMismatch, .alreadyConsumed, .notResolved, .encodeFailed,
        .lockFailed, .storeFull,
    ]

    @Test func mapCreateErrorCoversEveryCase() {
        #expect(Self.all.count == 15)
        for error in Self.all {
            let mapped = MCPDurableApprovalBackend.mapCreateError(error)
            switch error {
            case .storeFull, .invalidRequest:
                #expect(mapped as? MCPElicitationError == .parkFull)
            case .duplicateID, .notFound, .alreadyResolved, .expired, .canceled,
                .timedOut, .fingerprintMismatch, .identityMismatch,
                .continuationMismatch, .alreadyConsumed, .notResolved,
                .encodeFailed, .lockFailed:
                #expect(mapped as? MCPDurableApprovalError == .storeFailed(error))
            }
        }
    }

    @Test func mapConsumeStoreErrorCoversEveryCase() {
        let address = "tools.demo.org.main.echo"
        for error in Self.all {
            let mapped = MCPDurableApprovalBackend.mapConsumeStoreError(error, address: address)
            switch error {
            case .alreadyConsumed:
                #expect(mapped as? MCPElicitationError == .alreadyConsumed)
            case .expired, .timedOut:
                #expect(mapped as? MCPDurableApprovalError == .expired(address: address))
            case .canceled:
                #expect(mapped as? MCPDurableApprovalError == .canceled(address: address))
            case .notFound, .notResolved:
                #expect(mapped as? MCPElicitationError == .unknownTicket)
            case .invalidRequest, .duplicateID, .alreadyResolved,
                .fingerprintMismatch, .identityMismatch, .continuationMismatch,
                .encodeFailed, .lockFailed, .storeFull:
                #expect(mapped as? MCPDurableApprovalError == .storeFailed(error))
            }
        }
    }
}

// MARK: - Resolve races

@Suite("X1-R resolve races")
struct X1RResolveRaceTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func rig() -> (X1RFakeCoordinator, MCPDurableApprovalBackend) {
        let fake = X1RFakeCoordinator()
        let backend = MCPDurableApprovalBackend(store: fake, identity: x1rIdentity(), now: { Self.now })
        return (fake, backend)
    }

    @Test func resolveTerminalRacesAreSilent() async throws {
        let (fake, backend) = rig()
        let ticket = try await backend.park(x1rPrompt(), ttl: 600)
        for error in [
            PendingApprovalError.alreadyResolved, .alreadyConsumed, .expired,
            .canceled, .timedOut,
        ] as [PendingApprovalError] {
            await fake.setResolveError(error)
            try await backend.resolve(ticket, decision: .approved)
        }
        await fake.setResolveError(nil)
        #expect(await backend.poll(ticket) == .waiting)
    }

    @Test func resolveOutageCasesStayTyped() async throws {
        let (fake, backend) = rig()
        let ticket = try await backend.park(x1rPrompt(), ttl: 600)
        for error in [
            PendingApprovalError.identityMismatch, .fingerprintMismatch, .encodeFailed,
        ] as [PendingApprovalError] {
            await fake.setResolveError(error)
            await #expect(throws: MCPDurableApprovalError.storeFailed(error)) {
                try await backend.resolve(ticket, decision: .approved)
            }
        }
    }
}

// MARK: - Handler transition failures

@Suite("X1-R handler transition failures")
struct X1RHandlerTransitionTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func handlerCancelTransitionFailureThrowsTyped() async throws {
        let fake = X1RFakeCoordinator()
        let backend = MCPDurableApprovalBackend(store: fake, identity: x1rIdentity(), now: { Self.now })
        await fake.setCancelError(.lockFailed)
        await #expect(throws: MCPDurableApprovalError.storeFailed(.lockFailed)) {
            try await backend.park(
                x1rPrompt(), source: .policy, ttl: 600,
                onApproval: .handler { _ in .cancel }
            )
        }
        #expect(await fake.cancelsAttempted() == 2)
        #expect(await fake.recordCount() == 1)
    }

    @Test func handlerSecretLeakIsRedacted() async throws {
        let fake = X1RFakeCoordinator()
        let backend = MCPDurableApprovalBackend(store: fake, identity: x1rIdentity(), now: { Self.now })
        do {
            _ = try await backend.park(
                x1rPrompt(), source: .policy, ttl: 600,
                onApproval: .handler { _ in throw X1RLeakyBoom() }
            )
            Issue.record("expected handlerFailed")
        } catch let error as MCPDurableApprovalError {
            guard case .handlerFailed(let label) = error else {
                Issue.record("expected handlerFailed, got \(error)")
                return
            }
            #expect(label.contains(ReviewSanitizer.redactedPlaceholder))
            #expect(label.contains("supersecret123") == false)
        }
        #expect(await fake.recordCount() == 0)
    }
}

// MARK: - Handler fidelity

@Suite("X1-R handler fidelity")
struct X1RHandlerFidelityTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func customHandlerReceivesPromptAndSource() async throws {
        let fake = X1RFakeCoordinator()
        let backend = MCPDurableApprovalBackend(store: fake, identity: x1rIdentity(), now: { Self.now })
        let seen = Mutex<MCPApprovalPrompt?>(nil)
        let prompt = x1rPrompt()
        let ticket = try await backend.park(
            prompt, source: .tool, ttl: 600,
            onApproval: .handler { received in
                seen.withLock { $0 = received }
                return .accept
            }
        )
        #expect(seen.withLock { $0 } == MCPApprovalPrompt(prompt: prompt, source: .tool))
        // The never-auto-accept-tools rule binds accept-all only: an explicit
        // custom handler may still accept a tool request.
        #expect(await backend.poll(ticket) == .approved)
    }
}

// MARK: - Crash exactly-once

@Suite("X1-R crash exactly-once")
struct X1RCrashExactlyOnceTests {
    @Test func denyConsumeSurvivesRebindAsAlreadyConsumed() async throws {
        let dir = try x1rTempDir()
        let clock = X1RClock()
        let first = MCPDurableApprovalBackend(
            store: PendingApprovalStore(baseDirectory: dir), identity: x1rIdentity(), now: { clock.now() }
        )
        let ticket = try await first.park(x1rPrompt(), ttl: 600)
        try await first.resolve(ticket, decision: .declined)
        #expect(try await first.consume(ticket) == .declined)

        let rebound = MCPDurableApprovalBackend(
            store: PendingApprovalStore(baseDirectory: dir), identity: x1rIdentity(), now: { clock.now() }
        )
        #expect(await rebound.poll(ticket) == .declined)
        await #expect(throws: MCPElicitationError.alreadyConsumed) {
            try await rebound.consume(ticket)
        }
    }

    @Test func allowRedeliversAfterRebindKnownWindow() async throws {
        // KNOWN WINDOW, pinned not desired: allow-consumption is
        // memory-guarded because name-only store.consume cannot deliver
        // authority, so a crash between consume and invoke re-delivers after
        // an out-of-band ticket replay. If the store ever gains a
        // durably-marked allow-consume, this test must flip to
        // alreadyConsumed and the type docs move with it.
        let dir = try x1rTempDir()
        let clock = X1RClock()
        let first = MCPDurableApprovalBackend(
            store: PendingApprovalStore(baseDirectory: dir), identity: x1rIdentity(), now: { clock.now() }
        )
        let ticket = try await first.park(x1rPrompt(), ttl: 600)
        try await first.resolve(ticket, decision: .approved)
        #expect(try await first.consume(ticket) == .approved)

        let rebound = MCPDurableApprovalBackend(
            store: PendingApprovalStore(baseDirectory: dir), identity: x1rIdentity(), now: { clock.now() }
        )
        #expect(try await rebound.consume(ticket) == .approved)
    }
}

// MARK: - Real-store tamper tolerance

@Suite("X1-R real-store tamper tolerance")
struct X1RTamperTests {
    @Test func garbageTokenRowOverRealStoreFailsClosed() async throws {
        let dir = try x1rTempDir()
        let clock = X1RClock()
        let store = PendingApprovalStore(baseDirectory: dir)
        let id = UUID().uuidString
        _ = try await store.create(x1rSeedRequest(
            id: id, identity: x1rIdentity(),
            fingerprint: "mcp:tools.demo.org.main.echo:\(id)",
            continuation: .resume(ApprovalResumeToken(rawValue: "garbage"))
        ), now: clock.now())
        let cold = MCPDurableApprovalBackend(store: store, identity: x1rIdentity(), now: { clock.now() })
        let ticket = MCPElicitationTicket(id: UUID(uuidString: id)!, idempotencyKey: "x")
        #expect(try await cold.prompt(for: ticket) == nil)
        let listed = try await cold.parkedTickets()
        #expect(listed.map(\.id) == [ticket.id])
        #expect(listed.first?.idempotencyKey == "")
        _ = try await store.expire(id: ApprovalID(rawValue: id), now: clock.now())
        await #expect(throws: MCPDurableApprovalError.expired(address: id)) {
            try await cold.consume(ticket)
        }
    }

    @Test func corruptJSONLFailsClosedAndHeals() async throws {
        let dir = try x1rTempDir()
        let clock = X1RClock()
        let store = PendingApprovalStore(baseDirectory: dir)
        let backend = MCPDurableApprovalBackend(store: store, identity: x1rIdentity(), now: { clock.now() })
        let ticket = try await backend.park(x1rPrompt(), ttl: 600)
        #expect(await backend.poll(ticket) == .waiting)
        try "garbage-not-json\n".write(
            to: RVPolicyPaths.pendingApprovalsFile(inConfigDir: dir),
            atomically: true, encoding: .utf8
        )
        #expect(await backend.poll(ticket) == .canceled)
        await #expect(throws: MCPElicitationError.unknownTicket) {
            try await backend.consume(ticket)
        }
        #expect(try await backend.parkedTickets().isEmpty)
        let healed = try await backend.park(x1rPrompt(key: "after"), ttl: 600)
        #expect(await backend.poll(healed) == .waiting)
        #expect(await backend.poll(ticket) == .canceled)
    }
}

// MARK: - Final-pass hostile handler output

@Suite("X1-R hostile handler errors")
struct X1RHostileHandlerTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func hostileHandlerOutputIsRedactedExactly() async throws {
        // Exact pins: secrets die in every spelling, while non-secret text
        // (including format-string lookalikes, which Swift never interprets,
        // and control bytes, which host code could emit directly anyway)
        // passes through byte-for-byte. A sanitizer improvement that strips
        // controls must update these pins consciously.
        let cases: [(input: String, expected: String)] = [
            ("boom Bearer ghp_deadbeef1234567890", "boom Bearer [redacted]"),
            ("password=hunter2", "password=[redacted]"),
            ("token: hunter2", "token: [redacted]"),
            ("--token hunter2", "--token [redacted]"),
            ("-----BEGIN PRIVATE KEY-----\nabcdef", "[redacted]"),
            ("%s %x %n %@ done", "%s %x %n %@ done"),
            ("evil\u{1B}[2J password=hunter2", "evil\u{1B}[2J password=[redacted]"),
            ("line1\npassword=hunter2", "line1\npassword=[redacted]"),
        ]
        for (input, expected) in cases {
            let fake = X1RFakeCoordinator()
            let backend = MCPDurableApprovalBackend(store: fake, identity: x1rIdentity(), now: { Self.now })
            do {
                _ = try await backend.park(
                    x1rPrompt(), source: .policy, ttl: 600,
                    onApproval: .handler { _ in throw X1RHostileBoom(text: input) }
                )
                Issue.record("expected handlerFailed for \(input)")
            } catch let error as MCPDurableApprovalError {
                #expect(error == .handlerFailed(expected))
            }
            #expect(await fake.recordCount() == 0)
        }
    }
}

// MARK: - Final-pass cache hygiene

@Suite("X1-R prompt cache hygiene")
struct X1RPromptCacheTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func failedTransitionStrandsNoPromptCache() async throws {
        let fake = X1RFakeCoordinator()
        let backend = MCPDurableApprovalBackend(store: fake, identity: x1rIdentity(), now: { Self.now })
        await fake.setResolveError(.lockFailed)
        await #expect(throws: MCPDurableApprovalError.storeFailed(.lockFailed)) {
            try await backend.park(
                x1rPrompt(), source: .policy, ttl: 600,
                onApproval: .handler { _ in .accept }
            )
        }
        #expect(await backend.promptCacheCount == 0)
        await fake.setResolveError(nil)
        _ = try await backend.park(
            x1rPrompt(key: "ok"), source: .policy, ttl: 600,
            onApproval: .handler { _ in .accept }
        )
        #expect(await backend.promptCacheCount == 1)
    }
}
