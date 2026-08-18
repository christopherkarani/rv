import Testing
import RVDomain
@testable import RVPresentation

private let resetHard = ShellCommand(rawValue: "git reset --hard")

@Test func hostDenyText_nilOnAllowIncludingMedium() {
    let allow = EvaluationResult(decision: .allow)
    #expect(hostDenyText(from: allow, command: ShellCommand(rawValue: "git status")) == nil)

    let rule = RuleID(pack: .coreGit, pattern: "stash-drop")
    let medium = EvaluationResult(
        decision: .allow,
        matched: RuleMatch(
            ruleID: rule,
            packID: .coreGit,
            patternName: "stash-drop",
            severity: .medium,
            reason: "git stash drop deletes a single stash"
        )
    )
    #expect(hostDenyText(from: medium, command: ShellCommand(rawValue: "git stash drop")) == nil)
}

@Test func hostDenyText_indeterminateIsPlanSentence() {
    let reasons: [IndeterminateReason] = [
        .budgetExhausted,
        .commandTooLarge,
        .corePacksUnavailable,
    ]
    for reason in reasons {
        let text = hostDenyText(
            from: EvaluationResult(decision: .indeterminate(reason)),
            command: resetHard
        )
        #expect(text == "rv could not finish evaluating this command. Run it in Terminal.")
        #expect(text?.contains("core.git") == false)
        #expect(text?.contains("reset-hard") == false)
        #expect(text?.contains(":") == false)
        #expect(text?.contains("\n") == false)
    }
}

@Test func hostDenyText_denyIsOneLineNoPanelNoCode() {
    let rule = RuleID(pack: .coreGit, pattern: "reset-hard")
    let result = EvaluationResult(
        decision: .deny(
            Deny(
                ruleID: rule,
                reason: "git reset --hard destroys uncommitted changes. Use 'git stash' first."
            )
        )
    )
    let text = hostDenyText(from: result, command: resetHard)
    #expect(
        text
            == "Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once."
    )
    #expect(text?.contains("\n") == false)
    #expect(text?.contains("═") == false)
    #expect(text?.contains("┌") == false)
    #expect(text?.contains("\u{001B}") == false)
    #expect(text?.contains("ALLOW-") == false)
    #expect(text?.contains("redeem") == false)
}

@Test func hostDenyText_switchesOnDecisionNotNilHeuristic() {
    let deny = EvaluationResult(
        decision: .deny(Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "x"))
    )
    let allow = EvaluationResult(decision: .allow)
    #expect(hostDenyText(from: deny, command: resetHard) != nil)
    #expect(hostDenyText(from: allow, command: resetHard) == nil)
    #expect(deny.decision != allow.decision)
}
