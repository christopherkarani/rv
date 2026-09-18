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
    func project_unlockableAndGrayAreaFollowHostProfile(_ host: HookHost) throws {
        let workspace = try #require(cwd)
        let unlocked = HookAuthorization.project(
            host: host,
            result: EvaluationResult(
                outcome: .deny(packDeny, matched: nil),
                matchingView: MatchingView("git reset --hard")
            ),
            cwd: workspace,
            bound: .deny(packDeny)
        )
        let gray = HookAuthorization.project(
            host: host,
            result: EvaluationResult(
                outcome: .plain,
                matchingView: MatchingView("git push --force origin topic")
            ),
            cwd: workspace,
            bound: .mandatoryHuman(ActionPolicyEngine.Builtin.remoteBranchAsk)
        )

        switch HostNativeAsk.profile(for: host).pause {
        case .spendFirst:
            #expect(unlocked == .ask(.hostNative))
            #expect(unlocked.shouldRecordPending)
            #expect(unlocked.shouldMintUnlock == false)
            #expect(gray == .ask(.hostNative))
            #expect(gray.shouldMintUnlock == false)
        case .noPause, .leftoverAskForbidden:
            #expect(unlocked == .denyUnlockable(packDeny))
            #expect(unlocked.shouldMintUnlock)
            #expect(unlocked.shouldRecordPending == false)
            #expect(gray == .allow)
            #expect(gray.shouldMintUnlock == false)
            #expect(gray.shouldRecordPending == false)
        }
    }

    @Test func project_spendFirstUnlockableAsksAndDoesNotMint() throws {
        let workspace = try #require(cwd)
        let result = EvaluationResult(
            outcome: .deny(packDeny, matched: nil),
            matchingView: MatchingView("git reset --hard")
        )
        let auth = HookAuthorization.project(
            host: .pi,
            result: result,
            cwd: workspace,
            bound: .deny(packDeny)
        )
        #expect(auth == .ask(.hostNative))
        #expect(auth.shouldRecordPending)
        #expect(auth.shouldMintUnlock == false)
    }

    @Test func project_noPauseUnlockableIsDenyUnlockable() throws {
        let workspace = try #require(cwd)
        let result = EvaluationResult(
            outcome: .deny(packDeny, matched: nil),
            matchingView: MatchingView("git reset --hard")
        )
        let auth = HookAuthorization.project(
            host: .grok,
            result: result,
            cwd: workspace,
            bound: .deny(packDeny)
        )
        #expect(auth == .denyUnlockable(packDeny))
        #expect(auth.shouldMintUnlock)
        #expect(auth.shouldRecordPending == false)
        #expect(auth.verdict == .deny)
    }

    @Test func project_pinnedSecretIsDenyPinned() throws {
        let workspace = try #require(cwd)
        let result = EvaluationResult(
            outcome: .deny(secret, matched: nil),
            matchingView: MatchingView("cat ~/.aws/credentials")
        )
        let auth = HookAuthorization.project(
            host: .pi,
            result: result,
            cwd: workspace,
            bound: .deny(secret)
        )
        #expect(auth == .denyPinned(secret))
        #expect(auth.shouldMintUnlock == false)
        #expect(auth.shouldRecordPending == false)
    }
}
