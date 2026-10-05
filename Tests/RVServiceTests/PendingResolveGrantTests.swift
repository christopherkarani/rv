import Foundation
import Testing
import RVDomain
import RVIPC
import RVPolicy
@testable import RVService

@Suite("PendingResolveGrant")
struct PendingResolveGrantTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let command = "git reset --hard"

    @Test func PendingResolveGrant_allowOncePlantsGrantAndNextApplyAllowsOnce() async throws {
        let env = try IsolatedPendingResolve()
        defer { env.tearDown() }
        let created = try await env.seedResetHard()

        let resolved = await env.resolve(created, decision: .allowOnce)
        guard case .success(let reply) = resolved else {
            Issue.record("allowOnce must resolve, got \(resolved)")
            return
        }
        #expect(reply.terminal)
        try env.assertNoCommandText(resolved)

        let listed = try await env.pending.list(now: now)
        #expect(listed.isEmpty)
        let loaded = try await env.pending.load(id: created.id, now: now)
        guard case .resolved(let resolution) = loaded.state,
            resolution.decision == .allowOnce
        else {
            Issue.record("plant path must resolve the wait, got \(loaded.state)")
            return
        }
        #expect(try await env.grantedCount() == 1)

        let first = await env.applyResetHard()
        guard case .allow = first.result.decision else {
            Issue.record("next apply must allow once, got \(first.result.decision)")
            return
        }
        let second = await env.applyResetHard()
        guard case .deny = second.result.decision else {
            Issue.record("replay must deny, got \(second.result.decision)")
            return
        }
        // Step 8B.1: the projection row persists as audit (spend is
        // memory-only); the replay-deny above proves the consume.
        #expect(try await env.grantedCount() == 1)
        #expect(
            await env.memory.hasGrant(
                matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now
            ) == false
        )
    }

    @Test func PendingResolveGrant_denyResolvesWithoutGrant() async throws {
        let env = try IsolatedPendingResolve()
        defer { env.tearDown() }
        let created = try await env.seedResetHard()

        let resolved = await env.resolve(created, decision: .deny)
        guard case .success(let reply) = resolved else {
            Issue.record("deny must resolve, got \(resolved)")
            return
        }
        #expect(reply.terminal)
        try env.assertNoCommandText(resolved)
        #expect(try await env.pending.list(now: now).isEmpty)
        #expect(try await env.grantedCount() == 0)
        let loaded = try await env.pending.load(id: created.id, now: now)
        guard case .resolved(let resolution) = loaded.state else {
            Issue.record("deny must stay resolved, not planted")
            return
        }
        #expect(resolution.decision == .deny)
    }

    @Test func PendingResolveGrant_concurrentAllowOncePlantsAtMostOneGrant() async throws {
        let env = try IsolatedPendingResolve()
        defer { env.tearDown() }
        let created = try await env.seedResetHard()
        async let first = env.resolve(created, decision: .allowOnce)
        async let second = env.resolve(created, decision: .allowOnce)
        let results = await [first, second]
        let planted = results.filter {
            if case .success = $0 { return true }
            return false
        }
        let rejected = results.filter { $0 == .failure(.pendingAlreadyTerminal) }
        #expect(planted.count == 1)
        #expect(rejected.count == 1)
        #expect(try await env.grantedCount() == 1)
    }

    @Test func PendingResolveGrant_secondAllowOnceIsAlreadyTerminalWithoutSecondGrant() async throws {
        let env = try IsolatedPendingResolve()
        defer { env.tearDown() }
        let created = try await env.seedResetHard()
        _ = await env.resolve(created, decision: .allowOnce)
        let grants = try await env.grantedCount()
        #expect(grants == 1)

        let again = await env.resolve(created, decision: .allowOnce)
        #expect(again == .failure(.pendingAlreadyTerminal))
        #expect(try await env.grantedCount() == grants)
        try env.assertNoCommandText(again)
    }

    @Test func PendingResolveGrant_hardBindDoesNotPlantOrResolve() async throws {
        let env = try IsolatedPendingResolve()
        defer { env.tearDown() }
        let workspace = try isolatedTypedWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let cwd = try #require(WorkingDirectory(validating: workspace.path))
        let ruleID = RuleID(pack: .coreGit, pattern: "hook-load-main-deny")
        try TypedRuleStore(baseDirectory: RVPolicyPaths.configDirectory(home: env.home))
            .saveMachine([
                TypedRule(
                    id: ruleID,
                    predicate: .gitPush(force: .exactly(.forceWithLease), branch: "main"),
                    verdict: .deny,
                    origin: .machine
                ),
            ])
        let created = try await env.seed(
            command: "git push --force-with-lease origin main",
            cwd: cwd
        )

        let resolved = await env.resolve(created, decision: .allowOnce)
        #expect(resolved == .failure(.pendingAllowOnceNotUnlockable))
        #expect(try await env.pending.list(now: now).map(\.id) == [created.id])
        #expect(try await env.grantedCount() == 0)
        let loaded = try await env.pending.load(id: created.id, now: now)
        #expect(loaded.state == .awaitingHuman)
    }

    @Test func PendingResolveGrant_missingCoordinatorFailsClosedWithoutGrant() async throws {
        let homeURL = try isolatedHomeDirectory()
        let allowOnceDirectory = try isolatedAllowOnceDirectory()
        defer {
            try? FileManager.default.removeItem(at: homeURL)
            try? FileManager.default.removeItem(at: allowOnceDirectory)
        }
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let runtime = ServiceRuntime(
            home: home,
            allowOnceDirectory: allowOnceDirectory,
            clock: { now },
            pendingApprovals: .missing
        )
        let wait = PendingApproval(
            id: ApprovalID(rawValue: "down-1"),
            identity: ApprovalIdentity(
                session: SessionID(validating: "sess-pi")!,
                agent: .pi
            ),
            action: .shell(
                ShellAction(
                    fingerprint: ActionFingerprint(rawValue: "shell:down-1"),
                    scope: ActionScope(workingDirectory: wd("/tmp/ws")),
                    supportingCommand: ShellCommand(rawValue: command)
                )
            ),
            reason: .hostAsk,
            continuation: .hostNative,
            timeoutPolicy: .keepWaiting,
            createdAt: now,
            expiresAt: now.addingTimeInterval(3600),
            state: .awaitingHuman
        )
        let grants = AllowOnceStore(baseDirectory: allowOnceDirectory)
        let resolve = await HookAskResolver.resolve(
            params: PendingResolveParams(
                id: wait.id,
                decision: .allowOnce,
                fingerprint: wait.fingerprint,
                identity: wait.identity
            ),
            reviewedAction: (
                wait.action.supportingCommand,
                wait.action.scope.workingDirectory
            ),
            pending: nil,
            grants: EphemeralAllowOnceTable(),
            projection: grants,
            peek: { _, _, _ in
                Issue.record("missing coordinator must not peek")
                return EvaluationResult(outcome: .plain, matchingView: MatchingView(""))
            },
            now: now
        )
        #expect(resolve == .failure(.pendingCoordinatorUnavailable))
        #expect(await grants.list(now: now).isEmpty)
        _ = runtime
    }

    @Test func PendingResolveGrant_alreadyAllowResolvesWithoutSecondGrant() async throws {
        let env = try IsolatedPendingResolve()
        defer { env.tearDown() }
        let created = try await env.seed(command: "git status", cwd: wd("/tmp/ws"))

        let resolved = await env.resolve(created, decision: .allowOnce)
        guard case .success(let reply) = resolved else {
            Issue.record("already-allow must resolve, got \(resolved)")
            return
        }
        #expect(reply.terminal)
        #expect(try await env.grantedCount() == 0)
        #expect(try await env.pending.list(now: now).isEmpty)
    }

    @Test func PendingResolveGrant_plannerRefusesHardBindAndIndeterminate() {
        let deny = Deny(
            ruleID: RuleID(pack: ActionPolicyEngine.Builtin.pack, pattern: "working-tree-discard"),
            reason: "hard"
        )
        let hard = EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: MatchingView("git reset --hard"),
            analysis: .unknown,
            boundReview: .deny(deny)
        )
        #expect(PendingAllowOncePlanner.plan(peek: hard, cwd: wd("/tmp/ws")) == .refuse)

        let incomplete = EvaluationResult(
            outcome: .indeterminate(.commandTooLarge),
            matchingView: MatchingView("git reset --hard")
        )
        #expect(PendingAllowOncePlanner.plan(peek: incomplete, cwd: wd("/tmp/ws")) == .refuse)
        #expect(PendingAllowOncePlanner.plan(peek: resetHardPackDeny, cwd: nil) == .refuse)
    }

    @Test func PendingResolveGrant_plannerPlantsUnlockablePackDeny() {
        #expect(
            PendingAllowOncePlanner.plan(peek: resetHardPackDeny, cwd: wd("/tmp/ws"))
                == .plant(matchingView: MatchingView("git reset --hard"), cwd: wd("/tmp/ws"))
        )
        let allowed = EvaluationResult(
            outcome: .plain,
            matchingView: MatchingView("git status")
        )
        #expect(PendingAllowOncePlanner.plan(peek: allowed, cwd: wd("/tmp/ws")) == .resolveWithoutGrant)
    }

    @Test func PendingResolveGrant_bareDispatchStaysDenied() async throws {
        let env = try IsolatedPendingResolve()
        defer { env.tearDown() }
        let created = try await env.seedResetHard()

        // Step 8: row-ID knowledge is not authority. The authorized core
        // above resolves; generic IPC never does, with or without a peer.
        for context in [AuthenticatedRequestContext.unauthenticated, peerHookContext()] {
            let denied = await env.runtime.dispatch(
                IPCRequest(method: .pendingResolve(env.resolveParams(created, decision: .allowOnce))),
                context: context
            )
            #expect(denied.result == .error(.authorizationDenied))
        }
        #expect(try await env.grantedCount() == 0)
        let loaded = try await env.pending.load(id: created.id, now: now)
        #expect(loaded.state == .awaitingHuman)
    }

    @Test func PendingResolveGrant_plannerRefusesMissingCwd() {
        #expect(
            PendingAllowOncePlanner.plan(peek: resetHardPackDeny, cwd: nil) == .refuse
        )
    }

    @Test func PendingResolveGrant_plannerRefusesHardBind() {
        let deny = ActionPolicyEngine.Builtin.remoteSharedBranch
        let hard = EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: MatchingView("git push --force origin main"),
            analysis: .unknown,
            boundReview: .deny(deny)
        )
        #expect(
            PendingAllowOncePlanner.plan(peek: hard, cwd: wd("/tmp/ws")) == .refuse
        )
    }

    @Test func PendingResolveGrant_plannerRefusesPinnedSecret() {
        let secret = EvaluationResult(
            outcome: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreSecrets, pattern: "env"),
                    reason: "secret"
                ),
                matched: nil
            ),
            matchingView: MatchingView("cat .env")
        )
        #expect(
            PendingAllowOncePlanner.plan(peek: secret, cwd: wd("/tmp/ws")) == .refuse
        )
    }

    @Test func PendingResolveGrant_plannerRefusesIndeterminate() {
        let incomplete = EvaluationResult(
            outcome: .indeterminate(.commandTooLarge),
            matchingView: MatchingView("git reset --hard")
        )
        #expect(
            PendingAllowOncePlanner.plan(peek: incomplete, cwd: wd("/tmp/ws")) == .refuse
        )
    }

    @Test func PendingResolveGrant_plannerPlantsMandatoryHumanCarry() {
        let ask = ActionPolicyEngine.Builtin.remoteBranchAsk
        let carried = EvaluationResult(
            outcome: .deny(ask, matched: nil),
            matchingView: MatchingView("git push origin feature"),
            analysis: .unknown,
            boundReview: .mandatoryHuman(ask)
        )
        #expect(
            PendingAllowOncePlanner.plan(peek: carried, cwd: wd("/tmp/ws"))
                == .plant(
                    matchingView: MatchingView("git push origin feature"),
                    cwd: wd("/tmp/ws")
                )
        )
    }

    @Test(arguments: [HookHost.grok, .codex, .cursor, .pi, .claude])
    func PendingResolveGrant_universalAllowOncePlantsForEveryHost(_ host: HookHost) async throws {
        let env = try IsolatedPendingResolve()
        defer { env.tearDown() }
        let created = try await env.seed(command: "git reset --hard", cwd: wd("/tmp/ws"), host: host)

        // Step 8B: no host tiers. A human allow-once resolves every host
        // through the same peek → plan → plant → consume sequence.
        let resolved = await env.resolve(created, decision: .allowOnce)
        guard case .success(let reply) = resolved else {
            Issue.record("universal resolve must succeed for \(host), got \(resolved)")
            return
        }
        #expect(reply.terminal)
        #expect(try await env.grantedCount() == 1)
        #expect(try await env.pending.list(now: now).isEmpty)
        let loaded = try await env.pending.load(id: created.id, now: now)
        guard case .resolved(let resolution) = loaded.state,
            resolution.decision == .allowOnce
        else {
            Issue.record("plant path must resolve the wait for \(host), got \(loaded.state)")
            return
        }
    }
}

private let resetHardPackDeny = EvaluationResult(
    outcome: .deny(
        Deny(
            ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
            reason: "git reset --hard destroys uncommitted changes"
        ),
        matched: nil
    ),
    matchingView: MatchingView("git reset --hard")
)

private struct IsolatedPendingResolve {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let homeURL: URL
    let allowOnceDirectory: URL
    let home: HomeDirectory
    let runtime: ServiceRuntime
    let pending: PendingApprovalStore
    let grants: AllowOnceStore
    /// Step 8B.1: sole spend authority, shared by the resolve core, the
    /// peek world, and the runtime (one daemon epoch).
    let memory: EphemeralAllowOnceTable

    init() throws {
        homeURL = try isolatedHomeDirectory()
        allowOnceDirectory = try isolatedAllowOnceDirectory()
        home = try #require(HomeDirectory(validating: homeURL.path))
        let table = EphemeralAllowOnceTable()
        memory = table
        runtime = ServiceRuntime(
            home: home,
            allowOnceDirectory: allowOnceDirectory,
            grants: table,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
            pendingApprovals: .automatic
        )
        pending = PendingApprovalStore.makeLive(home: home)
        grants = AllowOnceStore(baseDirectory: allowOnceDirectory)
    }

    func seedResetHard() async throws -> PendingApproval {
        try await seed(command: "git reset --hard", cwd: wd("/tmp/ws"))
    }

    func seed(
        command: String,
        cwd: WorkingDirectory,
        host: HookHost = .pi,
        continuation: ApprovalContinuation = .hostNative
    ) async throws -> PendingApproval {
        let shell = ShellCommand(rawValue: command)
        return try await pending.create(
            PendingApprovalRequest(
                id: PendingApprovalStore.makeID(),
                identity: ApprovalIdentity(
                    session: SessionID(validating: "sess-pi")!,
                    agent: host
                ),
                action: .shell(
                    ShellAction(
                        fingerprint: ActionFingerprint.make(
                            host: host,
                            session: SessionID(validating: "sess-pi"),
                            cwd: cwd,
                            command: shell
                        ),
                        scope: ActionScope(workingDirectory: cwd),
                        supportingCommand: shell
                    )
                ),
                reason: .hostAsk,
                continuation: continuation,
                timeoutPolicy: .keepWaiting
            ),
            now: now
        )
    }

    func resolveParams(
        _ record: PendingApproval,
        decision: PendingResolveDecision
    ) -> PendingResolveParams {
        PendingResolveParams(
            id: record.id,
            decision: decision,
            fingerprint: record.fingerprint,
            identity: record.identity
        )
    }

    /// Owner-authorized resolve core. Generic IPC `pendingResolve` stays
    /// denied (row-ID knowledge is not authority); the ceremony transports
    /// (operator UI, unlock code) reach this same core after proving the
    /// human.
    func resolve(
        _ record: PendingApproval,
        decision: PendingResolveDecision
    ) async -> Result<PendingResolveReply, IPCError> {
        await HookAskResolver.resolve(
            params: resolveParams(record, decision: decision),
            reviewedAction: decision == .deny ? nil : (
                record.action.supportingCommand,
                record.action.scope.workingDirectory
            ),
            pending: pending,
            grants: memory,
            projection: grants,
            peek: { command, cwd, now in
                await LiveEvaluateWorld(home: home, store: grants, grants: memory, clock: { now })
                    .peek(command: command, cwd: cwd)
            },
            now: now
        )
    }

    func applyResetHard() async -> EvaluateReply {
        await runtime.evaluate(
            EvaluationRequest(
                command: ShellCommand(rawValue: "git reset --hard"),
                enabledPacks: dayOnePackIDs
            ),
            cwd: wd("/tmp/ws")
        )
    }

    func grantedCount() async throws -> Int {
        await grants.list(now: now).filter { $0.kind == .granted }.count
    }

    func assertNoCommandText(_ response: IPCResponse) throws {
        let data = try IPCJSON.encode(response)
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(text.contains("supportingCommand") == false)
        let object = try JSONSerialization.jsonObject(with: data)
        assertNoCommandKeys(object)
    }

    func assertNoCommandText(_ result: Result<PendingResolveReply, IPCError>) throws {
        let ipc: IPCResult
        switch result {
        case .success(let reply):
            ipc = .pendingResolve(reply)
        case .failure(let error):
            ipc = .error(error)
        }
        try assertNoCommandText(IPCResponse(id: UUID(), result: ipc))
    }

    func assertNoCommandKeys(_ object: Any) {
        switch object {
        case let dict as [String: Any]:
            #expect(dict["command"] == nil)
            #expect(dict["supportingCommand"] == nil)
            for value in dict.values {
                assertNoCommandKeys(value)
            }
        case let array as [Any]:
            for value in array {
                assertNoCommandKeys(value)
            }
        default:
            break
        }
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: homeURL)
        try? FileManager.default.removeItem(at: allowOnceDirectory)
    }
}

private func isolatedTypedWorkspace() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-pending-grant-ws-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
