import Testing
import RVDomain
@testable import RVHooks

private let resetHard = ShellCommand(rawValue: "git reset --hard")

@Test func hostDenyText_nilOnAllowIncludingMedium() {
    let allow = EvaluationResult(outcome: .plain)
    #expect(hostDenyText(from: allow, command: ShellCommand(rawValue: "git status")) == nil)

    let rule = RuleID(pack: .coreGit, pattern: "stash-drop")
    let medium = EvaluationResult(
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
            from: EvaluationResult(outcome: .indeterminate(reason)),
            command: resetHard
        )
        #expect(text == incompleteEvalSentence)
        #expect(text?.contains("core.git") == false)
        #expect(text?.contains("reset-hard") == false)
        #expect(text?.contains(":") == false)
        #expect(text?.contains("\n") == false)
    }
}

@Test func hostDenyText_denyIsOneLineNoPanelNoCode() {
    let rule = RuleID(pack: .coreGit, pattern: "reset-hard")
    let result = EvaluationResult(
        outcome: .deny(
            Deny(
                ruleID: rule,
                reason: "git reset --hard destroys uncommitted changes. Use 'git stash' first."
            ),
            matched: nil
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
        outcome: .deny(
            Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "x"),
            matched: nil
        )
    )
    let allow = EvaluationResult(outcome: .plain)
    #expect(hostDenyText(from: deny, command: resetHard) != nil)
    #expect(hostDenyText(from: allow, command: resetHard) == nil)
    #expect(deny.decision != allow.decision)
}

@Test func hostDenyText_multilineCommand_previewsFirstLine() {
    let command = ShellCommand(
        rawValue: """
        cat >> /Users/chriskarani/.grok/skill-observations/log.md << 'EOF'
        ### Observation 760: placeholder
        See `origin/<base>...HEAD`
        EOF
        """
    )
    let rule = RuleID(pack: .coreFilesystem, pattern: "redirect-truncate-dynamic-path")
    let result = EvaluationResult(
        outcome: .deny(
            Deny(ruleID: rule, reason: "dynamic"),
            matched: nil
        )
    )
    let text = hostDenyText(from: result, command: command)
    let preview = hookDenyCommandPreview(command)
    #expect(
        text
            == "Blocked \(preview) (core.filesystem/redirect-truncate-dynamic-path). \(hookUnlockNext)"
    )
    #expect(preview.hasSuffix("…"))
    #expect(preview.contains("cat >>"))
    #expect(preview.contains("Observation 760") == false)
    #expect(text?.contains("Observation 760") == false)
    #expect(text?.contains("<base>") == false)
    #expect(text?.contains("\n") == false)
    #expect((text?.count ?? 0) < 240)
}

@Test func hookDenyCommandPreview_shortCommandUnchanged() {
    #expect(hookDenyCommandPreview(resetHard) == "git reset --hard")
}

@Test func hookDenyCommandPreview_clipsOverlongFirstLine() {
    let raw = String(repeating: "a", count: hookDenyCommandPreviewLimit + 8)
    let preview = hookDenyCommandPreview(ShellCommand(rawValue: raw))
    #expect(preview == String(repeating: "a", count: hookDenyCommandPreviewLimit) + "…")
    #expect(preview.contains("\n") == false)
}
