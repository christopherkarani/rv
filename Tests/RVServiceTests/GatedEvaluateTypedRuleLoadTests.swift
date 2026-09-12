import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVService

@Suite("GatedEvaluateTypedRuleLoad")
struct GatedEvaluateTypedRuleLoadTests {
    @Test func savedTypedDeny_forceWithLeaseFeature_deniesWithSavedRuleID() async throws {
        let homeURL = try isolatedHomeDirectory()
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let workspace = try isolatedWorkspace()
        let ruleID = RuleID(pack: .coreGit, pattern: "hook-load-feature-deny")
        let rule = TypedRule(
            id: ruleID,
            predicate: .gitPush(force: .forceWithLease, branch: "feature"),
            verdict: .deny,
            origin: .machine
        )
        try TypedRuleStore(baseDirectory: RVPolicyPaths.configDirectory(home: home))
            .saveMachine([rule])

        let result = try await peek(
            "git push --force-with-lease origin feature",
            cwd: workspace,
            home: home
        )
        guard case .deny(let deny) = result.decision else {
            Issue.record("saved typed deny must deny force-with-lease feature, got \(result.decision)")
            return
        }
        #expect(deny.ruleID == ruleID)
        #expect(deny.ruleID != ActionPolicyEngine.Builtin.remoteBranchAsk.ruleID)
    }

    @Test func invalidTypedRulesFile_failClosedNotAllow() async throws {
        let homeURL = try isolatedHomeDirectory()
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let workspace = try isolatedWorkspace()
        let config = RVPolicyPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "not-json".write(
            to: RVPolicyPaths.typedRulesFile(inConfigDir: config),
            atomically: true,
            encoding: .utf8
        )

        let result = try await peek("git stash drop", cwd: workspace, home: home)
        guard case .deny(let deny) = result.decision else {
            Issue.record("invalid typed-rules.json must fail closed, got \(result.decision)")
            return
        }
        #expect(deny.ruleID == RuleID(pack: ActionPolicyEngine.Builtin.pack, pattern: "typed-rules-invalid"))
        #expect(deny.reason == "Typed rules could not be loaded.")
    }

    @Test func invalidPolicyTOML_failClosedNotAllow() async throws {
        let homeURL = try isolatedHomeDirectory()
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let workspace = try isolatedWorkspace()
        let config = RVPolicyPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "not-toml".write(
            to: RVPolicyPaths.policyFile(inConfigDir: config),
            atomically: true,
            encoding: .utf8
        )

        let result = try await peek("git stash drop", cwd: workspace, home: home)
        guard case .deny(let deny) = result.decision else {
            Issue.record("invalid policy.toml must fail closed, got \(result.decision)")
            return
        }
        #expect(deny.ruleID == RuleID(pack: ActionPolicyEngine.Builtin.pack, pattern: "typed-rules-invalid"))
        #expect(deny.reason == "Typed rules could not be loaded.")
    }

    @Test func typedAllow_cannotBeatSharedBranchHardDeny() async throws {
        let homeURL = try isolatedHomeDirectory()
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let workspace = try isolatedWorkspace()
        let rule = TypedRule(
            id: RuleID(pack: .coreGit, pattern: "hook-load-allow-main"),
            predicate: .gitPush(force: .force, branch: "main"),
            verdict: .allow,
            origin: .machine
        )
        try TypedRuleStore(baseDirectory: RVPolicyPaths.configDirectory(home: home))
            .saveMachine([rule])

        // python -c masks the payload in matchingView, so day-one
        // `push-force-long` does not floor. bash -c quotes do not mask, so
        // pack still matches `--force`. Unwrap then hits the builtin wall.
        let result = try await peek(
            #"python -c "os.system('git push --force origin main')""#,
            cwd: workspace,
            home: home
        )
        guard case .deny(let deny) = result.decision else {
            Issue.record("typed allow must not beat shared-branch hard deny, got \(result.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.remoteSharedBranch.ruleID)
    }

    @Test func typedDeny_forceWithLeaseMain_grantCannotOverrideHardBind() async throws {
        let homeURL = try isolatedHomeDirectory()
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let workspace = try isolatedWorkspace()
        let cwd = try #require(WorkingDirectory(validating: workspace.path))
        let ruleID = RuleID(pack: .coreGit, pattern: "hook-load-main-deny")
        let rule = TypedRule(
            id: ruleID,
            predicate: .gitPush(force: .forceWithLease, branch: "main"),
            verdict: .deny,
            origin: .machine
        )
        try TypedRuleStore(baseDirectory: RVPolicyPaths.configDirectory(home: home))
            .saveMachine([rule])

        let command = "git push --force-with-lease origin main"
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory())
        try await store.insertGranted(matchingView: MatchingView(command), cwd: cwd, now: now)

        let result = await peek(command, cwd: workspace, home: home, store: store)
        guard case .deny(let deny) = result.decision else {
            Issue.record("typed deny hard bind must not honor matchingView grant, got \(result.decision)")
            return
        }
        #expect(deny.ruleID == ruleID)
        #expect(result.boundReview == .deny(deny))
        let code = await GatedEvaluate.mintUnlockCode(
            for: result,
            cwd: cwd,
            store: store,
            now: now,
            home: home
        )
        #expect(code == nil)
    }

    @Test func typedDeny_forceWithLeaseMain_spendHostAskCannotOverrideHardBind() async throws {
        let homeURL = try isolatedHomeDirectory()
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let workspace = try isolatedWorkspace()
        let cwd = try #require(WorkingDirectory(validating: workspace.path))
        let ruleID = RuleID(pack: .coreGit, pattern: "hook-load-main-deny")
        let rule = TypedRule(
            id: ruleID,
            predicate: .gitPush(force: .forceWithLease, branch: "main"),
            verdict: .deny,
            origin: .machine
        )
        try TypedRuleStore(baseDirectory: RVPolicyPaths.configDirectory(home: home))
            .saveMachine([rule])

        let command = "git push --force-with-lease origin main"
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory())

        let planted = await spendHostAsk(command, cwd: workspace, home: home, store: store)
        guard case .deny(let deny) = planted.decision else {
            Issue.record("typed deny hard bind must not plant+spend on Host Ask, got \(planted.decision)")
            return
        }
        #expect(deny.ruleID == ruleID)
        #expect(planted.boundReview == .deny(deny))

        try await store.insertGranted(matchingView: MatchingView(command), cwd: cwd, now: now)
        let granted = await spendHostAsk(command, cwd: workspace, home: home, store: store)
        guard case .deny(let still) = granted.decision else {
            Issue.record("typed deny hard bind must not honor matchingView grant on Host Ask, got \(granted.decision)")
            return
        }
        #expect(still.ruleID == ruleID)
        #expect(granted.boundReview == .deny(still))
    }
}

private func peek(
    _ command: String,
    cwd: URL,
    home: HomeDirectory
) async throws -> EvaluationResult {
    await peek(
        command,
        cwd: cwd,
        home: home,
        store: AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory())
    )
}

private func peek(
    _ command: String,
    cwd: URL,
    home: HomeDirectory,
    store: AllowOnceStore
) async -> EvaluationResult {
    await GatedEvaluate().peek(
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
        cwd: WorkingDirectory(validating: cwd.path),
        home: home,
        store: store,
        now: Date(timeIntervalSince1970: 1_700_000_000),
        allowlist: { .empty }
    )
}

private func spendHostAsk(
    _ command: String,
    cwd: URL,
    home: HomeDirectory,
    store: AllowOnceStore
) async -> EvaluationResult {
    await GatedEvaluate().spendHostAsk(
        command: ShellCommand(rawValue: command),
        cwd: WorkingDirectory(validating: cwd.path),
        home: home,
        store: store,
        now: Date(timeIntervalSince1970: 1_700_000_000),
        allowlist: { .empty }
    )
}

private func isolatedWorkspace() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-typed-load-ws-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
