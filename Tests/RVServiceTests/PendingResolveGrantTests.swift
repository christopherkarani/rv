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

        let resolved = await env.runtime.dispatch(
            IPCRequest(method: .pendingResolve(env.resolveParams(created, decision: .allowOnce)))
        )
        guard case .pendingResolve(let reply) = resolved.result else {
            Issue.record("allowOnce must resolve, got \(resolved.result)")
            return
        }
        #expect(reply.terminal)
        try env.assertNoCommandText(resolved)

        let listed = try await env.pending.list(now: now)
        #expect(listed.isEmpty)
        let loaded = try await env.pending.load(id: created.id, now: now)
        #expect(loaded.authorizes(created.fingerprint, identity: created.identity) == false)
        guard case .consumed = loaded.state else {
            Issue.record("plant path must consume the wait")
            return
        }
        #expect(try await env.grantedCount() == 1)

        let first = await env.applyResetHard()
        guard case .evaluate(let allowed) = first.result, case .allow = allowed.result.decision else {
            Issue.record("next apply must allow once, got \(first.result)")
            return
        }
        let second = await env.applyResetHard()
        guard case .evaluate(let denied) = second.result, case .deny = denied.result.decision else {
            Issue.record("replay must deny, got \(second.result)")
            return
        }
        #expect(try await env.grantedCount() == 0)
    }

    @Test func PendingResolveGrant_denyResolvesWithoutGrant() async throws {
        let env = try IsolatedPendingResolve()
        defer { env.tearDown() }
        let created = try await env.seedResetHard()

        let resolved = await env.runtime.dispatch(
            IPCRequest(method: .pendingResolve(env.resolveParams(created, decision: .deny)))
        )
        guard case .pendingResolve(let reply) = resolved.result else {
            Issue.record("deny must resolve, got \(resolved.result)")
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
        let request = IPCRequest(method: .pendingResolve(env.resolveParams(created, decision: .allowOnce)))
        async let first = env.runtime.dispatch(request)
        async let second = env.runtime.dispatch(request)
        let results = await [first, second]
        let planted = results.filter {
            if case .pendingResolve = $0.result { return true }
            return false
        }
        let rejected = results.filter { $0.result == .error(.pendingAlreadyTerminal) }
        #expect(planted.count == 1)
        #expect(rejected.count == 1)
        #expect(try await env.grantedCount() == 1)
    }

    @Test func PendingResolveGrant_secondAllowOnceIsAlreadyTerminalWithoutSecondGrant() async throws {
        let env = try IsolatedPendingResolve()
        defer { env.tearDown() }
        let created = try await env.seedResetHard()
        _ = await env.runtime.dispatch(
            IPCRequest(method: .pendingResolve(env.resolveParams(created, decision: .allowOnce)))
        )
        let grants = try await env.grantedCount()
        #expect(grants == 1)

        let again = await env.runtime.dispatch(
            IPCRequest(method: .pendingResolve(env.resolveParams(created, decision: .allowOnce)))
        )
        #expect(again.result == .error(.pendingAlreadyTerminal))
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
                    predicate: .gitPush(force: .forceWithLease, branch: "main"),
                    verdict: .deny,
                    origin: .machine
                ),
            ])
        let created = try await env.seed(
            command: "git push --force-with-lease origin main",
            cwd: cwd
        )

        let resolved = await env.runtime.dispatch(
            IPCRequest(method: .pendingResolve(env.resolveParams(created, decision: .allowOnce)))
        )
        #expect(resolved.result == .error(.pendingAllowOnceNotUnlockable))
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
                session: SessionIdentity(rawValue: "sess-pi"),
                agent: AgentIdentity(rawValue: HookHost.pi.rawValue)
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
        let resolve = await runtime.dispatch(
            IPCRequest(
                method: .pendingResolve(
                    PendingResolveParams(
                        id: wait.id,
                        decision: .allowOnce,
                        fingerprint: wait.fingerprint,
                        identity: wait.identity
                    )
                )
            )
        )
        #expect(resolve.result == .error(.pendingCoordinatorUnavailable))
        let grants = AllowOnceStore(baseDirectory: allowOnceDirectory)
        #expect(await grants.list(now: now).isEmpty)
    }

    @Test func PendingResolveGrant_alreadyAllowResolvesWithoutSecondGrant() async throws {
        let env = try IsolatedPendingResolve()
        defer { env.tearDown() }
        let created = try await env.seed(command: "git status", cwd: wd("/tmp/ws"))

        let resolved = await env.runtime.dispatch(
            IPCRequest(method: .pendingResolve(env.resolveParams(created, decision: .allowOnce)))
        )
        guard case .pendingResolve(let reply) = resolved.result else {
            Issue.record("already-allow must resolve, got \(resolved.result)")
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

    init() throws {
        homeURL = try isolatedHomeDirectory()
        allowOnceDirectory = try isolatedAllowOnceDirectory()
        home = try #require(HomeDirectory(validating: homeURL.path))
        runtime = ServiceRuntime(
            home: home,
            allowOnceDirectory: allowOnceDirectory,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
            pendingApprovals: .automatic
        )
        pending = PendingApprovalStore.live(home: home)
        grants = AllowOnceStore(baseDirectory: allowOnceDirectory)
    }

    func seedResetHard() async throws -> PendingApproval {
        try await seed(command: "git reset --hard", cwd: wd("/tmp/ws"))
    }

    func seed(command: String, cwd: WorkingDirectory) async throws -> PendingApproval {
        let shell = ShellCommand(rawValue: command)
        return try await pending.create(
            PendingApprovalRequest(
                id: PendingApprovalStore.makeID(),
                identity: ApprovalIdentity(
                    session: SessionIdentity(rawValue: "sess-pi"),
                    agent: AgentIdentity(rawValue: HookHost.pi.rawValue)
                ),
                action: .shell(
                    ShellAction(
                        fingerprint: ActionFingerprint.make(
                            host: .pi,
                            session: SessionID(validating: "sess-pi"),
                            cwd: cwd,
                            command: shell
                        ),
                        scope: ActionScope(workingDirectory: cwd),
                        supportingCommand: shell
                    )
                ),
                reason: .hostAsk,
                continuation: .hostNative,
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

    func applyResetHard() async -> IPCResponse {
        await runtime.dispatch(
            IPCRequest(
                method: .evaluate(
                    EvaluateParams(
                        request: EvaluationRequest(
                            command: ShellCommand(rawValue: "git reset --hard"),
                            enabledPacks: dayOnePackIDs
                        ),
                        cwd: wd("/tmp/ws")
                    )
                )
            )
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
