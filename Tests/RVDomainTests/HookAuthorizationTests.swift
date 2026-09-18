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
    func project_matchesHostAskVerdict(_ host: HookHost) throws {
        let workspace = try #require(cwd)
        let unlocked = EvaluationResult(
            outcome: .deny(packDeny, matched: nil),
            matchingView: MatchingView("git reset --hard")
        )
        let human = EvaluationResult(
            outcome: .plain,
            matchingView: MatchingView("git push --force origin topic")
        )
        let secretResult = EvaluationResult(
            outcome: .deny(secret, matched: nil),
            matchingView: MatchingView("cat ~/.aws/credentials")
        )

        let rows: [(EvaluationResult, BoundReview)] = [
            (unlocked, .deny(packDeny)),
            (human, .mandatoryHuman(ActionPolicyEngine.Builtin.remoteBranchAsk)),
            (secretResult, .deny(secret)),
            (unlocked, .allow),
        ]
        for (result, bound) in rows {
            let auth = HookAuthorization.project(
                host: host,
                result: result,
                cwd: workspace,
                bound: bound
            )
            #expect(
                auth.verdict
                    == HostNativeAsk.hostAskVerdict(
                        host: host,
                        result: result,
                        cwd: workspace,
                        bound: bound
                    )
            )
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
