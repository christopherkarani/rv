import Foundation
import Testing
import RVDomain
@testable import RVPolicy

struct RebaseRecoveryTests {
    @Test func discardWorktreeIsEligible() {
        #expect(RebaseRecovery.isEligible(result: checkoutDiscardDeny()))
    }

    @Test func restoreWorktreeIsEligible() {
        let result = deny(
            pack: .coreGit,
            pattern: "restore-worktree",
            analysis: .git(.restore(pathspecs: ["."], staged: false, worktree: true, source: nil))
        )
        #expect(RebaseRecovery.isEligible(result: result))
    }

    @Test func restoreStagedOnlyIsNotEligible() {
        let result = deny(
            pack: .coreGit,
            pattern: "restore-staged",
            analysis: .git(.restore(pathspecs: ["."], staged: true, worktree: false, source: nil))
        )
        #expect(RebaseRecovery.isEligible(result: result) == false)
    }

    @Test func resetHardIsNeverEligible() {
        let result = deny(
            pack: .coreGit,
            pattern: "reset-hard",
            analysis: .git(.reset(mode: .hard, target: nil))
        )
        #expect(RebaseRecovery.isEligible(result: result) == false)
    }

    @Test func builtinWorkingTreeDiscardWithoutGitActionIsNotEligible() {
        let result = EvaluationResult(
            outcome: .deny(ActionPolicyEngine.Builtin.workingTreeDiscard, matched: nil),
            matchingView: "git checkout -- file",
            analysis: .unknown
        )
        #expect(RebaseRecovery.isEligible(result: result) == false)
    }

    @Test func builtinWorkingTreeDiscardWithDiscardWorktreeIsEligible() {
        let result = EvaluationResult(
            outcome: .deny(ActionPolicyEngine.Builtin.workingTreeDiscard, matched: nil),
            matchingView: "git checkout -- file",
            analysis: .git(.discardWorktree(pathspecs: ["file"], source: nil))
        )
        #expect(RebaseRecovery.isEligible(result: result))
    }

    @Test func packRuleWithoutGitActionIsEligible() {
        for pattern in ["checkout-discard", "checkout-ref-discard", "restore-worktree", "restore-worktree-explicit"] {
            let result = deny(pack: .coreGit, pattern: pattern, analysis: .unknown)
            #expect(RebaseRecovery.isEligible(result: result), Comment(rawValue: pattern))
        }
    }

    @Test func unwrapLimitedIsNeverEligibleEvenWithCheckoutDiscardRule() {
        let result = EvaluationResult(
            outcome: .deny(
                Deny(ruleID: RuleID(pack: .coreGit, pattern: "checkout-discard"), reason: "checkout"),
                matched: nil
            ),
            matchingView: "bash -c git checkout -- file",
            analysis: .unwrapLimited.wrapping([.bash])
        )
        #expect(RebaseRecovery.isEligible(result: result) == false)
    }

    @Test func secretsDenyIsNeverEligibleEvenWithDiscardWorktree() {
        let result = EvaluationResult(
            outcome: .deny(
                Deny(ruleID: RuleID(pack: .coreSecrets, pattern: "ssh-private-key"), reason: "secret"),
                matched: nil
            ),
            matchingView: "git checkout -- id_rsa",
            analysis: .git(.discardWorktree(pathspecs: ["id_rsa"], source: nil))
        )
        #expect(RebaseRecovery.isEligible(result: result) == false)
    }

    @Test func protectedPathDenyIsNeverEligible() {
        let target = FilesystemTarget(
            apparent: ".ssh/id_rsa",
            canonical: "/isolated-home/.ssh/id_rsa",
            scope: .protectedPath,
            kind: .unknown,
            resolution: .resolved
        )
        let result = EvaluationResult(
            outcome: .deny(ActionPolicyEngine.Builtin.protectedPath, matched: nil),
            matchingView: "rm -f .ssh/id_rsa",
            analysis: .filesystem(.delete(targets: [target], recursive: false, force: true))
        )
        #expect(RebaseRecovery.isEligible(result: result) == false)
    }

    @Test func otherPackCheckoutDiscardPatternIsNotEligible() {
        let result = deny(
            pack: .systemDisk,
            pattern: "checkout-discard",
            analysis: .unknown
        )
        #expect(RebaseRecovery.isEligible(result: result) == false)
    }

    @Test func forcePushIsNeverEligible() {
        let result = deny(
            pack: .coreGit,
            pattern: "push-force-long",
            analysis: .git(.push(remote: "origin", refspec: "main", force: .force, delete: false))
        )
        #expect(RebaseRecovery.isEligible(result: result) == false)
    }

    @Test func decideAllowsEligibleDiscardBeforeWorkingTreePin() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = EvaluationResult(
            outcome: .deny(ActionPolicyEngine.Builtin.workingTreeDiscard, matched: nil),
            matchingView: "git checkout -- file",
            analysis: .git(.discardWorktree(pathspecs: ["file"], source: nil))
        )
        #expect(RulePinning.blocksAllowOverride(denied))
        let withoutRebase = PolicyGate.decide(
            denied,
            cwd: wd("/tmp/ws"),
            allowlist: .empty,
            grant: .pending,
            now: now
        )
        #expect(withoutRebase.override == .none)
        guard case .deny = withoutRebase.result.decision else {
            Issue.record("pin must keep builtin discard denied without rebase")
            return
        }
        let withRebase = PolicyGate.decide(
            denied,
            cwd: wd("/tmp/ws"),
            allowlist: .empty,
            grant: .none,
            now: now,
            rebaseInProgress: true
        )
        #expect(withRebase.override == .rebaseRecovery)
        #expect(withRebase.result.decision == .allow)
    }

    @Test func decideKeepsUnwrapLimitedDeniedDuringRebase() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = EvaluationResult(
            outcome: .deny(
                Deny(ruleID: RuleID(pack: .coreGit, pattern: "checkout-discard"), reason: "checkout"),
                matched: nil
            ),
            matchingView: "bash -c git checkout -- file",
            analysis: .unwrapLimited.wrapping([.bash])
        )
        let gated = PolicyGate.decide(
            denied,
            cwd: wd("/tmp/ws"),
            allowlist: .empty,
            grant: .none,
            now: now,
            rebaseInProgress: true
        )
        #expect(gated.override == .none)
        guard case .deny = gated.result.decision else {
            Issue.record("unwrap-limited checkout must stay deny during rebase")
            return
        }
    }

    @Test func decideKeepsResetHardDeniedDuringRebase() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = deny(
            pack: .coreGit,
            pattern: "reset-hard",
            analysis: .git(.reset(mode: .hard, target: nil))
        )
        let gated = PolicyGate.decide(
            denied,
            cwd: wd("/tmp/ws"),
            allowlist: .empty,
            grant: .none,
            now: now,
            rebaseInProgress: true
        )
        #expect(gated.override == .none)
        guard case .deny = gated.result.decision else {
            Issue.record("reset --hard must stay deny during rebase")
            return
        }
    }

    @Test func applyRebaseRecoveryDoesNotConsumeStore() async throws {
        let store = try isolatedRebaseStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = checkoutDiscardDeny()
        try await store.insertGranted(
            matchingView: denied.matchingView,
            cwd: wd("/tmp/ws"),
            now: now
        )
        let gated = await PolicyGate.apply(
            denied,
            cwd: wd("/tmp/ws"),
            store: store,
            now: now,
            rebaseInProgress: true
        )
        #expect(gated.override == .rebaseRecovery)
        #expect(gated.result.decision == .allow)
        let leftover = await store.consume(
            matchingView: denied.matchingView,
            cwd: wd("/tmp/ws"),
            now: now
        )
        guard case .consumed = leftover else {
            Issue.record("rebase recovery must not spend allow-once")
            return
        }
    }
}

private func checkoutDiscardDeny() -> EvaluationResult {
    deny(
        pack: .coreGit,
        pattern: "checkout-discard",
        analysis: .git(.discardWorktree(pathspecs: ["file"], source: nil))
    )
}

private func deny(pack: PackID, pattern: String, analysis: SemanticAnalysis) -> EvaluationResult {
    EvaluationResult(
        outcome: .deny(
            Deny(ruleID: RuleID(pack: pack, pattern: pattern), reason: pattern),
            matched: nil
        ),
        matchingView: MatchingView(pattern),
        analysis: analysis
    )
}

private func isolatedRebaseStore() throws -> AllowOnceStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-rebase-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return AllowOnceStore(baseDirectory: root)
}
