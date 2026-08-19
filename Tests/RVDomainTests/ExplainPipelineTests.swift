import Testing
@testable import RVDomain

struct ExplainPipelineTests {
    @Test func denyWalksFourSteps() {
        let rule = RuleID(pack: .coreGit, pattern: "reset-hard")
        let steps = explainSteps(
            from: EvaluationResult(
                decision: .deny(Deny(ruleID: rule, reason: "blocked"))
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
                from: EvaluationResult(decision: .indeterminate(.commandTooLarge))
            ) == [.normalize, .default(.incomplete)]
        )
    }

    @Test func quickRejectSkipsScan() {
        #expect(
            explainSteps(
                from: EvaluationResult(decision: .allow, quickRejected: true)
            ) == [.normalize, .quickReject(.skipped), .default(.allow)]
        )
    }

    @Test func safeHitProjectsRuleID() {
        let rule = RuleID(pack: .coreGit, pattern: "checkout-new-branch")
        #expect(
            explainSteps(
                from: EvaluationResult(
                    decision: .allow,
                    matchedSafe: SafeMatch(packID: .coreGit, patternName: "checkout-new-branch")
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
                    decision: .allow,
                    matched: RuleMatch(
                        ruleID: rule,
                        packID: .coreGit,
                        patternName: "stash-drop",
                        severity: .medium,
                        reason: "git stash drop deletes a single stash"
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
                    decision: .allow,
                    matched: RuleMatch(
                        ruleID: match,
                        packID: .coreGit,
                        patternName: "stash-drop",
                        severity: .medium,
                        reason: "git stash drop deletes a single stash"
                    ),
                    matchedSafe: SafeMatch(packID: .coreFilesystem, patternName: "tmp-scratch")
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
            explainSteps(from: EvaluationResult(decision: .allow)) == [
                .normalize,
                .quickReject(.scanned),
                .safe(.none),
                .destructive(.none),
                .default(.allow),
            ]
        )
    }
}
