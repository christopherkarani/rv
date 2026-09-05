import Testing
import RVDomain
@testable import RVEngine

@Suite("ApplyGitSemanticsTypedRule")
struct ApplyGitSemanticsTypedRuleTests {
    @Test func typedDeny_forceWithLeaseFeature_deniesWithTypedRuleID() throws {
        let command = "git push --force-with-lease origin feature"
        let pack = try runPack(command)
        #expect(pack.decision == .allow)
        let rule = TypedRule(
            id: RuleID(pack: .coreGit, pattern: "deny-force-with-lease-feature"),
            predicate: .gitPush(force: .forceWithLease, branch: "feature"),
            verdict: .deny,
            origin: .machine
        )
        let composed = applyGitSemantics(
            pack: pack,
            command: ShellCommand(rawValue: command),
            policy: EffectiveActionPolicy(rules: [rule])
        )
        guard case .git(.push(_, let refspec, .forceWithLease, false)) = composed.analysis else {
            Issue.record("proof command must parse as force-with-lease, got \(composed.analysis)")
            return
        }
        #expect(refspec == "feature")
        guard case .deny(let deny) = composed.decision else {
            Issue.record("typed deny must deny force-with-lease feature, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == rule.id)
        #expect(deny.ruleID != ActionPolicyEngine.Builtin.remoteBranchAsk.ruleID)
        guard case .deny(let bound) = composed.boundReview else {
            Issue.record("typed hard deny must bind .deny, got \(String(describing: composed.boundReview))")
            return
        }
        #expect(bound.ruleID == rule.id)
    }

    @Test func typedAllow_cannotBeatSharedBranchHardDeny() throws {
        let command = "git push --force-with-lease origin main"
        let pack = try runPack(command)
        #expect(pack.decision == .allow)
        let rule = TypedRule(
            id: RuleID(pack: .coreGit, pattern: "allow-force-with-lease-main"),
            predicate: .gitPush(force: .forceWithLease, branch: "main"),
            verdict: .allow,
            origin: .machine
        )
        let composed = applyGitSemantics(
            pack: pack,
            command: ShellCommand(rawValue: command),
            context: GitAnalysisContext(isSharedBranch: true),
            policy: EffectiveActionPolicy(rules: [rule])
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("typed allow must not beat shared-branch hard deny, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.remoteSharedBranch.ruleID)
        #expect(composed.boundReview == .deny(ActionPolicyEngine.Builtin.remoteSharedBranch))
    }

    @Test func applySemantics_forwardsTypedDenyForForceWithLeaseFeature() throws {
        let command = "git push --force-with-lease origin feature"
        let pack = try runPack(command)
        #expect(pack.decision == .allow)
        let rule = TypedRule(
            id: RuleID(pack: .coreGit, pattern: "deny-force-with-lease-feature"),
            predicate: .gitPush(force: .forceWithLease, branch: "feature"),
            verdict: .deny,
            origin: .machine
        )
        let composed = applySemantics(
            pack: pack,
            command: ShellCommand(rawValue: command),
            policy: EffectiveActionPolicy(rules: [rule])
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("applySemantics must forward typed deny, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == rule.id)
        #expect(deny.ruleID != ActionPolicyEngine.Builtin.remoteBranchAsk.ruleID)
    }
}

private func runPack(_ command: String) throws -> EvaluationResult {
    let packs = [
        PackSnapshot(
            id: .coreFilesystem,
            name: "fs",
            description: "fs",
            keywords: ["rm"],
            safe: [],
            destructive: [
                DestructiveRule(
                    name: "rm-rf-general",
                    pattern: #"rm\s+-rf"#,
                    severity: .high,
                    reason: "rm -rf is destructive"
                ),
            ]
        ),
        PackSnapshot(
            id: .coreGit,
            name: "git",
            description: "git",
            keywords: ["git"],
            safe: [NamedPattern(name: "checkout-new-branch", pattern: #"git\s+checkout\s+-b\s+"#)],
            destructive: [
                DestructiveRule(
                    name: "reset-hard",
                    pattern: #"git\s+reset\s+--hard"#,
                    severity: .critical,
                    reason: "git reset --hard destroys uncommitted changes"
                ),
                DestructiveRule(
                    name: "checkout-discard",
                    pattern: #"git\s+checkout\s+--"#,
                    severity: .high,
                    reason: "git checkout -- discards uncommitted changes"
                ),
            ]
        ),
    ]
    let engine = ICUPatternEngine()
    let compiled = try CompiledPacks<ICUCompiledPattern>.compile(packs: packs, using: engine)
    return evaluate(
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
        packs: packs,
        patterns: engine,
        compiled: compiled
    )
}
