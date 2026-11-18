import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVService

/// The ceiling reaches the hook verdict through `PolicyStoreInputs.gather`,
/// not only `PolicyWorkspace.loadEffectiveRules`.
@Suite("Policy ceiling at the gate")
struct PolicyCeilingGateTests {
    private let softResetCeiling = """
        schema_version = 1

        [[rule]]
        id = "typed.git:no-soft-reset"
        verdict = "deny"
        predicate = "gitReset"
        mode = "soft"
        """

    @Test func ceilingDeny_reachesTheHookVerdict_whenEveryLayerIsSilent() async throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let command = "git reset --soft HEAD~1"
        let baseline = await hook(command, home: home)
        if case .deny(let deny) = baseline.decision {
            #expect(deny.ruleID.pattern != "no-soft-reset")
        }
        try writeCeiling(softResetCeiling, home: home)
        let capped = await hook(command, home: home)
        guard case .deny(let deny) = capped.decision else {
            Issue.record("a ceiling deny must reach the hook verdict: \(capped.decision)")
            return
        }
        #expect(deny.ruleID.pattern == "no-soft-reset", "\(deny.ruleID.rawValue)")
    }

    @Test func corruptCeiling_deniesWithTypedRulesInvalid() async throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        try writeCeiling("schema_version = 1\nbogus = 1\n", home: home)
        let result = await hook("git status", home: home)
        guard case .deny(let deny) = result.decision else {
            Issue.record("a corrupt ceiling must fail closed: \(result.decision)")
            return
        }
        #expect(deny.ruleID == BuiltinRule.typedRulesInvalid.ruleID)
    }

    private func hook(_ command: String, home: HomeDirectory) async -> EvaluationResult {
        await GatedEvaluate().apply(
            command: ShellCommand(rawValue: command),
            cwd: WorkingDirectory(validating: home.rawValue),
            home: home,
            grants: EphemeralAllowOnceTable(),
            now: Date(timeIntervalSince1970: 1_800_000_000),
            allowlist: { .empty },
            host: .hook(.claude)
        )
    }

    private func writeCeiling(_ text: String, home: HomeDirectory) throws {
        let config = RVPolicyPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try text.write(to: RVPolicyPaths.policyCeilingFile(inConfigDir: config), atomically: true, encoding: .utf8)
    }
}
