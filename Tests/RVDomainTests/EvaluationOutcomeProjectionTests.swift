import Testing
@testable import RVDomain

struct EvaluationOutcomeProjectionTests {
    private let gitMatch = RuleMatch(
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
        packID: .coreGit,
        patternName: "reset-hard",
        severity: .critical,
        reason: "destroys uncommitted changes"
    )

    @Test func hitProjectsMatchIdentity() {
        let outcome = EvaluationOutcome.hit(gitMatch, safe: nil)
        #expect(outcome.explainRuleID == gitMatch.ruleID)
        #expect(outcome.explainPackID == gitMatch.packID)
    }

    @Test func hitKeepsMatchPackWhenSafeAlsoPresent() {
        let outcome = EvaluationOutcome.hit(
            gitMatch,
            safe: SafeMatch(packID: .coreFilesystem, patternName: "keep")
        )
        #expect(outcome.explainRuleID == gitMatch.ruleID)
        #expect(outcome.explainPackID == gitMatch.packID)
    }

    @Test func safeOnlyProjectsPackWithoutRule() {
        let safe = SafeMatch(packID: .coreGit, patternName: "checkout-new-branch")
        let outcome = EvaluationOutcome.safeOnly(safe)
        #expect(outcome.explainRuleID == nil)
        #expect(outcome.explainPackID == safe.packID)
    }

    @Test func denyWithoutMatchUsesDenyRuleID() {
        let leftover = HostNativeAsk.leftoverAskDeny
        let outcome = EvaluationOutcome.deny(leftover, matched: nil)
        #expect(outcome.explainRuleID == leftover.ruleID)
        #expect(outcome.explainPackID == leftover.ruleID.pack)
    }

    @Test func denyIgnoresMatchedRuleID() {
        let leftover = HostNativeAsk.leftoverAskDeny
        let outcome = EvaluationOutcome.deny(leftover, matched: gitMatch)
        #expect(outcome.explainRuleID == leftover.ruleID)
        #expect(outcome.explainRuleID != gitMatch.ruleID)
        #expect(outcome.explainPackID == leftover.ruleID.pack)
    }

    @Test(arguments: [
        EvaluationOutcome.quickRejected,
        .plain,
        .indeterminate(.commandTooLarge),
        .indeterminate(.budgetExhausted),
        .indeterminate(.corePacksUnavailable),
    ])
    func emptyIdentityOutcomes(_ outcome: EvaluationOutcome) {
        #expect(outcome.explainRuleID == nil)
        #expect(outcome.explainPackID == nil)
    }
}
