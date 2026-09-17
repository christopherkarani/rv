import Testing
import RVDomain
import RVPresentation
import RVTheme
@testable import RVTUI

@Test func testRenderer_colorOff_hasNoEscape() {
    let vm = testViewModel(
        from: EvaluationResult(
            outcome: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                    reason: "git reset --hard destroys uncommitted changes. Use 'git stash' first."
                ),
                matched: nil
            )
        ),
        command: ShellCommand(rawValue: "git reset --hard")
    )
    let lines = TestRenderer().render(vm, palette: colorOffPalette)
    #expect(lines.allSatisfy { !$0.contains("\u{001B}") })
    #expect(lines.contains { $0 == "Result: BLOCKED" })
}

private func stripCSI(_ text: String) -> String {
    var out = ""
    var index = text.startIndex
    while index < text.endIndex {
        if text[index] == "\u{001B}" {
            index = text.index(after: index)
            if index < text.endIndex, text[index] == "[" {
                index = text.index(after: index)
                while index < text.endIndex, !text[index].isLetter {
                    index = text.index(after: index)
                }
                if index < text.endIndex {
                    index = text.index(after: index)
                }
            }
            continue
        }
        out.append(text[index])
        index = text.index(after: index)
    }
    return out
}

@Test func testRenderer_colorOn_wrapsVisibleWidthAndPaintsCarets() {
    let command = "git reset --hard " + String(repeating: "x", count: 90)
    let rule = RuleID(pack: .coreGit, pattern: "reset-hard")
    let vm = testViewModel(
        from: EvaluationResult(
            outcome: .deny(
                Deny(ruleID: rule, reason: "git reset --hard destroys uncommitted changes"),
                matched: RuleMatch(
                    ruleID: rule,
                    packID: .coreGit,
                    patternName: "reset-hard",
                    severity: .critical,
                    reason: "git reset --hard destroys uncommitted changes",
                    span: MatchSpan(start: 0, end: 16),
                    matchedText: "git reset --hard"
                )
            )
        ),
        command: ShellCommand(rawValue: command)
    )
    let on = Palette(for: ColorCapability(colorsEnabled: true))
    let lines = TestRenderer().render(vm, palette: on)
    #expect(lines[0].contains("\u{001B}"))
    #expect(stripCSI(lines[0]).hasPrefix("Command: git reset --hard"))
    #expect(lines.contains { $0.contains(on.deny) && stripCSI($0).contains("^") })
    #expect(lines.contains { $0.contains(on.mark) && stripCSI($0).contains("Matched: core.git:reset-hard") })
    #expect(lines.allSatisfy { stripCSI($0).count <= 80 })
}

private let resetHardExplanation = """
git reset --hard discards ALL uncommitted changes in your working directory \\ AND staging area. This is one of the most dangerous git commands because \\ changes that were never committed cannot be recovered by any means.

\\ What gets destroyed: \\ - All modified files revert to the target commit \\ - All staged changes are lost \\ - Untracked files remain (use git clean to remove those)

\\ Safer alternatives: \\ - git reset --soft <ref>: Move HEAD but keep all changes staged \\ - git reset --mixed <ref>: Move HEAD, unstage changes, keep working dir (default) \\ - git stash: Save changes before resetting

\\ Preview what would be lost: git status && git diff
"""

@Test func explainRenderer_titlesDecisionShowsRegexAndSuggestions() {
    let rule = RuleID(pack: .coreGit, pattern: "reset-hard")
    let reason = "git reset --hard destroys uncommitted changes. Use 'git stash' first."
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
                    explanation: resetHardExplanation,
                    regex: regex
                )
            )
        ),
        command: ShellCommand(rawValue: "git reset --hard")
    )
    let lines = ExplainRenderer().render(vm, palette: colorOffPalette)
    let text = lines.joined(separator: "\n")
    #expect(lines.first == "RV EXPLAIN")
    #expect(lines.contains { $0.contains("Decision: DENY") })
    #expect(lines.contains { $0.hasPrefix("├── ") && $0.hasSuffix("Command") })
    #expect(lines.contains { $0.contains("│   ") && $0.contains("Input") && $0.contains("git reset --hard") })
    #expect(lines.contains { $0.hasPrefix("├── ") && $0.hasSuffix("Match") })
    #expect(lines.contains { $0.contains("Regex") && $0.contains("(?:") })
    #expect(lines.contains { $0.contains("Severity") && $0.contains("critical") })
    #expect(lines.contains { $0.hasPrefix("├── ") && $0.hasSuffix("Explanation") })
    #expect(lines.contains { $0.contains("What gets destroyed") })
    #expect(lines.contains { $0.contains("Safer alternatives") })
    #expect(lines.contains { isTreeSpacer($0) })
    #expect(lines.contains { $0.contains("Suggestions") })
    #expect(lines.contains { $0.contains("Preview first") })
    #expect(lines.contains { $0.contains("$ git diff && git status") })
    #expect(lines.contains { $0.contains("Next") && $0.contains("rv allow-once") })
    #expect(!text.contains("μs"))
    #expect(lines.allSatisfy { $0.count <= 80 })
}

private func isTreeSpacer(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return !trimmed.isEmpty
        && trimmed.contains("│")
        && trimmed.allSatisfy { $0 == "│" || $0.isWhitespace }
        && !line.contains("├")
        && !line.contains("└")
}

@Test func explainRenderer_indeterminateHasReasonWithoutMatch() {
    let vm = explainViewModel(
        from: EvaluationResult(outcome: .indeterminate(.commandTooLarge)),
        command: ShellCommand(rawValue: "git reset --hard")
    )
    let lines = ExplainRenderer().render(vm, palette: colorOffPalette)
    let text = lines.joined(separator: "\n")
    #expect(lines.first == "RV EXPLAIN")
    #expect(lines.contains { $0.contains("Decision: INCOMPLETE") })
    #expect(lines.contains { $0.contains("Reason") })
    #expect(text.contains("rv could not finish evaluating this command"))
    #expect(text.contains("Terminal."))
    #expect(!text.contains("Match"))
}

@Test func explainRenderer_colorOn_paintsDecisionAndHeadings() {
    let rule = RuleID(pack: .coreGit, pattern: "reset-hard")
    let vm = explainViewModel(
        from: EvaluationResult(
            outcome: .deny(
                Deny(ruleID: rule, reason: "git reset --hard destroys uncommitted changes"),
                matched: RuleMatch(
                    ruleID: rule,
                    packID: .coreGit,
                    patternName: "reset-hard",
                    severity: .critical,
                    reason: "git reset --hard destroys uncommitted changes",
                    explanation: resetHardExplanation
                )
            )
        ),
        command: ShellCommand(rawValue: "git reset --hard")
    )
    let on = Palette(for: ColorCapability(colorsEnabled: true))
    let lines = ExplainRenderer().render(vm, palette: on)
    #expect(lines.allSatisfy { stripCSI($0).count <= 80 })
    #expect(stripCSI(lines[0]) == "RV EXPLAIN")
    #expect(lines[0].contains(on.heading) == false)
    #expect(lines[0].contains(on.mark) == false)
    #expect(lines[0].contains(on.trace) == false)
    let decision = lines.first { stripCSI($0).contains("Decision: DENY") }
    #expect(decision?.contains(on.deny) == true)
    let command = lines.first { stripCSI($0).hasSuffix("Command") }
    #expect(command?.contains(on.heading) == true)
    let match = lines.first { stripCSI($0).hasSuffix("Match") }
    #expect(match?.contains(on.mark) == true)
    let explanation = lines.first { stripCSI($0).hasSuffix("Explanation") }
    #expect(explanation?.contains(on.heading) == false)
    #expect(explanation?.contains(on.mark) == false)
    let pipeline = lines.first { stripCSI($0).hasSuffix("Pipeline") }
    #expect(pipeline?.contains(on.trace) == true)
    let suggestions = lines.first { stripCSI($0).hasSuffix("Suggestions") }
    #expect(suggestions?.contains(on.mark) == true)
}

@Test func explainRenderer_colorOn_paintsRegexSyntax() throws {
    let rule = RuleID(pack: .coreGit, pattern: "reset-hard")
    let regex = #"(?:^|[^[:alnum:]_-])git\s+(?:\S+\s+)*reset\s+--hard"#
    let vm = explainViewModel(
        from: EvaluationResult(
            outcome: .deny(
                Deny(ruleID: rule, reason: "git reset --hard destroys uncommitted changes"),
                matched: RuleMatch(
                    ruleID: rule,
                    packID: .coreGit,
                    patternName: "reset-hard",
                    severity: .critical,
                    reason: "git reset --hard destroys uncommitted changes",
                    regex: regex
                )
            )
        ),
        command: ShellCommand(rawValue: "git reset --hard")
    )
    let off = ExplainRenderer().render(vm, palette: colorOffPalette)
    let regexOff = off.first { $0.contains("Regex") }
    #expect(regexOff?.contains(regex) == true)
    #expect(regexOff?.contains("\u{001B}") == false)

    let on = Palette(for: ColorCapability(colorsEnabled: true))
    let lines = ExplainRenderer().render(vm, palette: on)
    let regexOn = try #require(lines.first { stripCSI($0).contains("Regex") })
    #expect(stripCSI(regexOn).contains(regex))
    #expect(regexOn.contains(on.regex.meta))
    #expect(regexOn.contains(on.regex.escape))
    #expect(regexOn.contains(on.regex.name))
    #expect(regexOn.contains("alnum"))
    #expect(lines.allSatisfy { stripCSI($0).count <= 80 })
}

@Test func tokenizeRegex_splitsResetHard() {
    let pattern = #"(?:^|[^[:alnum:]_-])git\s+"#
    let kinds = tokenizeRegex(pattern).map(\.kind)
    #expect(kinds.contains(.meta))
    #expect(kinds.contains(.escape))
    #expect(kinds.contains(.posixName))
    #expect(tokenizeRegex(pattern).contains { $0.kind == .posixName && $0.text == "alnum" })
    #expect(tokenizeRegex(pattern).contains { $0.kind == .escape && $0.text == "\\s" })
    #expect(paintedRegex(pattern, palette: colorOffPalette) == pattern)
}

@Test func paintedRegexLines_keepsSpacesWhenWrapping() {
    let pattern = String(repeating: "a", count: 40) + "[ \\t]" + String(repeating: "b", count: 40)
    let off = paintedRegexLines(pattern, width: 24, palette: colorOffPalette)
    #expect(off.joined() == pattern)
    #expect(off.allSatisfy { !$0.contains("\u{001B}") })
    #expect(off.contains { $0.contains("[ \\t]") || $0.contains("\\t]") })

    let on = Palette(for: ColorCapability(colorsEnabled: true))
    let painted = paintedRegexLines(pattern, width: 24, palette: on)
    #expect(painted.map(stripCSI).joined() == pattern)
    #expect(painted.contains { $0.contains(on.regex.meta) })
    #expect(painted.contains { $0.contains(on.regex.escape) })
    #expect(painted.allSatisfy { stripCSI($0).count <= 24 })
}

@Test func testRenderer_windowsLateMatchAndStaysWithinWidth() {
    let prefix = String(repeating: "x", count: 90)
    let command = prefix + " && rm -rf ./src"
    let rule = RuleID(pack: .coreFilesystem, pattern: "rm-rf-general")
    let vm = testViewModel(
        from: EvaluationResult(
            outcome: .deny(
                Deny(ruleID: rule, reason: "rm -rf is destructive and requires human approval."),
                matched: RuleMatch(
                    ruleID: rule,
                    packID: .coreFilesystem,
                    patternName: "rm-rf-general",
                    severity: .high,
                    reason: "rm -rf is destructive and requires human approval.",
                    span: MatchSpan(start: command.count - 12, end: command.count - 6),
                    matchedText: "rm -rf",
                    searchText: "rm -rf ./src"
                )
            )
        ),
        command: ShellCommand(rawValue: command)
    )
    let lines = TestRenderer().render(vm, palette: colorOffPalette)
    #expect(lines.allSatisfy { $0.count <= 80 })
    #expect(lines.contains { $0.contains("^") })
    #expect(lines.contains { $0.contains("Matched: core.filesystem:rm-rf-general") })
}

@Test func testRenderer_longGitFlagsDoNotTrapAt80() {
    let command =
        "git -c protocol.version=2 -c core.quotepath=false -c log.showSignature=false reset --hard"
    let rule = RuleID(pack: .coreGit, pattern: "reset-hard")
    let vm = testViewModel(
        from: EvaluationResult(
            outcome: .deny(
                Deny(ruleID: rule, reason: "git reset --hard destroys uncommitted changes"),
                matched: RuleMatch(
                    ruleID: rule,
                    packID: .coreGit,
                    patternName: "reset-hard",
                    severity: .critical,
                    reason: "git reset --hard destroys uncommitted changes",
                    span: MatchSpan(start: 0, end: command.count),
                    matchedText: command,
                    searchText: command
                )
            )
        ),
        command: ShellCommand(rawValue: command),
        columns: 80
    )
    let lines = TestRenderer().render(vm, palette: colorOffPalette)
    #expect(lines.allSatisfy { $0.count <= 80 })
    #expect(lines.contains { $0.contains("^") })
    #expect(lines.contains { $0.contains("Matched: core.git:reset-hard") })
    #expect(lines.contains { $0.hasPrefix("Command:") })
}

@Test func testRenderer_wideColumnsKeepsReasonOnOneLine() {
    let reason =
        "rm -rf is destructive and requires human approval. Explain what you want to delete and why, then ask the user to run the command manually."
    let rule = RuleID(pack: .coreFilesystem, pattern: "rm-rf-general")
    let vm = testViewModel(
        from: EvaluationResult(
            outcome: .deny(
                Deny(ruleID: rule, reason: reason),
                matched: RuleMatch(
                    ruleID: rule,
                    packID: .coreFilesystem,
                    patternName: "rm-rf-general",
                    severity: .high,
                    reason: reason,
                    explanation: "Why this is dangerous: \\ - Gone",
                    span: MatchSpan(start: 0, end: 6),
                    matchedText: "rm -rf"
                )
            )
        ),
        command: ShellCommand(rawValue: "rm -rf"),
        columns: 160
    )
    let lines = TestRenderer().render(vm, palette: colorOffPalette)
    #expect(lines.contains { $0 == "Reason: \(reason)" })
    #expect(lines.contains { $0.hasPrefix("    • ") })
    #expect(lines.contains { $0.contains("Why this is dangerous:") })
}

@Test func testRenderer_colorOn_paintsLabelsPackResult() throws {
    let rule = RuleID(pack: .coreGit, pattern: "reset-hard")
    let vm = testViewModel(
        from: EvaluationResult(
            outcome: .deny(
                Deny(ruleID: rule, reason: "git reset --hard destroys uncommitted changes"),
                matched: RuleMatch(
                    ruleID: rule,
                    packID: .coreGit,
                    patternName: "reset-hard",
                    severity: .critical,
                    reason: "git reset --hard destroys uncommitted changes",
                    explanation: "intro\n\n\\ Why this is dangerous:",
                    span: MatchSpan(start: 0, end: 16),
                    matchedText: "git reset --hard"
                )
            )
        ),
        command: ShellCommand(rawValue: "git reset --hard")
    )
    let on = Palette(for: ColorCapability(colorsEnabled: true))
    let lines = TestRenderer().render(vm, palette: on)
    let pack = try #require(lines.first { stripCSI($0).hasPrefix("Pack:") })
    let pattern = try #require(lines.first { stripCSI($0).hasPrefix("Pattern:") })
    let result = try #require(lines.first { stripCSI($0).hasPrefix("Result:") })
    let heading = try #require(lines.first { stripCSI($0).contains("Why this is dangerous:") })
    #expect(pack.contains(on.muted))
    #expect(pack.contains(on.heading))
    #expect(pattern.contains(on.mark))
    #expect(result.contains(on.muted))
    #expect(result.contains(on.deny))
    #expect(heading.contains(on.silver))
    #expect(!heading.contains(on.heading))
    #expect(stripCSI(result) == "Result: BLOCKED")
}

@Test func explainRenderer_allowAndCustomSuggestions() {
    var vm = explainViewModel(from: EvaluationResult(outcome: .plain), command: ShellCommand(rawValue: "git status"))
    vm.semantic = ExplainSemanticView(
        action: "unknown",
        scope: "wrapper",
        effect: "none",
        remote: "origin",
        ref: "HEAD",
        pathspec: "file.swift",
        path: "/tmp/file",
        kind: "source code",
        category: "ssh",
        catalogRule: "core.secrets/id",
        wrappers: []
    )
    vm.suggestions = [
        ExplainSuggestion(kind: .workflowFix, text: "Ask the operator"),
        ExplainSuggestion(kind: .documentation, text: "See the handbook", url: "https://example.com/docs"),
    ]
    let lines = ExplainRenderer().render(vm, palette: colorOffPalette)
    let text = lines.joined(separator: "\n")
    #expect(text.contains("Decision: ALLOW"))
    #expect(text.contains("Action") && text.contains("unknown"))
    #expect(text.contains("Effect") && text.contains("none"))
    #expect(text.contains("Remote") && text.contains("origin"))
    #expect(text.contains("Ref") && text.contains("HEAD"))
    #expect(text.contains("Pathspec"))
    #expect(text.contains("Path") && text.contains("/tmp/file"))
    #expect(text.contains("Kind") && text.contains("source code"))
    #expect(text.contains("Category") && text.contains("ssh"))
    #expect(text.contains("Catalog") && text.contains("core.secrets/id"))
    #expect(text.contains("Wrappers") == false)
    #expect(text.contains("Workflow fix: Ask the operator"))
    #expect(text.contains("See: https://example.com/docs"))
}

@Test func explainRenderer_emptyExplanationIsOmitted() {
    var vm = explainViewModel(from: EvaluationResult(outcome: .plain), command: ShellCommand(rawValue: "true"))
    vm.explanation = "\\ - "
    let text = ExplainRenderer().render(vm, palette: colorOffPalette).joined(separator: "\n")
    #expect(text.contains("Explanation") == false)
}

@Test func testRenderer_allowIncompleteAndEmptyExplanation() {
    let on = Palette(for: ColorCapability(colorsEnabled: true))
    let allow = TestRenderer().render(
        testViewModel(from: EvaluationResult(outcome: .plain), command: ShellCommand(rawValue: "true")),
        palette: on
    )
    #expect(allow.contains { stripCSI($0) == "Result: ALLOWED" && $0.contains(on.allow) })

    let incomplete = TestRenderer().render(
        testViewModel(
            from: EvaluationResult(outcome: .indeterminate(.commandTooLarge)),
            command: ShellCommand(rawValue: "true")
        ),
        palette: colorOffPalette
    )
    #expect(incomplete.contains("Result: INCOMPLETE"))

    var emptyEssay = testViewModel(
        from: EvaluationResult(outcome: .plain),
        command: ShellCommand(rawValue: "true")
    )
    emptyEssay.explanation = ""
    let empty = TestRenderer().render(emptyEssay, palette: colorOffPalette)
    #expect(empty.contains("Explanation:"))
}

@Test func testRenderer_windowsLongCommandWithoutSpanAndOverflowLabel() {
    let long = String(repeating: "x", count: 90)
    let noSpan = TestViewModel(
        command: ShellCommand(rawValue: long),
        resultWord: "ALLOWED",
        resultTone: .allow
    )
    let truncated = TestRenderer().render(noSpan, palette: colorOffPalette)
    #expect(truncated[0].hasPrefix("Command: "))
    #expect(truncated[0].hasSuffix("..."))
    #expect(truncated[0].count <= 80)

    let overflow = TestViewModel(
        command: ShellCommand(rawValue: "rm -rf ./src"),
        span: MatchSpan(start: 0, end: 6),
        matchedLabel: String(repeating: "core.filesystem:rm-rf-general/", count: 6),
        packDisplay: "core.filesystem",
        patternName: "rm-rf-general",
        reason: "rm -rf is destructive",
        resultWord: "BLOCKED",
        resultTone: .deny
    )
    let lines = TestRenderer().render(overflow, palette: colorOffPalette)
    #expect(lines.contains { $0.contains("Matched:") })
    #expect(lines.allSatisfy { $0.count <= 80 })
}

@Test func testRenderer_previewEmptyRestAndPastEndSpan() {
    let preview = TestViewModel(
        command: ShellCommand(rawValue: "rm -rf"),
        explanation: "intro\n\nPreview leftovers: " + String(repeating: "keep ", count: 20),
        resultWord: "BLOCKED",
        resultTone: .deny
    )
    let previewLines = TestRenderer().render(preview, palette: colorOffPalette)
    #expect(previewLines.contains { $0.contains("Preview leftovers:") })
    #expect(previewLines.contains { $0.hasPrefix("  keep") || $0.contains("keep keep") })

    let pastEnd = TestViewModel(
        command: ShellCommand(rawValue: "rm"),
        span: MatchSpan(start: 8, end: 12),
        matchedLabel: "core.filesystem:rm-rf-general",
        resultWord: "BLOCKED",
        resultTone: .deny
    )
    let past = TestRenderer().render(pastEnd, palette: colorOffPalette)
    #expect(past.contains { $0.contains("^") } == false)
}

@Test func testRenderer_alignsCaretsUnderMatch() {
    let rule = RuleID(pack: .coreFilesystem, pattern: "rm-rf-general")
    let vm = testViewModel(
        from: EvaluationResult(
            outcome: .deny(
                Deny(ruleID: rule, reason: "rm -rf is destructive and requires human approval."),
                matched: RuleMatch(
                    ruleID: rule,
                    packID: .coreFilesystem,
                    patternName: "rm-rf-general",
                    severity: .high,
                    reason: "rm -rf is destructive and requires human approval.",
                    span: MatchSpan(start: 0, end: 6),
                    matchedText: "rm -rf"
                )
            )
        ),
        command: ShellCommand(rawValue: "rm -rf ./src")
    )
    let lines = TestRenderer().render(vm, palette: colorOffPalette)
    #expect(lines[0] == "Command: rm -rf ./src")
    #expect(lines[1] == "         ^^^^^^")
    #expect(lines[2] == "         └── Matched: core.filesystem:rm-rf-general")
    #expect(lines.contains { $0 == "Pack: core.filesystem" })
    #expect(lines.contains { $0 == "Pattern: rm-rf-general" })
    #expect(lines.contains { $0 == "Source: pack" })
    #expect(lines.last == "Result: BLOCKED")
}
