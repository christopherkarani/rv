import Foundation
import Testing
import RVDomain
import RVHistory
import RVHooks
import RVIPC
import RVPolicy
@testable import RVService

@Suite("Daemon-side hook deadline")
struct HookDeadlineTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let askStdin = """
    {"toolName":"bash","cwd":"/tmp/ws","sessionId":"sess-pi","input":{"command":"git reset --hard"}}
    """

    @Test func budgetStaysBelowTheClientHookTimeout() {
        // Sources/rv-c/rv.c gives hookEvaluate 8 s; the daemon must stop
        // committing side effects before the client gives up.
        #expect(HookDeadline.budget < .seconds(8))
        #expect(HookDeadline.budget == .seconds(7))
    }

    @Test func expiredDeadlineIsStickyAndFreshOneAdmits() {
        let fresh = HookDeadline()
        #expect(fresh.permitsSideEffects())
        #expect(fresh.hasTripped == false)

        let stale = HookDeadline(receivedAt: .now - .seconds(30))
        #expect(stale.permitsSideEffects() == false)
        #expect(stale.hasTripped)
        #expect(stale.permitsSideEffects() == false)
    }

    @Test func lateHookEvaluateDoesNotConsumeTheAllowOnceGrant() async throws {
        let env = try DeadlineEnv()
        defer { env.tearDown() }
        #expect(await env.plantResetHardGrant() == .planted)

        let wire = await env.runtime.dispatch(
            IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: .pi, stdin: Self.askStdin))),
            context: peerHookContext(),
            receivedAt: .now - .seconds(30)
        )
        try assertDeny(wire)
        #expect(await env.grantStillLive())
        #expect(try await env.pending.list(now: Self.now).isEmpty)
    }

    @Test func lateHookEvaluateWritesNoPendingRowOrUnlockCode() async throws {
        let env = try DeadlineEnv()
        defer { env.tearDown() }

        let wire = await env.runtime.dispatch(
            IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: .pi, stdin: Self.askStdin))),
            context: peerHookContext(),
            receivedAt: .now - .seconds(30)
        )
        try assertDeny(wire)
        #expect(try await env.pending.list(now: Self.now).isEmpty)
        #expect(env.allowOnceRows().isEmpty)
        #expect(env.denialRecords().isEmpty)

        // Control: the same consult inside the budget does write them.
        let inTime = await env.runtime.dispatch(
            IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: .pi, stdin: Self.askStdin))),
            context: peerHookContext(),
            receivedAt: .now
        )
        guard case .hookEvaluate(let reply) = inTime.result else {
            Issue.record("expected hookEvaluate, got \(inTime.result)")
            return
        }
        #expect(reply.stdout.contains("timed out") == false)
        #expect(try await env.pending.list(now: Self.now).count == 1)
        #expect(env.allowOnceRows().isEmpty == false)
        #expect(env.denialRecords().isEmpty == false)
    }

    @Test func expiryMidEvaluationSkipsLaterSideEffects() async throws {
        let env = try DeadlineEnv()
        defer { env.tearDown() }
        let deadline = HookDeadline(receivedAt: .now, budget: .milliseconds(200))
        let world = hookWorld(
            evaluate: { command, _ in
                // The evaluation itself outlives the budget.
                try? await Task.sleep(for: .milliseconds(400))
                return EvaluationResult(
                    outcome: .deny(
                        Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "x"),
                        matched: nil),
                    matchingView: MatchingView(command.rawValue))
            },
            mintOnDeny: { _, _ in
                Issue.record("mint must not run past the deadline")
                return nil
            },
            recordHostAsk: { _, _ in
                Issue.record("pending row must not be written past the deadline")
            }
        )
        let gated = HookEvaluateWorld.deadlineGuarded(world)
        let reply = try await HookDoor.run(
            host: .pi, stdin: Self.askStdin, world: gated, deadline: deadline)
        #expect(deadline.hasTripped)
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(reply.stdout.utf8)) as? [String: Any])
        #expect(json["decision"] as? String == "deny")
        #expect(reply.stdout.contains("timed out"))
    }

    @Test func inTimeHookEvaluateStillConsumesTheGrant() async throws {
        let env = try DeadlineEnv()
        defer { env.tearDown() }
        #expect(await env.plantResetHardGrant() == .planted)

        let wire = await env.runtime.dispatch(
            IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: .pi, stdin: Self.askStdin))),
            context: peerHookContext(),
            receivedAt: .now
        )
        guard case .hookEvaluate(let reply) = wire.result else {
            Issue.record("expected hookEvaluate, got \(wire.result)")
            return
        }
        #expect(reply.stdout.contains("timed out") == false)
        #expect(await env.grantStillLive() == false)
    }
}

private func assertDeny(_ wire: IPCResponse) throws {
    guard case .hookEvaluate(let reply) = wire.result else {
        Issue.record("expected hookEvaluate, got \(wire.result)")
        return
    }
    let json = try #require(
        JSONSerialization.jsonObject(with: Data(reply.stdout.utf8)) as? [String: Any])
    #expect(json["decision"] as? String == "deny")
    #expect(reply.stdout.contains("timed out"))
}

private struct DeadlineEnv {
    let homeURL: URL
    let allowOnceDirectory: URL
    let home: HomeDirectory
    let grants = EphemeralAllowOnceTable()
    let runtime: ServiceRuntime
    let pending: PendingApprovalStore

    init() throws {
        homeURL = try isolatedHomeDirectory()
        allowOnceDirectory = try isolatedAllowOnceDirectory()
        home = try #require(HomeDirectory(validating: homeURL.path))
        runtime = ServiceRuntime(
            home: home,
            allowOnceDirectory: allowOnceDirectory,
            grants: grants,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
            pendingApprovals: .automatic
        )
        pending = PendingApprovalStore.makeLive(home: home)
    }

    func plantResetHardGrant() async -> EphemeralAllowOnceTable.PlantResult {
        await grants.plant(
            matchingView: "git reset --hard", cwd: wd("/tmp/ws"), codeHash: "deadline",
            now: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func grantStillLive() async -> Bool {
        await grants.hasGrant(
            matchingView: "git reset --hard", cwd: wd("/tmp/ws"),
            now: Date(timeIntervalSince1970: 1_700_000_000), maskedSegments: [])
    }

    func allowOnceRows() -> [String] {
        let file = allowOnceDirectory.appendingPathComponent("allow-once.jsonl")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    func denialRecords() -> [DenialLedgerRecord] {
        DenialLedger(configDirectory: RVPolicyPaths.configDirectory(home: home))
            .records(asOf: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: homeURL)
        try? FileManager.default.removeItem(at: allowOnceDirectory)
    }
}

@Suite("Runtime live-grant query for idle exit")
struct RuntimeLiveGrantTests {
    @Test func runtimeReportsLiveAllowOnceGrants() async throws {
        let env = try DeadlineEnv()
        defer { env.tearDown() }
        #expect(await env.runtime.hasLiveAllowOnceGrants() == false)
        #expect(await env.plantResetHardGrant() == .planted)
        #expect(await env.runtime.hasLiveAllowOnceGrants())
    }
}
