import Testing
import RVDomain

@Suite("Display")
struct DisplayTests {
    @Test func incompleteEvalSentence_isSharedHookAndTTYCopy() {
        #expect(incompleteEvalSentence == "rv could not finish evaluating this command. Run it in Terminal.")
    }

    @Test func displayRuleID_usesSlashNotColon() throws {
        let rule = try #require(RuleID(rawValue: "core.git:reset-hard"))
        #expect(displayRuleID(rule) == "core.git/reset-hard")
        #expect(displayRuleID(rule) == rule.slashDisplay)
        #expect(displayRuleID(rule) != rule.rawValue)
    }
}
