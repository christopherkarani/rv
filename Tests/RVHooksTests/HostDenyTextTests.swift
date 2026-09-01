import Testing
import RVDomain
@testable import RVHooks

private let resetHard = ShellCommand(rawValue: "git reset --hard")
let resetHardHostDeny = "RV · Blocked. Destroys uncommitted changes. Use 'git stash' first."

func assertHookDenyHasNoBypassOrEssay(_ text: String?) {
    let payload = text ?? ""
    #expect(payload.contains("RV · Blocked"))
    #expect(payload.contains("RV · Blocked\n") == false)
    #expect(payload.contains("git reset --hard") == false)
    #expect(payload.contains("Terminal") == false)
    #expect(payload.contains("allow-once") == false)
    #expect(payload.contains("reset --soft") == false)
}

func assertMintedHookUnlock(_ text: String, why: String = resetHardHostDeny) throws -> String {
    let minted = try #require(allowOnceUnlockCode(in: text))
    #expect(text.contains("\(why) Run it in Terminal, or rv allow-once \(minted)."))
    #expect(text.contains("git reset --hard") == false)
    #expect(text.contains("RV_" + "BYPASS") == false)
    #expect(text.contains("\u{001B}") == false)
    #expect(text.contains("═") == false)
    #expect(text.contains("┌") == false)
    return minted
}

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
    #expect(text == resetHardHostDeny)
    #expect(text?.contains("\n") == false)
    #expect(text?.contains("═") == false)
    #expect(text?.contains("┌") == false)
    #expect(text?.contains("\u{001B}") == false)
    #expect(text?.contains("ALLOW-") == false)
    #expect(text?.contains("redeem") == false)
    assertHookDenyHasNoBypassOrEssay(text)
}

@Test func hostDenyText_resetHardIsWhatAndWhy() {
    let result = EvaluationResult(
        outcome: .deny(
            Deny(
                ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                reason: "git reset --hard destroys uncommitted changes. Use 'git stash' first."
            ),
            matched: nil
        )
    )
    let text = hostDenyText(from: result, command: resetHard)
    #expect(text == resetHardHostDeny)
    #expect(text?.contains("\n") == false)
    #expect(text?.contains("git reset --hard") == false)
    #expect(text?.contains("git stash") == true)
    #expect(text?.components(separatedBy: "RV · Blocked").count == 2)
    #expect(text?.hasPrefix("Error:") == false)
    assertHookDenyHasNoBypassOrEssay(text)
}

@Test func hostDenyText_dropsThirdSentence() {
    let text = hostDenyLine(command: ShellCommand(rawValue: "echo"), reason: "A. B. C. D.")
    #expect(text == "RV · Blocked. A. B.")
}

@Test func hostDenyText_omitsSentence2WhenBypassish() {
    let command = ShellCommand(rawValue: "echo")
    #expect(
        hostDenyLine(command: command, reason: "Nope. Run rv allow-once next.")
            == "RV · Blocked. Nope."
    )
    #expect(
        hostDenyLine(command: command, reason: "Nope. Code ALLOW-123456.")
            == "RV · Blocked. Nope."
    )
    #expect(
        hostDenyLine(command: command, reason: "Nope. Then redeem it.")
            == "RV · Blocked. Nope."
    )
    #expect(
        hostDenyLine(command: command, reason: "Nope. Env RV_BYPASS is not a skip.")
            == "RV · Blocked. Nope."
    )
    #expect(
        hostDenyLine(command: command, reason: "Nope. Run it in Terminal.")
            == "RV · Blocked. Nope."
    )
}

@Test func hostDenyText_omitsSentence2WhenWhyExceeds180Scalars() {
    let second = String(repeating: "a", count: 180)
    let text = hostDenyLine(
        command: ShellCommand(rawValue: "echo"),
        reason: "Short. \(second)."
    )
    #expect(text == "RV · Blocked. Short.")
}

@Test func hostDenyText_oneSentenceBuiltinStaysOneClause() {
    let text = hostDenyLine(
        command: ShellCommand(rawValue: "git checkout -- file"),
        reason: "Discarding working-tree files is a built-in hard deny."
    )
    #expect(text == "RV · Blocked. Discarding working-tree files is a built-in hard deny.")
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
    #expect(text == hostDenyLine(command: command, reason: "dynamic"))
    #expect(text == "RV · Blocked. Dynamic.")
    #expect(preview.hasSuffix("…"))
    #expect(preview.contains("cat >>"))
    #expect(preview.contains("Observation 760") == false)
    #expect(text?.contains(preview) == false)
    #expect(text?.contains("Observation 760") == false)
    #expect(text?.contains("<base>") == false)
    #expect(text?.contains("\n") == false)
    #expect((text?.count ?? 0) < 240)
}

@Test func hookDenyCommandPreview_shortCommandUnchanged() {
    #expect(hookDenyCommandPreview(resetHard) == "git reset --hard")
    #expect(hookDenyCommandPreview(ShellCommand(rawValue: "git reset --hard\n")) == "git reset --hard")
}

@Test func hookUnlockNext_codeAppendsSixHex() {
    #expect(hookUnlockNext(code: nil) == hookUnlockNext)
    #expect(hookUnlockNext(code: "abc") == hookUnlockNext)
    #expect(hookUnlockNext(code: "ABCDEF") == hookUnlockNext)
    #expect(hookUnlockNext(code: "a1b2c3") == "Run it in Terminal, or rv allow-once a1b2c3.")
    #expect(allowOnceUnlockCode(in: hookUnlockNext) == nil)
    #expect(allowOnceUnlockCode(in: hookUnlockNext(code: "a1b2c3")) == "a1b2c3")
}

@Test func hostDenyLine_appendsUnlockWhenCodeIsMinted() throws {
    let command = resetHard
    let reason = "git reset --hard destroys uncommitted changes. Use 'git stash' first."
    #expect(hostDenyLine(command: command, reason: reason) == resetHardHostDeny)
    let minted = hostDenyLine(command: command, reason: reason, unlockCode: "a1b2c3")
    #expect(minted == "\(resetHardHostDeny) Run it in Terminal, or rv allow-once a1b2c3.")
    #expect(minted.contains("\n") == false)
    _ = try assertMintedHookUnlock(minted)
}

@Test func hookDenyCommandPreview_clipsOverlongFirstLine() {
    let exact = String(repeating: "a", count: hookDenyCommandPreviewLimit)
    #expect(hookDenyCommandPreview(ShellCommand(rawValue: exact)) == exact)
    let raw = String(repeating: "a", count: hookDenyCommandPreviewLimit + 8)
    let preview = hookDenyCommandPreview(ShellCommand(rawValue: raw))
    #expect(preview == exact + "…")
    #expect(preview.contains("\n") == false)
}
