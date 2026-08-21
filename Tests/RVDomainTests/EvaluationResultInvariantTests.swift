import Foundation
import Testing
@testable import RVDomain

struct EvaluationResultInvariantTests {
    @Test func missingPolicyOverrideDecodesAsNone() throws {
        let encoded = try JSONEncoder().encode(EvaluationResult(decision: .allow))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "policyOverride")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(EvaluationResult.self, from: stripped)
        #expect(decoded.policyOverride == .none)
    }

    @Test func policyOverrideRoundTrips() throws {
        let result = EvaluationResult(
            decision: .allow,
            matchingView: "git reset --hard",
            policyOverride: .allowOnce
        )
        let encoded = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(EvaluationResult.self, from: encoded)
        #expect(decoded.policyOverride == .allowOnce)
    }

    @Test func stashDropShapedAllowKeepsAdvisoryMatchAndNilBlockingMatch() {
        let rule = RuleID(pack: .coreGit, pattern: "stash-drop")
        let result = EvaluationResult(
            decision: .allow,
            matched: RuleMatch(
                ruleID: rule,
                packID: .coreGit,
                patternName: "stash-drop",
                severity: .medium,
                reason: "git stash drop deletes a single stash"
            ),
            matchingView: "git stash drop"
        )
        #expect(result.decision == .allow)
        #expect(result.matched?.ruleID == rule)
        #expect(result.policyOverride == .none)
        #expect(result.blockingMatch == nil)
    }

    @Test func honoredAllowWithLeftoverBlockingMatchHasNilBlockingMatch() {
        let match = resetHardMatch()
        let result = EvaluationResult(
            decision: .allow,
            matched: match,
            matchingView: "git reset --hard",
            policyOverride: .allowOnce
        )
        #expect(result.decision == .allow)
        #expect(result.policyOverride != .none)
        #expect(result.matched == match)
        #expect(result.blockingMatch == nil)
    }

    @Test func denyExposesMatchedAsBlockingMatch() {
        let match = resetHardMatch()
        let result = EvaluationResult(
            decision: .deny(Deny(ruleID: match.ruleID, reason: match.reason)),
            matched: match,
            matchingView: "git reset --hard"
        )
        #expect(result.blockingMatch == match)
        #expect(result.policyOverride == .none)
    }

    @Test func indeterminateHasNilBlockingMatch() {
        let result = EvaluationResult(decision: .indeterminate(.commandTooLarge))
        #expect(result.blockingMatch == nil)
        #expect(result.policyOverride == .none)
    }
}

private func resetHardMatch() -> RuleMatch {
    RuleMatch(
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
        packID: .coreGit,
        patternName: "reset-hard",
        severity: .critical,
        reason: "git reset --hard destroys uncommitted changes"
    )
}
