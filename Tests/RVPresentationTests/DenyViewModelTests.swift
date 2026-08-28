import Testing
import RVDomain
@testable import RVPresentation

private let resetHard = ShellCommand(rawValue: "git reset --hard")
private let stashDrop = ShellCommand(rawValue: "git stash drop")
private let status = ShellCommand(rawValue: "git status")

let resetHardExplanation = """
git reset --hard discards ALL uncommitted changes in your working directory \\ AND staging area. This is one of the most dangerous git commands because \\ changes that were never committed cannot be recovered by any means.

\\ What gets destroyed: \\ - All modified files revert to the target commit \\ - All staged changes are lost \\ - Untracked files remain (use git clean to remove those)

\\ Safer alternatives: \\ - git reset --soft <ref>: Move HEAD but keep all changes staged \\ - git reset --mixed <ref>: Move HEAD, unstage changes, keep working dir (default) \\ - git stash: Save changes before resetting

\\ Preview what would be lost: git status && git diff
"""

private func denyResult(
    pack: String = "core.git",
    pattern: String = "reset-hard",
    reason: String = "git reset --hard destroys uncommitted changes. Use 'git stash' first."
) -> EvaluationResult {
    let rule = RuleID(pack: PackID(rawValue: pack), pattern: pattern)
    return EvaluationResult(
        outcome: .deny(
            Deny(ruleID: rule, reason: reason),
            matched: RuleMatch(
                ruleID: rule,
                packID: rule.pack,
                patternName: pattern,
                severity: .critical,
                reason: reason
            )
        )
    )
}

private func mediumAllow() -> EvaluationResult {
    let rule = RuleID(pack: .coreGit, pattern: "stash-drop")
    return EvaluationResult(
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
}

@Test func denyViewModel_nilOnAllowIncludingMedium() {
    let allow = EvaluationResult(outcome: .plain)
    #expect(denyViewModel(from: allow, command: status) == nil)
    #expect(denyViewModel(from: mediumAllow(), command: stashDrop) == nil)
}

@Test func denyViewModel_nilOnIndeterminate() {
    let result = EvaluationResult(outcome: .indeterminate(.commandTooLarge))
    #expect(denyViewModel(from: result, command: resetHard) == nil)
}

@Test func denyViewModel_factAndNextAction() throws {
    let reason = "git reset --hard destroys uncommitted changes. Use 'git stash' first."
    let vm = try #require(denyViewModel(from: denyResult(reason: reason), command: resetHard))
    #expect(vm.fact == "git reset --hard destroys uncommitted changes")
    #expect(vm.packReason == reason)
    #expect(vm.nextAction == "run it in Terminal, or rv allow-once")
    #expect(vm.ruleID.rawValue == "core.git:reset-hard")
    #expect(displayRuleID(vm.ruleID) == "core.git/reset-hard")
    #expect(vm.ruleDisplay == "core.git/reset-hard")
}

@Test func explainViewModel_allowHasNoNextAction() {
    let vm = explainViewModel(from: EvaluationResult(outcome: .plain), command: status)
    #expect(vm.fact == "allow")
    #expect(vm.nextAction == nil)
}

@Test func explainViewModel_denyHasFactNext() {
    let vm = explainViewModel(from: denyResult(), command: resetHard)
    #expect(vm.fact == "git reset --hard destroys uncommitted changes")
    #expect(vm.nextAction == "run it in Terminal, or rv allow-once")
    #expect(vm.patternName == "reset-hard")
    #expect(vm.severity == .critical)
    #expect(vm.explanation == nil)
    #expect(vm.heading == "RV EXPLAIN")
    #expect(vm.explainDecisionWord == "DENY")
    #expect(vm.suggestions.contains { $0.kind == .previewFirst })
    #expect(vm.suggestions.contains { $0.command == "git reset --soft" })
    #expect(!vm.suggestions.contains { $0.command?.contains("HEAD~1") == true })
    #expect(
        !suggestions(for: RuleID(pack: .coreFilesystem, pattern: "dd-overwrite-general"))
            .contains { $0.command?.contains("rm -ri") == true }
    )
}

@Test func testViewModel_denyShowsPackReasonAndColonMatch() throws {
    let reason = "git reset --hard destroys uncommitted changes. Use 'git stash' first."
    let result = EvaluationResult(
        outcome: .deny(
            Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: reason),
            matched: RuleMatch(
                ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                packID: .coreGit,
                patternName: "reset-hard",
                severity: .critical,
                reason: reason,
                explanation: resetHardExplanation,
                span: MatchSpan(start: 0, end: 16),
                matchedText: "git reset --hard"
            )
        )
    )
    let deny = try #require(denyViewModel(from: result, command: resetHard))
    let vm = testViewModel(from: result, command: resetHard)
    #expect(vm.deny == deny)
    #expect(vm.resultWord == "BLOCKED")
    #expect(vm.resultTone == .deny)
    #expect(vm.packDisplay == deny.packID.rawValue)
    #expect(vm.patternName == deny.ruleID.pattern)
    #expect(vm.matchedLabel == "core.git:reset-hard")
    #expect(vm.reason == deny.packReason)
    #expect(vm.reason == reason)
    #expect(vm.explanation == resetHardExplanation)
    #expect(vm.source == "pack")
    #expect(vm.span == MatchSpan(start: 0, end: 16))
}

@Test func testViewModel_allowIsCommandAndAllowed() {
    let vm = testViewModel(from: EvaluationResult(outcome: .plain), command: status)
    #expect(vm.deny == nil)
    #expect(vm.resultWord == "ALLOWED")
    #expect(vm.packDisplay == nil)
    #expect(vm.reason == nil)
    #expect(vm.explanation == nil)
    #expect(vm.source == nil)
}

@Test func testViewModel_mediumAllowKeepsCaretOmitsPackEssay() {
    let result = mediumAllow()
    let vm = testViewModel(from: result, command: stashDrop)
    #expect(vm.deny == nil)
    #expect(vm.resultWord == "ALLOWED")
    #expect(vm.matchedLabel == "core.git:stash-drop")
    #expect(vm.packDisplay == nil)
    #expect(vm.explanation == nil)
    #expect(vm.source == nil)
}

@Test func testViewModel_indeterminateUsesPlanSentence() {
    let vm = testViewModel(
        from: EvaluationResult(outcome: .indeterminate(.commandTooLarge)),
        command: resetHard
    )
    #expect(vm.deny == nil)
    #expect(vm.resultWord == "INCOMPLETE")
    #expect(vm.reason == incompleteEvalSentence)
    #expect(vm.source == nil)
}

@Test func remapMatchSpan_prefersMatchedTextInDisplayCommand() {
    let remapped = remapMatchSpan(
        span: MatchSpan(start: 0, end: 6),
        matchedText: "rm -rf",
        onto: "echo hi && rm -rf ./src"
    )
    #expect(remapped == MatchSpan(start: 11, end: 17))
}

@Test func remapMatchSpan_usesSearchTextNotFirstSnippet() {
    let remapped = remapMatchSpan(
        span: MatchSpan(start: 0, end: 6),
        matchedText: "rm -rf",
        searchText: "rm -rf ./src",
        onto: "rm -rf /tmp/foo && rm -rf ./src"
    )
    #expect(remapped == MatchSpan(start: 19, end: 25))
}

@Test func remapMatchSpan_omitsCaretsWhenViewDoesNotAppear() {
    let remapped = remapMatchSpan(
        span: MatchSpan(start: 0, end: 16),
        matchedText: "git reset --hard",
        searchText: "git reset --hard",
        onto: "'git' reset --hard"
    )
    #expect(remapped == nil)
}

@Test func decisionTone_mapsClosedDecision() {
    #expect(decisionTone(.allow) == .allow)
    #expect(
        decisionTone(
            .deny(
                Deny(
                    ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                    reason: "git reset --hard destroys uncommitted changes"
                )
            )
        ) == .deny
    )
    #expect(decisionTone(.indeterminate(.commandTooLarge)) == .incomplete)
}

@Test func explainViewModel_copiesPackExplanation() {
    let reason = "git reset --hard destroys uncommitted changes. Use 'git stash' first."
    let rule = RuleID(pack: .coreGit, pattern: "reset-hard")
    let essay = resetHardExplanation
    let regex = #"(?:^|[^[:alnum:]_-])git\s+(?:\S+\s+)*reset\s+--hard"#
    let vm = explainViewModel(
        from: EvaluationResult(
            outcome: .deny(
                Deny(ruleID: rule, reason: reason),
                matched: RuleMatch(
                    ruleID: rule,
                    packID: .coreGit,
                    patternName: "reset-hard",
                    severity: .critical,
                    reason: reason,
                    explanation: essay,
                    regex: regex
                )
            )
        ),
        command: resetHard
    )
    #expect(vm.explanation == essay)
    #expect(vm.severity == .critical)
    #expect(vm.patternName == "reset-hard")
    #expect(vm.regex == regex)
}

@Test func explainViewModel_exposesDisplayFieldsWithoutNextOnAllow() {
    let vm = explainViewModel(from: mediumAllow(), command: stashDrop)
    #expect(vm.decisionWord == "allow")
    #expect(vm.decisionTone == .allow)
    #expect(vm.ruleDisplay == "core.git/stash-drop")
    #expect(vm.packDisplay == "core.git")
    #expect(vm.severityDisplay == "medium")
    #expect(vm.nextAction == nil)
}

@Test func explanationLines_stripsInlineMarkdownKeepsHomeTilde() {
    let raw = "Use `rm -ri` on ~/Downloads, not **force**. See [docs](https://example.com)."
    #expect(
        explanationLines(from: raw) == [
            "Use rm -ri on ~/Downloads, not force. See docs (https://example.com).",
        ]
    )
}

@Test func explanationLines_keepsUnderscoresInIdentifiers() {
    let raw = "`unlink` ~/.ssh/id_ed25519 or O_WRONLY|O_CREAT|O_TRUNC, not **force**."
    #expect(
        explanationLines(from: raw) == [
            "unlink ~/.ssh/id_ed25519 or O_WRONLY|O_CREAT|O_TRUNC, not force.",
        ]
    )
}

@Test func explanationLines_keepsImageAltText() {
    #expect(explanationLines(from: "Review ![diagram](file://secret).") == ["Review diagram."])
}

@Test func explanationLines_keepsInternalDashesInABullet() {
    let raw = "\\ Why this is dangerous: \\ - Deleted files bypass the trash - they're gone immediately \\ - Typos in paths can delete unintended directories"
    #expect(
        explanationLines(from: raw) == [
            "Why this is dangerous:",
            "• Deleted files bypass the trash - they're gone immediately",
            "• Typos in paths can delete unintended directories",
        ]
    )
}

@Test func explanationLines_splitsWrapMarkersAndBullets() {
    #expect(
        explanationLines(from: resetHardExplanation) == [
            "git reset --hard discards ALL uncommitted changes in your working directory AND staging area. This is one of the most dangerous git commands because changes that were never committed cannot be recovered by any means.",
            "",
            "What gets destroyed:",
            "• All modified files revert to the target commit",
            "• All staged changes are lost",
            "• Untracked files remain (use git clean to remove those)",
            "",
            "Safer alternatives:",
            "• git reset --soft <ref>: Move HEAD but keep all changes staged",
            "• git reset --mixed <ref>: Move HEAD, unstage changes, keep working dir (default)",
            "• git stash: Save changes before resetting",
            "",
            "Preview what would be lost: git status && git diff",
        ]
    )
}

@Test func explainViewModel_indeterminateHasIncompleteFact() {
    let vm = explainViewModel(
        from: EvaluationResult(outcome: .indeterminate(.commandTooLarge)),
        command: resetHard
    )
    #expect(vm.fact == incompleteEvalSentence)
}

@Test func explainStep_displayWordsAreTTYVoice() {
    let rule = RuleID(pack: .coreGit, pattern: "checkout-new-branch")
    #expect(ExplainStep.normalize.label == "normalize")
    #expect(ExplainStep.normalize.displayOutcome == "prepared")
    #expect(ExplainStep.quickReject(.skipped).displayOutcome == "skipped")
    #expect(ExplainStep.quickReject(.scanned).displayOutcome == "scanned")
    #expect(ExplainStep.safe(.none).displayOutcome == "none")
    #expect(ExplainStep.safe(.rule(rule)).displayOutcome == "core.git/checkout-new-branch")
    #expect(ExplainStep.default(.allow).displayOutcome == "allow")
    #expect(ExplainStep.default(.incomplete).displayOutcome == "incomplete")
}

@Test func explainViewModel_mediumAllowKeepsMatchAndNoNext() {
    let vm = explainViewModel(from: mediumAllow(), command: stashDrop)
    #expect(vm.fact == "allow")
    #expect(vm.nextAction == nil)
    #expect(vm.ruleID?.rawValue == "core.git:stash-drop")
}

@Test func explainViewModel_attachesGitSemanticWhenPresent() {
    let create = explainViewModel(
        from: EvaluationResult(
            outcome: .plain,
            analysis: .git(.createBranch(name: "feature", startPoint: nil, force: false))
        ),
        command: ShellCommand(rawValue: "git checkout -b feature")
    )
    #expect(create.semantic?.action == "branch creation")
    #expect(create.semantic?.effect == "local branch create")
    #expect(create.semantic?.ref == "feature")

    let discard = explainViewModel(
        from: EvaluationResult(
            outcome: .plain,
            analysis: .git(.discardWorktree(pathspecs: ["file.swift"], source: nil))
        ),
        command: ShellCommand(rawValue: "git checkout -- file.swift")
    )
    #expect(discard.semantic?.action == "working-tree overwrite/discard")
    #expect(discard.semantic?.pathspec == "file.swift")

    #expect(explainViewModel(from: EvaluationResult(outcome: .plain), command: status).semantic == nil)
}

@Test func packsViewModel_dayOneEnabled() {
    let vm = packsViewModel(
        enabled: dayOnePackIDs,
        catalog: [
            (.coreFilesystem, "filesystem"),
            (.coreGit, "git"),
        ]
    )
    #expect(vm.rows.count == 2)
    #expect(vm.rows.allSatisfy { $0.enabled })
    #expect(vm.rows.map(\.id.rawValue) == ["core.filesystem", "core.git"])
}
