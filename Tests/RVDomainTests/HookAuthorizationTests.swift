import Testing
import RVDomain

@Suite("HookAuthorization")
struct HookAuthorizationTests {
    private let cwd = WorkingDirectory(validating: "/tmp/ws")
    private let packDeny = Deny(
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
        reason: "git reset --hard destroys uncommitted changes"
    )
    private let secret = Deny(
        ruleID: RuleID(pack: .coreSecrets, pattern: "aws-credentials"),
        reason: "secret path"
    )

    @Test(arguments: UnlockableDenyTable.rows)
    func isUnlockable_matchesAbsorbedTable(_ row: UnlockableDenyTable.Row) {
        #expect(
            HookAuthorization.isUnlockable(result: row.result, cwd: row.cwd) == row.expected
        )
        #expect(
            UnlockableDeny.matches(result: row.result, cwd: row.cwd)
                == HookAuthorization.isUnlockable(result: row.result, cwd: row.cwd)
        )
    }

    @Test func policyGateAccess_skipsHardBoundDenyOnly() {
        let unlocked = EvaluationResult(
            outcome: .deny(packDeny, matched: nil),
            matchingView: MatchingView("git reset --hard")
        )
        #expect(HookAuthorization.policyGateAccess(for: unlocked) == .consider)

        let hard = EvaluationResult(
            outcome: .deny(packDeny, matched: nil),
            matchingView: MatchingView("git reset --hard"),
            analysis: .unknown,
            boundReview: .deny(packDeny)
        )
        #expect(HookAuthorization.policyGateAccess(for: hard) == .skip)

        let human = EvaluationResult(
            outcome: .deny(ActionPolicyEngine.Builtin.remoteBranchAsk, matched: nil),
            matchingView: MatchingView("git push --force origin topic"),
            analysis: .unknown,
            boundReview: .mandatoryHuman(ActionPolicyEngine.Builtin.remoteBranchAsk)
        )
        #expect(HookAuthorization.policyGateAccess(for: human) == .consider)
    }

    @Test func shouldMintUnlock_isHostFreeAndSkipsHardBind() throws {
        let workspace = try #require(cwd)
        let unlocked = EvaluationResult(
            outcome: .deny(packDeny, matched: nil),
            matchingView: MatchingView("git reset --hard")
        )
        #expect(HookAuthorization.shouldMintUnlock(result: unlocked, cwd: workspace))

        let hard = EvaluationResult(
            outcome: .deny(packDeny, matched: nil),
            matchingView: MatchingView("git reset --hard"),
            analysis: .unknown,
            boundReview: .deny(packDeny)
        )
        #expect(HookAuthorization.shouldMintUnlock(result: hard, cwd: workspace) == false)

        let pinned = EvaluationResult(
            outcome: .deny(secret, matched: nil),
            matchingView: MatchingView("cat ~/.aws/credentials")
        )
        #expect(HookAuthorization.shouldMintUnlock(result: pinned, cwd: workspace) == false)
    }

    @Test(arguments: HookHost.allCases)
    func project_unlockableAndMandatoryHumanAskEveryHost(_ host: HookHost) throws {
        // Step 8B: host-free ASK on both transports (pending row + TTY code).
        let workspace = try #require(cwd)
        let unlocked = HookAuthorization.project(
            result: EvaluationResult(
                outcome: .deny(packDeny, matched: nil),
                matchingView: MatchingView("git reset --hard")
            ),
            cwd: workspace
        )
        let gray = HookAuthorization.project(
            result: EvaluationResult(
                outcome: .plain,
                matchingView: MatchingView("git push --force origin topic"),
                analysis: .unknown,
                boundReview: .mandatoryHuman(ActionPolicyEngine.Builtin.remoteBranchAsk)
            ),
            cwd: workspace
        )
        #expect(unlocked == .ask, "\(host)")
        #expect(unlocked.shouldRecordPending)
        #expect(unlocked.shouldMintUnlock)
        #expect(unlocked.verdict == .ask)
        #expect(gray == .ask, "\(host)")
        #expect(gray.shouldRecordPending)
        #expect(gray.shouldMintUnlock)
        #expect(gray != .allow)
    }

    @Test func project_unlockableAsksAndMints() throws {
        let workspace = try #require(cwd)
        let result = EvaluationResult(
            outcome: .deny(packDeny, matched: nil),
            matchingView: MatchingView("git reset --hard")
        )
        let auth = HookAuthorization.project(result: result, cwd: workspace)
        #expect(auth == .ask)
        #expect(auth.shouldRecordPending)
        #expect(auth.shouldMintUnlock)
    }

    @Test func project_pinnedSecretIsDenyPinned() throws {
        let workspace = try #require(cwd)
        let result = EvaluationResult(
            outcome: .deny(secret, matched: nil),
            matchingView: MatchingView("cat ~/.aws/credentials")
        )
        let auth = HookAuthorization.project(result: result, cwd: workspace)
        #expect(auth == .denyPinned)
        #expect(auth.shouldMintUnlock == false)
        #expect(auth.shouldRecordPending == false)
        #expect(auth.verdict == .deny)
    }

    @Test func project_allowDecisionAllows() throws {
        let workspace = try #require(cwd)
        let result = EvaluationResult(
            outcome: .plain,
            matchingView: MatchingView("git status")
        )
        #expect(HookAuthorization.project(result: result, cwd: workspace) == .allow)
    }

    @Test func project_indeterminateIsDenyPinned() throws {
        let workspace = try #require(cwd)
        let result = EvaluationResult(
            outcome: .indeterminate(.commandTooLarge),
            matchingView: MatchingView("git reset --hard")
        )
        let auth = HookAuthorization.project(result: result, cwd: workspace)
        #expect(auth == .denyPinned)
        #expect(auth.shouldMintUnlock == false)
        #expect(auth.shouldRecordPending == false)
    }
}
