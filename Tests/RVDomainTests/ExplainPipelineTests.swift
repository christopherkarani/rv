import Testing
@testable import RVDomain

struct ExplainPipelineTests {
    @Test func denyWalksFourSteps() {
        let rule = RuleID(pack: .coreGit, pattern: "reset-hard")
        let steps = explainSteps(
            from: EvaluationResult(
                outcome: .deny(Deny(ruleID: rule, reason: "blocked"), matched: nil)
            )
        )
        #expect(
            steps == [
                .normalize,
                .quickReject(.scanned),
                .safe(.none),
                .destructive(.rule(rule)),
            ]
        )
        #expect(steps.map(\.id) == [.normalize, .quickReject, .safe, .destructive])
        #expect(steps.map(\.id.rawValue) == [
            "normalize", "quick-reject", "safe", "destructive",
        ])
    }

    @Test func indeterminateStopsAtIncomplete() {
        #expect(
            explainSteps(
                from: EvaluationResult(outcome: .indeterminate(.commandTooLarge))
            ) == [.normalize, .default(.incomplete)]
        )
    }

    @Test func quickRejectSkipsScan() {
        #expect(
            explainSteps(
                from: EvaluationResult(outcome: .quickRejected)
            ) == [.normalize, .quickReject(.skipped), .default(.allow)]
        )
    }

    @Test func safeHitProjectsRuleID() {
        let rule = RuleID(pack: .coreGit, pattern: "checkout-new-branch")
        #expect(
            explainSteps(
                from: EvaluationResult(
                    outcome: .safeOnly(SafeMatch(packID: .coreGit, patternName: "checkout-new-branch"))
                )
            ) == [
                .normalize,
                .quickReject(.scanned),
                .safe(.rule(rule)),
                .default(.allow),
            ]
        )
    }

    @Test func mediumAllowWalksDestructiveThenDefault() {
        let rule = RuleID(pack: .coreGit, pattern: "stash-drop")
        #expect(
            explainSteps(
                from: EvaluationResult(
                    outcome: .hit(
                        RuleMatch(
                            ruleID: rule,
                            packID: .coreGit,
                            patternName: "stash-drop",
                            severity: .medium,
                            reason: "git stash drop deletes a single stash"
                        ),
                        safe: nil
                    )
                )
            ) == [
                .normalize,
                .quickReject(.scanned),
                .safe(.none),
                .destructive(.rule(rule)),
                .default(.allow),
            ]
        )
    }

    @Test func safeHitSurvivesAlongsideMediumMatch() {
        let safe = RuleID(pack: .coreFilesystem, pattern: "tmp-scratch")
        let match = RuleID(pack: .coreGit, pattern: "stash-drop")
        #expect(
            explainSteps(
                from: EvaluationResult(
                    outcome: .hit(
                        RuleMatch(
                            ruleID: match,
                            packID: .coreGit,
                            patternName: "stash-drop",
                            severity: .medium,
                            reason: "git stash drop deletes a single stash"
                        ),
                        safe: SafeMatch(packID: .coreFilesystem, patternName: "tmp-scratch")
                    )
                )
            ) == [
                .normalize,
                .quickReject(.scanned),
                .safe(.rule(safe)),
                .destructive(.rule(match)),
                .default(.allow),
            ]
        )
    }

    @Test func unmatchedAllowWalksFullDefault() {
        #expect(
            explainSteps(from: EvaluationResult(outcome: .plain)) == [
                .normalize,
                .quickReject(.scanned),
                .safe(.none),
                .destructive(.none),
                .default(.allow),
            ]
        )
    }

    @Test func denyWithMatchedStillShowsNoSafeStage() {
        let rule = RuleID(pack: .coreGit, pattern: "reset-hard")
        let safeRule = RuleID(pack: .coreFilesystem, pattern: "tmp-scratch")
        let steps = explainSteps(
            from: EvaluationResult(
                outcome: .deny(
                    Deny(ruleID: rule, reason: "blocked"),
                    matched: RuleMatch(
                        ruleID: rule,
                        packID: .coreGit,
                        patternName: "reset-hard",
                        severity: .critical,
                        reason: "blocked"
                    )
                )
            )
        )
        #expect(
            steps == [
                .normalize,
                .quickReject(.scanned),
                .safe(.none),
                .destructive(.rule(rule)),
            ]
        )
        #expect(steps.contains { $0 == .safe(.rule(safeRule)) } == false)
    }
}
