import Testing
import RVDomain
@testable import RVEngine

@Suite("ApplyGitSemantics")
struct ApplyGitSemanticsTests {
    @Test func checkoutCreate_staysAllowUnderDefaultPolicy() throws {
        let pack = try runPack("git checkout -b feature")
        #expect(pack.decision == .allow)
        let composed = applyGitSemantics(
            pack: pack,
            command: ShellCommand(rawValue: "git checkout -b feature")
        )
        #expect(composed.decision == .allow)
        #expect(
            composed.analysis
                == .git(.createBranch(name: "feature", startPoint: nil, force: false))
        )
        #expect(composed.boundReview == nil)
    }

    @Test func checkoutDiscard_keepsPackDeny() throws {
        let pack = try runPack("git checkout -- file.swift")
        guard case .deny(let packDeny) = pack.decision else {
            Issue.record("sample pack must deny checkout --")
            return
        }
        let composed = applyGitSemantics(
            pack: pack,
            command: ShellCommand(rawValue: "git checkout -- file.swift")
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("composed must keep pack deny")
            return
        }
        #expect(deny.ruleID == packDeny.ruleID)
        guard case .git(.discardWorktree(let pathspecs, _)) = composed.analysis else {
            Issue.record("expected discard analysis")
            return
        }
        #expect(pathspecs == ["file.swift"])
    }

    @Test func unknownSyntax_neverBecomesMorePermissive() throws {
        let command = "git --weird-flag reset --hard"
        #expect(analyzeGit(ShellCommand(rawValue: command)) == .unknown)
        let packDeny = EvaluationResult(
            outcome: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                    reason: "git reset --hard destroys uncommitted changes"
                ),
                matched: nil
            ),
            matchingView: MatchingView(command)
        )
        let composedDeny = applyGitSemantics(
            pack: packDeny,
            command: ShellCommand(rawValue: command)
        )
        #expect(composedDeny.decision == packDeny.decision)
        #expect(composedDeny.analysis == .unknown)

        let echo = try runPack("echo hello")
        let composedEcho = applyGitSemantics(
            pack: echo,
            command: ShellCommand(rawValue: "echo hello")
        )
        #expect(composedEcho.decision == echo.decision)
        #expect(composedEcho.analysis == .unknown)
    }

    @Test func forcePushPackMiss_isDeniedBySemantics() throws {
        let command = "git push --force-with-lease origin main"
        let pack = try runPack(command)
        #expect(pack.decision == .allow)
        let composed = applyGitSemantics(
            pack: pack,
            command: ShellCommand(rawValue: command),
            context: GitAnalysisContext(isSharedBranch: true)
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("force-with-lease to main must deny")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.remoteSharedBranch.ruleID)
        #expect(composed.boundReview == .deny(ActionPolicyEngine.Builtin.remoteSharedBranch))
        #expect(composed.analysis != .unknown)
    }

    @Test func forcePushPrivateBranch_carriesMandatoryHumanBoundReview() throws {
        let command = "git push --force-with-lease origin feature"
        let pack = try runPack(command)
        #expect(pack.decision == .allow)
        #expect(pack.boundReview == nil)
        let composed = applyGitSemantics(
            pack: pack,
            command: ShellCommand(rawValue: command)
        )
        let deny = ActionPolicyEngine.Builtin.remoteBranchAsk
        #expect(composed.decision == .deny(deny))
        #expect(composed.boundReview == .mandatoryHuman(deny))
    }

    @Test func unforcedPush_leavesBoundReviewNil() throws {
        let command = "git push origin feature"
        let pack = try runPack(command)
        #expect(pack.decision == .allow)
        let composed = applyGitSemantics(
            pack: pack,
            command: ShellCommand(rawValue: command)
        )
        #expect(composed.decision == .allow)
        #expect(composed.boundReview == nil)
    }

    @Test func coreGitDisabled_doesNotAddSemanticDeny() throws {
        let pack = try runPack("echo hello")
        #expect(pack.decision == .allow)
        let composed = applyGitSemantics(
            pack: EvaluationResult(
                outcome: .plain,
                matchingView: MatchingView("git reset --hard")
            ),
            command: ShellCommand(rawValue: "git reset --hard"),
            enabledPacks: []
        )
        #expect(composed.decision == .allow)
        guard case .git(.reset(let mode, _)) = composed.analysis else {
            Issue.record("analysis still attaches when packs are off")
            return
        }
        #expect(mode == .hard)
        #expect(pack.decision == .allow)
    }

    @Test func packIndeterminate_isNotLifted() {
        let pack = EvaluationResult(
            outcome: .indeterminate(.corePacksUnavailable),
            matchingView: MatchingView("git reset --hard")
        )
        let composed = applyGitSemantics(
            pack: pack,
            command: ShellCommand(rawValue: "git reset --hard")
        )
        #expect(composed.decision == .indeterminate(.corePacksUnavailable))
        guard case .git(.reset(let mode, _)) = composed.analysis else {
            Issue.record("analysis may still attach")
            return
        }
        #expect(mode == .hard)
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
