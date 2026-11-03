import Testing
import RVDomain
@testable import RVEngine

private func mapping(_ pairs: [String: String]) -> SecretPathResolution {
    SecretPathResolution { candidate in pairs[candidate] }
}

struct SecretPathDeciderTests {
    @Test func decider_firstHit_typedSecretDenies() {
        let decider = SecretPathDecider()
        let hit = decider.firstHit(in: MatchingView("cat ~/.ssh/id_rsa"))
        #expect(hit?.ruleID.rawValue == "core.secrets:id-rsa")
        #expect(hit?.matchedText == "~/.ssh/id_rsa")
    }

    @Test func decider_firstHit_resolvedSpellingIsAuthoritative() {
        let decider = SecretPathDecider(
            resolution: mapping([".env": "/tmp/ok.txt"])
        )
        #expect(decider.firstHit(in: MatchingView("cat .env")) == nil)
    }

    @Test func decider_firstHit_exemptionSuppressesNonHostHit() {
        let decider = SecretPathDecider(
            allowPaths: SecretAllowPathSet(literals: ["~/.env"])
        )
        #expect(decider.firstHit(in: MatchingView("cat ~/.env")) == nil)
    }

    @Test func decider_fold_turnsAllowIntoSecretDeny() {
        let decider = SecretPathDecider()
        let allowed = EvaluationResult(outcome: .plain, matchingView: MatchingView("cat .env"))
        let folded = decider.fold(allowed)
        guard case .deny(let deny, _) = folded.outcome else {
            Issue.record("expected fold to deny")
            return
        }
        #expect(deny.ruleID.rawValue == "core.secrets:env")
    }

    @Test func decider_fold_keepsExistingDeny() {
        let decider = SecretPathDecider()
        let denied = EvaluationResult(
            outcome: .deny(
                Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "pack"),
                matched: nil
            ),
            matchingView: MatchingView("cat .env")
        )
        #expect(decider.fold(denied).outcome == denied.outcome)
    }

    @Test func decider_filePathHit_reportsResolvedRuleAndSpelling() {
        let decider = SecretPathDecider(
            resolution: mapping(["~/ss/k": "~/.ssh/id_rsa"])
        )
        let hit = decider.filePathHit("~/ss/k")
        #expect(hit?.rule.pattern == "id-rsa")
        #expect(hit?.spelling == "~/.ssh/id_rsa")
    }

    @Test func decider_filePathHit_typedExemptionDoesNotVouchForResolved() {
        let decider = SecretPathDecider(
            allowPaths: SecretAllowPathSet(literals: ["~/b/.env"]),
            resolution: mapping(["~/b/.env": "~/.aws/config"])
        )
        #expect(decider.filePathHit("~/b/.env")?.rule.pattern == "home-aws")
    }

    @Test func decider_aliasEscalation_onlyForAllowOutcomes() {
        let decider = SecretPathDecider()
        let view = MatchingView("cat x")
        #expect(decider.escalatesToAliasPass(EvaluationResult(outcome: .plain, matchingView: view)))
        #expect(decider.escalatesToAliasPass(EvaluationResult(outcome: .quickRejected, matchingView: view)))
        let denied = EvaluationResult(
            outcome: .deny(
                Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "pack"),
                matched: nil
            ),
            matchingView: view
        )
        #expect(decider.escalatesToAliasPass(denied) == false)
        let unknown = EvaluationResult(outcome: .indeterminate(.commandTooLarge), matchingView: view)
        #expect(decider.escalatesToAliasPass(unknown) == false)
    }

    @Test func decider_withResolution_keepsContextReplacesAdapter() {
        let decider = SecretPathDecider(
            allowPaths: SecretAllowPathSet(literals: ["~/.env"])
        ).withResolution(mapping(["~/ss/k": "~/.ssh/id_rsa"]))
        #expect(decider.firstHit(in: MatchingView("cat ~/ss/k"))?.ruleID.rawValue == "core.secrets:id-rsa")
        #expect(decider.firstHit(in: MatchingView("cat ~/.env")) == nil)
    }
}
