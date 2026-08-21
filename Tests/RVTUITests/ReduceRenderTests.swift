import Testing
import RVDomain
import RVPresentation
import RVTheme
@testable import RVTUI

@Test func reduce_upDownQuitWithoutTTY() {
    var state = BrowseState(rows: ["a", "b", "c"], pageSize: 2)
    #expect(state.selected == 0)
    #expect(state.page == 0)

    state = reduce(state, .down)
    #expect(state.selected == 1)
    state = reduce(state, .down)
    #expect(state.selected == 2)
    #expect(state.page == 1)
    state = reduce(state, .down)
    #expect(state.selected == 2)
    state = reduce(state, .up)
    #expect(state.selected == 1)
    state = reduce(state, .quit)
    #expect(state.quit)
    let same = reduce(state, .enter)
    #expect(same.selected == state.selected)
}

@Test func keyMap_isPure() {
    #expect(mapKey("j") == .down)
    #expect(mapKey("k") == .up)
    #expect(mapKey("\u{001B}[A") == .up)
    #expect(mapKey("\u{001B}[B") == .down)
    #expect(mapKey("q") == .quit)
    #expect(mapKey("\u{001B}") == .quit)
    #expect(mapKey("\r") == .enter)
    #expect(mapKey("x") == .noop)
}

@Test func render_colorOff_hasNoEscape() {
    let state = BrowseState(rows: ["one", "two"], selected: 1)
    let lines = render(state, palette: colorOffPalette)
    #expect(lines.count == 2)
    #expect(lines[1].hasPrefix(">"))
    #expect(lines.allSatisfy { !$0.contains("\u{001B}") })
}

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
    let on = palette(for: ColorCapability(colorsEnabled: true))
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
    let on = palette(for: ColorCapability(colorsEnabled: true))
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

    let on = palette(for: ColorCapability(colorsEnabled: true))
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

    let on = palette(for: ColorCapability(colorsEnabled: true))
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
    let on = palette(for: ColorCapability(colorsEnabled: true))
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
