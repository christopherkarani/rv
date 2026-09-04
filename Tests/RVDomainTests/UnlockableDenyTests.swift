import Testing
import RVDomain

struct UnlockableDenyTests {
    @Test(arguments: UnlockableDenyTable.rows)
    func matches(_ row: UnlockableDenyTable.Row) {
        #expect(
            UnlockableDeny.matches(result: row.result, cwd: row.cwd) == row.expected
        )
    }
}

enum UnlockableDenyTable {
    struct Row: Sendable, CustomTestStringConvertible {
        var label: String
        var result: EvaluationResult
        var cwd: WorkingDirectory?
        var expected: Bool

        var testDescription: String { label }
    }

    static let workspace = WorkingDirectory(validating: "/tmp/ws")

    static let packDeny = Deny(
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
        reason: "git reset --hard destroys uncommitted changes"
    )

    static var rows: [Row] {
        [
            Row(
                label: "core.git reset-hard with cwd",
                result: EvaluationResult(
                    outcome: .deny(packDeny, matched: nil),
                    matchingView: MatchingView("git reset --hard")
                ),
                cwd: workspace,
                expected: true
            ),
            Row(
                label: "core.git reset-hard plus unwrapLimited",
                result: EvaluationResult(
                    outcome: .deny(packDeny, matched: nil),
                    matchingView: MatchingView("bash -c git reset --hard"),
                    analysis: .unwrapLimited.wrapping([.bash])
                ),
                cwd: workspace,
                expected: false
            ),
            Row(
                label: "pack-floor deny plus protectedPath",
                result: EvaluationResult(
                    outcome: .deny(
                        Deny(
                            ruleID: RuleID(
                                pack: .coreFilesystem,
                                pattern: "redirect-truncate-root-home"
                            ),
                            reason: "Redirect truncate to home path"
                        ),
                        matched: nil
                    ),
                    matchingView: MatchingView("echo leaked > ~/.ssh/config"),
                    analysis: .filesystem(
                        .overwrite(
                            targets: [
                                FilesystemTarget(
                                    apparent: "~/.ssh/config",
                                    canonical: "/home/.ssh/config",
                                    scope: .protectedPath,
                                    kind: .unknown
                                ),
                            ]
                        )
                    )
                ),
                cwd: workspace,
                expected: false
            ),
            Row(
                label: "core.secrets",
                result: EvaluationResult(
                    outcome: .deny(
                        Deny(
                            ruleID: RuleID(pack: .coreSecrets, pattern: "aws-credentials"),
                            reason: "secret path"
                        ),
                        matched: nil
                    ),
                    matchingView: MatchingView("cat ~/.aws/credentials")
                ),
                cwd: workspace,
                expected: false
            ),
            Row(
                label: "builtin.action",
                result: EvaluationResult(
                    outcome: .deny(HostNativeAsk.leftoverAskDeny, matched: nil),
                    matchingView: MatchingView("git reset --hard")
                ),
                cwd: workspace,
                expected: false
            ),
            Row(
                label: "mandatoryHuman remote-branch-ask with cwd",
                result: EvaluationResult(
                    outcome: .deny(ActionPolicyEngine.Builtin.remoteBranchAsk, matched: nil),
                    matchingView: MatchingView("git push --force-with-lease origin feature"),
                    analysis: .unknown,
                    boundReview: .mandatoryHuman(ActionPolicyEngine.Builtin.remoteBranchAsk)
                ),
                cwd: workspace,
                expected: true
            ),
            Row(
                label: "mandatoryHuman remote-branch-ask missing cwd",
                result: EvaluationResult(
                    outcome: .deny(ActionPolicyEngine.Builtin.remoteBranchAsk, matched: nil),
                    matchingView: MatchingView("git push --force-with-lease origin feature"),
                    analysis: .unknown,
                    boundReview: .mandatoryHuman(ActionPolicyEngine.Builtin.remoteBranchAsk)
                ),
                cwd: nil,
                expected: false
            ),
            Row(
                label: "mandatoryHuman plus unwrapLimited",
                result: EvaluationResult(
                    outcome: .deny(ActionPolicyEngine.Builtin.remoteBranchAsk, matched: nil),
                    matchingView: MatchingView("bash -c git push --force-with-lease origin feature"),
                    analysis: .unwrapLimited.wrapping([.bash]),
                    boundReview: .mandatoryHuman(ActionPolicyEngine.Builtin.remoteBranchAsk)
                ),
                cwd: workspace,
                expected: false
            ),
            Row(
                label: "builtin.action deny without boundReview",
                result: EvaluationResult(
                    outcome: .deny(ActionPolicyEngine.Builtin.remoteBranchAsk, matched: nil),
                    matchingView: MatchingView("git push --force-with-lease origin feature")
                ),
                cwd: workspace,
                expected: false
            ),
            Row(
                label: "missing cwd",
                result: EvaluationResult(
                    outcome: .deny(packDeny, matched: nil),
                    matchingView: MatchingView("git reset --hard")
                ),
                cwd: nil,
                expected: false
            ),
            Row(
                label: "empty matching view",
                result: EvaluationResult(
                    outcome: .deny(packDeny, matched: nil)
                ),
                cwd: workspace,
                expected: false
            ),
            Row(
                label: "indeterminate",
                result: EvaluationResult(
                    outcome: .indeterminate(.commandTooLarge),
                    matchingView: MatchingView("git reset --hard")
                ),
                cwd: workspace,
                expected: false
            ),
            Row(
                label: "pack allow",
                result: EvaluationResult(
                    outcome: .plain,
                    matchingView: MatchingView("git status")
                ),
                cwd: workspace,
                expected: false
            ),
        ]
    }
}
