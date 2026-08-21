import Foundation
import Testing
import RVDomain
import RVPresentation
import RVTheme
@testable import RVTUI

private func snapshotDirectory() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/snapshots/phase-1b")
}

private func loadSnapshot(_ name: String) throws -> String {
    let url = snapshotDirectory().appendingPathComponent(name)
    let text = try String(contentsOf: url, encoding: .utf8)
    return text.hasSuffix("\n") ? String(text.dropLast()) : text
}

private func joined(_ lines: [String]) -> String {
    lines.joined(separator: "\n")
}

private func assertWidth(_ lines: [String], file: String = #file, name: String) {
    for line in lines {
        #expect(line.count <= 80, "\(name) line exceeds 80: \(line)")
        #expect(!line.contains("\u{001B}"), "\(name) has escape")
    }
}

private func resetHardTest() -> TestViewModel {
    let rule = RuleID(pack: .coreGit, pattern: "reset-hard")
    let reason = "git reset --hard destroys uncommitted changes. Use 'git stash' first."
    return testViewModel(
        from: EvaluationResult(
            outcome: .deny(
                Deny(ruleID: rule, reason: reason),
                matched: RuleMatch(
                    ruleID: rule,
                    packID: .coreGit,
                    patternName: "reset-hard",
                    severity: .critical,
                    reason: reason,
                    explanation: resetHardPackExplanation,
                    span: MatchSpan(start: 0, end: 16),
                    matchedText: "git reset --hard"
                )
            )
        ),
        command: ShellCommand(rawValue: "git reset --hard")
    )
}

private func rmRfTest() -> TestViewModel {
    let rule = RuleID(pack: .coreFilesystem, pattern: "rm-rf-general")
    let reason =
        "rm -rf is destructive and requires human approval. Explain what you want to delete and why, then ask the user to run the command manually."
    return testViewModel(
        from: EvaluationResult(
            outcome: .deny(
                Deny(ruleID: rule, reason: reason),
                matched: RuleMatch(
                    ruleID: rule,
                    packID: .coreFilesystem,
                    patternName: "rm-rf-general",
                    severity: .high,
                    reason: reason,
                    explanation: rmRfPackExplanation,
                    span: MatchSpan(start: 0, end: 6),
                    matchedText: "rm -rf"
                )
            )
        ),
        command: ShellCommand(rawValue: "rm -rf ./src")
    )
}

private let rmRfPackExplanation = """
rm -rf recursively removes files and directories without confirmation prompts. \\ The -f (force) flag suppresses all warnings, making accidental deletions \\ silent and immediate.

\\ Why this is dangerous: \\ - Deleted files bypass the trash - they're gone immediately \\ - Typos in paths can delete unintended directories \\ - Wildcards can expand to match more than expected \\ - No undo mechanism exists

\\ Safe alternatives: \\ - rm -ri: Interactive mode, confirms each file \\ - trash-cli: Moves files to trash instead of deleting \\ - rm -rf in literal /tmp or /var/tmp subdirectories: Allowed \\ - Variable-rooted paths such as $TMPDIR: Reviewed because the environment may point anywhere

\\ Preview what would be deleted: \\ find /path/to/delete -type f | wc -l # Count files \\ ls -la /path/to/delete # List contents
"""

private let resetHardPackExplanation = """
git reset --hard discards ALL uncommitted changes in your working directory \\ AND staging area. This is one of the most dangerous git commands because \\ changes that were never committed cannot be recovered by any means.

\\ What gets destroyed: \\ - All modified files revert to the target commit \\ - All staged changes are lost \\ - Untracked files remain (use git clean to remove those)

\\ Safer alternatives: \\ - git reset --soft <ref>: Move HEAD but keep all changes staged \\ - git reset --mixed <ref>: Move HEAD, unstage changes, keep working dir (default) \\ - git stash: Save changes before resetting

\\ Preview what would be lost: git status && git diff
"""

@Test func snapshot_prettyDenyGitResetHard() throws {
    let lines = TestRenderer().render(resetHardTest(), palette: colorOffPalette)
    assertWidth(lines, name: "pretty-deny-git-reset-hard")
    #expect(joined(lines) == (try loadSnapshot("pretty-deny-git-reset-hard.txt")))
    #expect(lines.contains { $0.hasPrefix("Command: git reset --hard") })
    #expect(lines.contains { $0.contains("^^^^^^") })
    #expect(lines.contains { $0.contains("Matched: core.git:reset-hard") })
    #expect(lines.contains { $0 == "Result: BLOCKED" })
}

@Test func snapshot_prettyDenyRmRf() throws {
    let lines = TestRenderer().render(rmRfTest(), palette: colorOffPalette)
    assertWidth(lines, name: "pretty-deny-rm-rf")
    #expect(joined(lines) == (try loadSnapshot("pretty-deny-rm-rf.txt")))
    #expect(lines.contains { $0.contains("Matched: core.filesystem:rm-rf-general") })
    #expect(lines.contains { $0.contains("Why this is dangerous") })
    #expect(lines.contains { $0 == "Source: pack" })
}

@Test func snapshot_prettyAllowGitStatus() throws {
    let lines = TestRenderer().render(
        testViewModel(
            from: EvaluationResult(outcome: .plain),
            command: ShellCommand(rawValue: "git status")
        ),
        palette: colorOffPalette
    )
    #expect(joined(lines) == (try loadSnapshot("pretty-allow-git-status.txt")))
    #expect(!joined(lines).localizedCaseInsensitiveContains("blocked"))
    #expect(!joined(lines).contains("deny"))
}

@Test func snapshot_prettyExplainGitResetHard() throws {
    let vm = explainViewModel(
        from: EvaluationResult(
            outcome: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                    reason: "git reset --hard destroys uncommitted changes. Use 'git stash' first."
                ),
                matched: RuleMatch(
                    ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                    packID: .coreGit,
                    patternName: "reset-hard",
                    severity: .critical,
                    reason: "git reset --hard destroys uncommitted changes. Use 'git stash' first.",
                    explanation: resetHardPackExplanation,
                    regex: #"(?:^|[^[:alnum:]_-])git\s+(?:\S+\s+)*reset\s+--hard"#
                )
            )
        ),
        command: ShellCommand(rawValue: "git reset --hard")
    )
    let lines = ExplainRenderer().render(vm, palette: colorOffPalette)
    assertWidth(lines, name: "pretty-explain-git-reset-hard")
    #expect(joined(lines) == (try loadSnapshot("pretty-explain-git-reset-hard.txt")))
    #expect(!joined(lines).contains("μs"))
}

@Test func snapshot_prettyExplainGitStatus() throws {
    let vm = explainViewModel(
        from: EvaluationResult(outcome: .plain),
        command: ShellCommand(rawValue: "git status")
    )
    let lines = ExplainRenderer().render(vm, palette: colorOffPalette)
    assertWidth(lines, name: "pretty-explain-git-status")
    #expect(joined(lines) == (try loadSnapshot("pretty-explain-git-status.txt")))
    #expect(!joined(lines).contains("run it in Terminal"))
}

@Test func snapshot_prettyPacksDayOne() throws {
    let vm = packsViewModel(
        enabled: dayOnePackIDs,
        catalog: [
            (.coreFilesystem, "filesystem"),
            (.coreGit, "git"),
        ]
    )
    let lines = PacksRenderer().render(vm, palette: colorOffPalette)
    assertWidth(lines, name: "pretty-packs-day-one")
    #expect(joined(lines) == (try loadSnapshot("pretty-packs-day-one.txt")))
    #expect(lines.count == 2)
}

@Test func snapshot_nocolorDenyNoEsc() throws {
    let lines = TestRenderer().render(resetHardTest(), palette: colorOffPalette)
    let text = joined(lines)
    #expect(text == (try loadSnapshot("nocolor-deny-no-esc.txt")))
    #expect(!text.utf8.contains(0x1B))
}


