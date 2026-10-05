import Foundation
import Synchronization
import Testing
import RVDomain
@testable import RVIsolation

/// Scripted `ActionApprovalAsking`. No service, no XPC: drives the session
/// park/waiter/resume machinery through its exact production seam.
final class FakeAskBackend: ActionApprovalAsking, Sendable {
    struct State: Sendable {
        var creates: [(action: ProposedAction, reason: RuntimeAskReason)] = []
        var created: [CreatedActionApproval] = []
        var createDeclined = false
        /// Per-approval status scripts (FIFO; falls back to `statusDefault`).
        /// A nil entry is one transport blip (the waiter keeps polling).
        var statusScripts: [UUID: [String?]] = [:]
        var statusDefault = "pending"
        var statusCalls = 0
        /// Approvals whose consume succeeds.
        var consumable: Set<UUID> = []
        /// New approvals start consumable (set only by `authorizeAll`).
        var consumableByDefault = false
        var consumeCalls: [UUID] = []
        var cancels: [UUID] = []
        /// Runs inside `consumeApproval` before the verdict returns. Lets
        /// a test revoke the principal between spend and resume.
        var onConsume: (@Sendable (UUID) -> Void)?
    }

    private let state = Mutex(State())

    var snapshot: State { state.withLock { $0 } }

    func setStatusScript(_ script: [String?], for approvalID: UUID) {
        state.withLock { $0.statusScripts[approvalID] = script }
    }

    func setStatusDefault(_ status: String) {
        state.withLock { $0.statusDefault = status }
    }

    func setConsumable(_ approvalID: UUID) {
        state.withLock { $0.consumable.insert(approvalID) }
    }

    func setCreateDeclined(_ declined: Bool) {
        state.withLock { $0.createDeclined = declined }
    }

    func setOnConsume(_ hook: (@Sendable (UUID) -> Void)?) {
        state.withLock { $0.onConsume = hook }
    }

    /// Authorize-all: every approval reports authorized and consumes.
    func authorizeAll() {
        state.withLock {
            $0.statusDefault = "authorized"
            $0.consumableByDefault = true
            for approval in $0.created {
                $0.consumable.insert(approval.approvalID)
            }
        }
    }

    func createApproval(
        subject: RuntimeAdmissionSubject,
        action: ProposedAction,
        reason: RuntimeAskReason,
        policyContext: String
    ) -> CreatedActionApproval? {
        state.withLock { state in
            guard !state.createDeclined else { return nil }
            state.creates.append((action, reason))
            let created = CreatedActionApproval(
                approvalID: UUID(), continuationID: UUID(), subject: subject)
            state.created.append(created)
            if state.consumableByDefault {
                state.consumable.insert(created.approvalID)
            }
            return created
        }
    }

    func approvalStatus(_ approval: CreatedActionApproval) -> String? {
        state.withLock { state in
            state.statusCalls += 1
            if var script = state.statusScripts[approval.approvalID], !script.isEmpty {
                let next = script.removeFirst()
                state.statusScripts[approval.approvalID] = script
                return next
            }
            return state.statusDefault
        }
    }

    func consumeApproval(
        _ approval: CreatedActionApproval,
        actionDigestHex: String
    ) -> Bool {
        let (verdict, hook) = state.withLock { state in
            state.consumeCalls.append(approval.approvalID)
            return (state.consumable.contains(approval.approvalID), state.onConsume)
        }
        hook?(approval.approvalID)
        return verdict
    }

    func cancelApproval(_ approval: CreatedActionApproval) {
        state.withLock { $0.cancels.append(approval.approvalID) }
    }
}

private final class ParkEffect: Sendable {
    private let runsBox = Mutex(0)
    private let commandsBox = Mutex<[String]>([])
    var runs: Int { runsBox.withLock { $0 } }
    var commands: [String] { commandsBox.withLock { $0 } }

    func run(_ allowed: AllowedAction) -> Result<Int32, RuntimeAdmissionExecutorError> {
        runsBox.withLock { $0 += 1 }
        if case .shell(let shell) = allowed.action {
            commandsBox.withLock { $0.append(shell.supportingCommand?.rawValue ?? "?") }
        }
        return .success(0)
    }
}

private struct ParkHarness {
    let root: URL
    let runtime: RuntimeSession
    let capability: RuntimeCapability
    let registry: AgentInstanceRegistry
    let instance: AgentInstance
    let effect: ParkEffect
    let evidence: RuntimeAdmissionEvidence
    let backend: FakeAskBackend
    let session: RuntimeAdmissionSession

    init(backend: FakeAskBackend? = nil, parkPollInterval: TimeInterval = 0.005,
        parkTimeout: TimeInterval = 5
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-park-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = try #require(WorkingDirectory(validating: root.path))
        let plan = compileContainedPlan(workspace: workspace)
        let runtime = RuntimeSession(
            id: RuntimeSessionID(),
            workspaceSessionID: WorkspaceSessionID(),
            host: .opencode,
            workspace: workspace,
            backend: .seatbelt,
            startedAt: Date(),
            child: nil
        )
        let capability = RuntimeCapability()
        let effect = ParkEffect()
        let evidence = RuntimeAdmissionEvidence()
        let backend = backend ?? FakeAskBackend()
        let configuration = RuntimeAdmissionConfiguration(
            normalize: ParkHarness.normalize,
            executor: .effect(effect.run),
            approval: { _, _ in nil },
            policy: { _ in .empty },
            evidence: evidence,
            askBackend: backend
        )
        let definition = AgentDefinition(
            id: AgentDefinitionID(rawValue: "park-agent"),
            displayName: "Park",
            blurb: "",
            executableRequirement: ExecutableRequirement(allowsUnsigned: true),
            hookHost: .opencode,
            agentTag: "opencode",
            resourceProfile: RuntimeResourceProfile(id: "test", projects: []),
            credentialBindings: [],
            requiredAssurance: .launchObserved,
            authorityCeiling: AgentAuthority(scopes: ["shell"])
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
        let session = RuntimeAdmissionSession(
            binding: RuntimeChannelBinding(session: runtime, capability: capability),
            configuration: configuration,
            launch: AdmittedLaunchContext(
                plan: plan,
                profileSource: "(deny file-link)",
                workspacePath: workspace.rawValue
            ),
            requestRead: -1,
            responseWrite: -1,
            parkPollInterval: parkPollInterval,
            parkTimeout: parkTimeout
        )
        guard registry.announce(instance) else {
            throw ParkHarnessError.announceFailed
        }
        guard let established = EstablishedRuntimeSession(
            session: runtime, instance: instance, establishedAt: Date()),
            registry.activate(established) != nil
        else {
            throw ParkHarnessError.bindFailed
        }
        guard session.bindAgentInstance(instance.id, registry: registry) else {
            throw ParkHarnessError.bindFailed
        }
        self.root = root
        self.runtime = runtime
        self.capability = capability
        self.registry = registry
        self.instance = instance
        self.effect = effect
        self.evidence = evidence
        self.backend = backend
        self.session = session
    }

    static func normalize(
        subject: RuntimeAdmissionSubject,
        action: RuntimeRequestedAction
    ) -> Result<ProposedAction, RuntimeAdmissionEvaluationError> {
        guard case .shell(let command) = action else {
            return .failure(.failed)
        }
        let raw = command.rawValue
        if raw.contains("$") || raw.contains("`") || raw.contains("\"") || raw.contains("'") {
            return .failure(.failed)
        }
        // No effects: `echo` stays ASK (reviewAsk), like the production
        // gate for unruled commands. `touch marker` gains the create
        // effect and executes, mirroring the admission harness.
        let tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        var effects = ActionEffects(kinds: [])
        var resources = ActionResources()
        if tokens.count == 2, tokens[0] == "touch" {
            if tokens[1].hasPrefix("/") {
                effects = ActionEffects(kinds: [.filesystemOverwrite, .outsideRepositoryMutation])
                resources = ActionResources(
                    path: tokens[1], filesystemScope: .outsideRepository, resourceKind: .unknown)
            } else {
                effects = ActionEffects(kinds: [.filesystemCreate])
                resources = ActionResources(
                    path: tokens[1], filesystemScope: .insideRepository, resourceKind: .unknown)
            }
        }
        return .success(.shell(ShellAction(
            fingerprint: ActionFingerprint(
                rawValue: "runtime:\(subject.session.id.rawValue.uuidString):\(subject.policyWorkspace.rawValue):\(raw)"),
            effects: effects,
            resources: resources,
            scope: ActionScope(workingDirectory: subject.policyWorkspace),
            supportingCommand: command)))
    }

    func frame(_ command: String, id: UUID = UUID()) -> RuntimeActionFrame {
        RuntimeActionFrame(
            version: 1,
            requestID: RuntimeActionRequestID(validating: id.uuidString)!,
            capability: capability,
            claimedSession: RuntimeSessionClaim(validating: runtime.id.rawValue.uuidString)!,
            action: .shell(ShellCommand(rawValue: command))
        )
    }

    func cleanup() {
        session.finish()
        try? FileManager.default.removeItem(at: root)
    }
}

private enum ParkHarnessError: Error {
    case announceFailed
    case bindFailed
}

/// Step 6 host parking: ASKs park for a human decision and resume the exact
/// parked continuation at most once. The fake backend stands in for rvd;
/// service-side authority is pinned by the ceremony/authorizer suites.
@Suite("Action approval parking")
struct ActionApprovalParkTests {
    private func waitFor(
        _ description: String,
        // Generous: the full suite saturates the machine (40s+ individuals,
        // 200-500s suites) and any wall clock can stall; tight budgets
        // flake in the broad gate while passing in isolation in <0.1s.
        timeout: TimeInterval = 120,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                Issue.record("timeout waiting for \(description)")
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @Test func revokedParkNeverResumesExecution() async throws {
        // Step 8 (F3 re-review): a principal revoked while its ASK awaits
        // the human must not execute when the approval lands — neither
        // the poll waiter nor the resume path may run it.
        let harness = try ParkHarness()
        defer { harness.cleanup() }
        let decision = harness.session.submitLegacy(.success(harness.frame("echo hello")))
        #expect(decision.responseDeferred == true)
        #expect(harness.session.parkedApprovalCountForTesting == 1)
        #expect(
            harness.registry.revoke(harness.instance.id, reason: .explicitRevoke) { true }
                == .revoked
        )
        // The human approves anyway (stale UI): both the waiter fail-fast
        // and the resume revalidation refuse with the same cause.
        harness.backend.authorizeAll()
        await waitFor("park completion") {
            harness.session.queuedCompletionCountForTesting == 1
        }
        #expect(harness.effect.runs == 0)
        #expect(harness.session.parkedApprovalCountForTesting == 0)
        let events = harness.evidence.snapshot()
        #expect(events.contains { $0.result == "principalRevoked" })
        #expect(events.contains { $0.executionAttempted } == false)
    }

    @Test func revokeBetweenSpendAndResumeNeverExecutes() async throws {
        // Step 8 (F3 re-review): the approval is spent, then the
        // principal dies before resume runs. The resume revalidation —
        // not the poll waiter — must refuse execution.
        let backend = FakeAskBackend()
        let harness = try ParkHarness(backend: backend)
        defer { harness.cleanup() }
        backend.setOnConsume { _ in
            _ = harness.registry.revoke(harness.instance.id, reason: .explicitRevoke) { true }
        }
        backend.authorizeAll()
        let decision = harness.session.submitLegacy(.success(harness.frame("echo hello")))
        #expect(decision.responseDeferred == true)
        await waitFor("park completion") {
            harness.session.queuedCompletionCountForTesting == 1
        }
        #expect(harness.effect.runs == 0)
        #expect(harness.session.parkedApprovalCountForTesting == 0)
        let events = harness.evidence.snapshot()
        #expect(events.contains { $0.result == "principalRevoked" })
        #expect(events.contains { $0.executionAttempted } == false)
    }

    @Test func askParksAndDefersResponse() throws {
        let harness = try ParkHarness()
        defer { harness.cleanup() }
        let decision = harness.session.submitLegacy(.success(harness.frame("echo hello")))
        #expect(decision.responseDeferred == true)
        #expect(decision.response == .pending(.reviewAsk))
        #expect(harness.effect.runs == 0)
        let creates = harness.backend.snapshot.creates
        #expect(creates.count == 1)
        #expect(creates[0].reason == .reviewAsk)
        if case .shell(let shell) = creates[0].action {
            #expect(shell.supportingCommand?.rawValue == "echo hello")
        } else {
            Issue.record("parked action must be the shell command")
        }
        #expect(harness.session.parkedApprovalCountForTesting == 1)
    }

    @Test func allowOnceExecutesExactlyOnce() async throws {
        let harness = try ParkHarness()
        defer { harness.cleanup() }
        harness.backend.authorizeAll()
        let decision = harness.session.submitLegacy(.success(harness.frame("echo hello")))
        #expect(decision.responseDeferred == true)
        await waitFor("execution") { harness.effect.runs == 1 }
        #expect(harness.effect.runs == 1)
        #expect(harness.effect.commands == ["echo hello"])
        #expect(harness.session.parkedApprovalCountForTesting == 0)
        // The answer is queued exactly once and drains exactly once.
        await waitFor("completion") { harness.session.queuedCompletionCountForTesting == 1 }
        harness.session.drainCompletions()
        #expect(harness.session.queuedCompletionCountForTesting == 0)
        harness.session.drainCompletions()
        #expect(harness.effect.runs == 1)
        // Pending event plus executed outcome, both stamped.
        let events = harness.evidence.snapshot()
        #expect(events.count == 2)
        #expect(events[0].authorization == .pending)
        #expect(events[1].authorization == .allowed)
        #expect(events[1].executionAttempted == true)
        #expect(events[1].agentInstance == harness.instance.id.rawValue.uuidString)
    }

    @Test func denyExecutesZeroWithOriginalDeny() async throws {
        let harness = try ParkHarness()
        defer { harness.cleanup() }
        harness.backend.setStatusDefault("denied")
        let decision = harness.session.submitLegacy(.success(harness.frame("echo hello")))
        #expect(decision.responseDeferred == true)
        await waitFor("denial") { harness.session.queuedCompletionCountForTesting == 1 }
        #expect(harness.effect.runs == 0)
        #expect(harness.session.parkedApprovalCountForTesting == 0)
        let events = harness.evidence.snapshot()
        #expect(events.count == 2)
        #expect(events[1].authorization == .denied)
    }

    @Test func consumeRefusedExecutesZero() async throws {
        let harness = try ParkHarness()
        defer { harness.cleanup() }
        // Authorized but the grant is gone (expired/invalidated server-side).
        harness.backend.setStatusDefault("authorized")
        let decision = harness.session.submitLegacy(.success(harness.frame("echo hello")))
        #expect(decision.responseDeferred == true)
        await waitFor("failure") { harness.session.queuedCompletionCountForTesting == 1 }
        #expect(harness.effect.runs == 0)
        let events = harness.evidence.snapshot()
        #expect(events.last?.authorization == .approvalUnavailable)
    }

    @Test func sameActionNewRequestCannotDoubleExecute() async throws {
        let harness = try ParkHarness()
        defer { harness.cleanup() }
        harness.backend.authorizeAll()
        _ = harness.session.submitLegacy(.success(harness.frame("echo hello", id: UUID())))
        await waitFor("first execution") { harness.effect.runs == 1 }
        await waitFor("first completion") { harness.session.queuedCompletionCountForTesting == 1 }
        harness.session.drainCompletions()
        #expect(harness.session.queuedCompletionCountForTesting == 0)
        // Byte-identical action, new request: parks fresh (the old grant is
        // spent), then the resume is rejected as fingerprint replay — the
        // gate's at-most-once survives Step 6.
        #expect(harness.backend.snapshot.creates.count == 1)
        let second = harness.session.submitLegacy(.success(harness.frame("echo hello", id: UUID())))
        #expect(second.responseDeferred == true)
        #expect(harness.backend.snapshot.creates.count == 2)
        await waitFor("replay rejection") { harness.session.queuedCompletionCountForTesting == 1 }
        #expect(harness.effect.runs == 1)
        let events = harness.evidence.snapshot()
        #expect(events.last?.result == "replay")
        #expect(events.last?.authorization == .rejected)
    }

    @Test func createDeclinedKeepsLegacyPending() throws {
        let backend = FakeAskBackend()
        backend.setCreateDeclined(true)
        let harness = try ParkHarness(backend: backend)
        defer { harness.cleanup() }
        // Creation declined: legacy pending, answered immediately.
        let declined = harness.session.submitLegacy(.success(harness.frame("echo hello")))
        #expect(declined.responseDeferred == false)
        #expect(declined.response == .pending(.reviewAsk))
        #expect(harness.session.parkedApprovalCountForTesting == 0)
    }

    @Test func nonPendingActionsNeverPark() throws {
        let harness = try ParkHarness()
        defer { harness.cleanup() }
        harness.backend.authorizeAll()
        // Allowed action executes inline: no ASK, no park.
        let allowed = harness.session.submitLegacy(.success(harness.frame("touch marker")))
        #expect(allowed.responseDeferred == false)
        #expect(allowed.response == .executed(exitStatus: 0))
        #expect(harness.effect.runs == 1)
        #expect(harness.backend.snapshot.creates.isEmpty)
        // Denied action: no ASK, no park.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-park-outside-\(UUID().uuidString)")
        let denied = harness.session.submitLegacy(
            .success(harness.frame("touch \(outside.path)")))
        #expect(denied.responseDeferred == false)
        #expect(harness.backend.snapshot.creates.isEmpty)
    }

    @Test func waitTimeoutFailsClosedAndCancels() async throws {
        let harness = try ParkHarness(parkPollInterval: 0.005, parkTimeout: 0.05)
        defer { harness.cleanup() }
        // Backend never authorizes: the waiter gives up, cancels, and fails.
        let decision = harness.session.submitLegacy(.success(harness.frame("echo hello")))
        #expect(decision.responseDeferred == true)
        await waitFor("timeout") { harness.session.queuedCompletionCountForTesting == 1 }
        #expect(harness.effect.runs == 0)
        #expect(harness.backend.snapshot.cancels.count == 1)
        let events = harness.evidence.snapshot()
        #expect(events.last?.result == "approvalTimeout")
    }

    @Test func unknownStatusFailsClosed() async throws {
        let harness = try ParkHarness()
        defer { harness.cleanup() }
        harness.backend.setStatusDefault("unknown")
        _ = harness.session.submitLegacy(.success(harness.frame("echo hello")))
        await waitFor("unknown") { harness.session.queuedCompletionCountForTesting == 1 }
        #expect(harness.effect.runs == 0)
    }

    @Test func finishCancelsParksWithoutExecution() async throws {
        let harness = try ParkHarness()
        // Park (backend pending forever), then tear the channel down.
        let decision = harness.session.submitLegacy(.success(harness.frame("echo hello")))
        #expect(decision.responseDeferred == true)
        #expect(harness.session.parkedApprovalCountForTesting == 1)
        harness.session.finish()
        #expect(harness.session.parkedApprovalCountForTesting == 0)
        // Service-side cancel is fire-and-forget (teardown never blocks):
        // observe it with a bounded wait.
        await waitFor("cancel RPC") { harness.backend.snapshot.cancels.count == 1 }
        // Even if the human allows later, nothing runs: the park is gone.
        harness.backend.authorizeAll()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(harness.effect.runs == 0)
        harness.cleanup()
    }

    @Test func parkCapRefusesNinth() throws {
        let harness = try ParkHarness()
        defer { harness.cleanup() }
        // Backend pending forever: parks accumulate to the cap.
        for i in 0..<8 {
            let decision = harness.session.submitLegacy(
                .success(harness.frame("echo park-\(i)", id: UUID())))
            #expect(decision.responseDeferred == true)
        }
        #expect(harness.session.parkedApprovalCountForTesting == 8)
        let ninth = harness.session.submitLegacy(.success(harness.frame("echo park-9", id: UUID())))
        #expect(ninth.responseDeferred == false)
        #expect(ninth.response == .pending(.reviewAsk))
        #expect(harness.backend.snapshot.creates.count == 8)
    }

    @Test func declinedCreatesReleaseTheParkSlot() throws {
        let backend = FakeAskBackend()
        backend.setCreateDeclined(true)
        let harness = try ParkHarness(backend: backend)
        defer { harness.cleanup() }
        // Declined creates must release their reservation: eight declines
        // leave the full cap available for later parks.
        for i in 0..<8 {
            let declined = harness.session.submitLegacy(
                .success(harness.frame("echo declined-\(i)", id: UUID())))
            #expect(declined.responseDeferred == false)
        }
        #expect(harness.session.parkedApprovalCountForTesting == 0)
        backend.setCreateDeclined(false)
        for i in 0..<8 {
            let decision = harness.session.submitLegacy(
                .success(harness.frame("echo park-\(i)", id: UUID())))
            #expect(decision.responseDeferred == true)
        }
        #expect(harness.session.parkedApprovalCountForTesting == 8)
    }

    @Test func sameRequestIDRejectedAsReplay() throws {
        let harness = try ParkHarness()
        defer { harness.cleanup() }
        let id = UUID()
        let first = harness.session.submitLegacy(.success(harness.frame("echo hello", id: id)))
        #expect(first.responseDeferred == true)
        let replay = harness.session.submitLegacy(.success(harness.frame("echo hello", id: id)))
        #expect(replay.response == .rejected(.replay))
        #expect(harness.backend.snapshot.creates.count == 1)
    }

    @Test func statusBlipRetriesUntilDecision() async throws {
        // Status polls that fail (nil) are transport blips: the waiter
        // keeps polling instead of failing the ASK. The park timeout is
        // generous on purpose: this test proves blip-retry, and under
        // full-suite load the 6 script polls can arrive slowly.
        let backend = FakeAskBackend()
        let harness = try ParkHarness(backend: backend, parkTimeout: 120)
        defer { harness.cleanup() }
        _ = harness.session.submitLegacy(.success(harness.frame("echo hello")))
        let approvalID = try #require(backend.snapshot.created.first?.approvalID)
        backend.setStatusScript(
            [nil, nil, "pending", "awaitingAuthentication", "authorized"], for: approvalID)
        backend.setConsumable(approvalID)
        await waitFor("execution after blips") { harness.effect.runs == 1 }
        #expect(harness.effect.runs == 1)
    }
}
