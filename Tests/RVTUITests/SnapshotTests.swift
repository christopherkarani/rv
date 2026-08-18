import Foundation
import Testing
import RVDomain
import RVPresentation
import RVTheme
@testable import RVTUI

private func snapshotDirectory() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
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

private func resetHardDeny() -> DenyViewModel {
    denyViewModel(
        from: EvaluationResult(
            decision: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                    reason: "git reset --hard destroys uncommitted changes. Use 'git stash' first."
                )
            )
        ),
        command: ShellCommand(rawValue: "git reset --hard")
    )!
}

private func rmRfDeny() -> DenyViewModel {
    denyViewModel(
        from: EvaluationResult(
            decision: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreFilesystem, pattern: "rm-rf-general"),
                    reason: "rm -rf is destructive and requires human approval. Explain what you want to delete and why, then ask the user to run the command manually."
                )
            )
        ),
        command: ShellCommand(rawValue: "rm -rf ./src")
    )!
}

@Test func snapshot_prettyDenyGitResetHard() throws {
    let lines = DenyRenderer().render(resetHardDeny(), palette: colorOffPalette)
    assertWidth(lines, name: "pretty-deny-git-reset-hard")
    #expect(joined(lines) == (try loadSnapshot("pretty-deny-git-reset-hard.txt")))
    #expect(lines.filter { $0.hasPrefix("blocked") }.count == 1)
}

@Test func snapshot_prettyDenyRmRf() throws {
    let lines = DenyRenderer().render(rmRfDeny(), palette: colorOffPalette)
    assertWidth(lines, name: "pretty-deny-rm-rf")
    #expect(joined(lines) == (try loadSnapshot("pretty-deny-rm-rf.txt")))
}

@Test func snapshot_prettyAllowGitStatus() throws {
    let lines = prettyAllowLines()
    #expect(joined(lines) == (try loadSnapshot("pretty-allow-git-status.txt")))
    #expect(!joined(lines).contains("blocked"))
    #expect(!joined(lines).contains("deny"))
}

@Test func snapshot_prettyExplainGitResetHard() throws {
    let vm = explainViewModel(
        from: EvaluationResult(
            decision: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                    reason: "git reset --hard destroys uncommitted changes. Use 'git stash' first."
                )
            ),
            matched: RuleMatch(
                ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                packID: .coreGit,
                patternName: "reset-hard",
                severity: .critical,
                reason: "git reset --hard destroys uncommitted changes. Use 'git stash' first."
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
        from: EvaluationResult(decision: .allow),
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
    let lines = DenyRenderer().render(resetHardDeny(), palette: colorOffPalette)
    let text = joined(lines)
    #expect(text == (try loadSnapshot("nocolor-deny-no-esc.txt")))
    #expect(!text.utf8.contains(0x1B))
}

@Test func snapshot_hostDenyText() throws {
    let result = EvaluationResult(
        decision: .deny(
            Deny(
                ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                reason: "git reset --hard destroys uncommitted changes. Use 'git stash' first."
            )
        )
    )
    let text = hostDenyText(from: result, command: ShellCommand(rawValue: "git reset --hard"))
    #expect(text == (try loadSnapshot("host-deny-text-git-reset-hard.txt")))
    #expect(text?.contains("core.git/reset-hard") == true)
    #expect(text?.contains("rv allow-once") == true)
    #expect(text?.contains("═") == false)
}
