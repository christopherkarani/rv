import Foundation
import Testing
import RVDomain
import RVHooks
import RVPresentation
import RVTheme
@testable import RVCLI

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

private func trimOneNewline(_ text: String) -> String {
    text.hasSuffix("\n") ? String(text.dropLast()) : text
}

private func prettyProbe(plain: Bool = false, noColor: Bool = false, ci: Bool = false, noColorEnv: Bool = false) -> ThemeProbe {
    ThemeProbe(
        stdinIsTTY: true,
        stdoutIsTTY: true,
        jsonFlag: false,
        robotFlag: false,
        plainFlag: plain,
        noColorFlag: noColor,
        ci: ci,
        noColorEnv: noColorEnv,
        termDumb: false
    )
}

private func robotProbe() -> ThemeProbe {
    ThemeProbe(
        stdinIsTTY: false,
        stdoutIsTTY: false,
        jsonFlag: true,
        robotFlag: true,
        plainFlag: false,
        noColorFlag: false,
        ci: false,
        noColorEnv: false,
        termDumb: false
    )
}

@Test func test_prettyDeny_resetHard_exit1() async throws {
    let result = try await cliRun(
        kind: .test,
        command: "git reset --hard",
        probe: prettyProbe(plain: true),
        requested: .automatic
    )
    #expect(result.exitCode == 1)
    #expect(trimOneNewline(result.stdout) == (try loadSnapshot("pretty-deny-git-reset-hard.txt")))
}

@Test func test_prettyAllow_gitStatus_exit0() async throws {
    let result = try await cliRun(
        kind: .test,
        command: "git status",
        probe: prettyProbe(plain: true),
        requested: .automatic
    )
    #expect(result.exitCode == 0)
    #expect(trimOneNewline(result.stdout) == (try loadSnapshot("pretty-allow-git-status.txt")))
    #expect(!result.stdout.localizedCaseInsensitiveContains("blocked"))
    #expect(!result.stdout.contains("denied"))
}

@Test func explain_prettyDeny_exit0() async throws {
    let result = try await cliRun(
        kind: .explain,
        command: "git reset --hard",
        probe: prettyProbe(plain: true),
        requested: .automatic
    )
    #expect(result.exitCode == 0)
    #expect(trimOneNewline(result.stdout) == (try loadSnapshot("pretty-explain-git-reset-hard.txt")))
}

@Test func test_robotAllow_andDeny() async throws {
    let allow = try await cliRun(
        kind: .test,
        command: "git status",
        probe: robotProbe(),
        requested: .robot
    )
    #expect(allow.exitCode == 0)
    #expect(trimOneNewline(allow.stdout) == (try loadSnapshot("robot-allow-git-status.json")))
    #expect(!allow.stdout.contains("\u{001B}"))
    #expect(!allow.stdout.contains("reason"))

    let deny = try await cliRun(
        kind: .test,
        command: "git reset --hard",
        probe: robotProbe(),
        requested: .robot
    )
    #expect(deny.exitCode == 1)
    #expect(trimOneNewline(deny.stdout) == (try loadSnapshot("robot-deny-git-reset-hard.json")))
    #expect(!deny.stdout.contains("\u{001B}"))
    let object = try JSONSerialization.jsonObject(with: Data(deny.stdout.utf8))
    let json = try #require(object as? [String: Any])
    #expect(json["schema"] as? String == "rv.test.v1")
    #expect(json["decision"] as? String == "deny")
    #expect(json["pack_id"] as? String == "core.git")
    #expect(json["rule_id"] as? String == "core.git:reset-hard")
}

@Test func test_plainAndNoColor_haveNoEscape() async throws {
    for probe in [prettyProbe(plain: true), prettyProbe(noColor: true), prettyProbe(ci: true), prettyProbe(noColorEnv: true)] {
        let result = try await cliRun(
            kind: .test,
            command: "git reset --hard",
            probe: probe,
            requested: .automatic
        )
        #expect(!result.stdout.utf8.contains(0x1B))
        #expect(browseEligible(probe) == false || probe.noColorFlag)
    }
}

@Test func hostDenyText_stashDropIsNil() async throws {
    let result = try await cliEvaluate("git stash drop")
    #expect(result.decision == .allow)
    #expect(result.matched?.ruleID.rawValue == "core.git:stash-drop")
    #expect(hostDenyText(from: result, command: ShellCommand(rawValue: "git stash drop")) == nil)
    let pretty = CommandRun.render(
        kind: .test,
        result: result,
        command: ShellCommand(rawValue: "git stash drop"),
        probe: prettyProbe(plain: true),
        requested: .pretty
    )
    #expect(pretty.stdout.contains("Command: git stash drop"))
    #expect(pretty.stdout.contains("Result: ALLOWED"))
    #expect(!pretty.stdout.contains("Result: BLOCKED"))
}

@Test func hostDenyText_indeterminateNoRuleID() {
    let result = EvaluationResult(outcome: .indeterminate(.commandTooLarge))
    let text = hostDenyText(from: result, command: ShellCommand(rawValue: "x"))
    #expect(text == "rv could not finish evaluating this command. Run it in Terminal.")
}

@Test func prettyWriter_joinsWithNewline() {
    #expect(PrettyWriter.join(["a", "b"]) == "a\nb\n")
}

@Test func test_prettyDeny_doesNotFallBackToAllow() {
    let result = EvaluationResult(
        outcome: .deny(
            Deny(
                ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                reason: "git reset --hard destroys uncommitted changes"
            ),
            matched: nil
        )
    )
    let rendered = CommandRun.render(
        kind: .test,
        result: result,
        command: ShellCommand(rawValue: "git reset --hard"),
        probe: prettyProbe(plain: true),
        requested: .pretty
    )
    #expect(rendered.exitCode == 1)
    #expect(rendered.stdout.contains("Result: BLOCKED"))
    #expect(!rendered.stdout.contains("Result: ALLOWED"))
}

@Test func test_prettyIndeterminate_isPlanSentence() {
    let rendered = CommandRun.render(
        kind: .test,
        result: EvaluationResult(outcome: .indeterminate(.corePacksUnavailable)),
        command: ShellCommand(rawValue: "git status"),
        probe: prettyProbe(plain: true),
        requested: .pretty
    )
    #expect(rendered.exitCode == 1)
    #expect(rendered.stdout.contains("Command: git status"))
    #expect(rendered.stdout.contains(incompleteEvalSentence))
    #expect(rendered.stdout.contains("Result: INCOMPLETE"))
}

@Test func test_prettyDeny_pipelineHighlightsDenyingSegment() async throws {
    let rendered = try await cliRun(
        kind: .test,
        command: "rm -rf /tmp/foo && rm -rf ./src",
        probe: prettyProbe(plain: true),
        requested: .pretty
    )
    #expect(rendered.exitCode == 1)
    #expect(rendered.stdout.contains("Command: rm -rf /tmp/foo && rm -rf ./src"))
    #expect(rendered.stdout.contains("\n" + String(repeating: " ", count: 28) + "^^^^^^\n"))
    #expect(rendered.stdout.contains("Matched: core.filesystem:rm-rf-general"))
    #expect(!rendered.stdout.contains("\n" + String(repeating: " ", count: 9) + "^^^^^^"))
}

@Test func testExplain_sameExitAsTest() async throws {
    let deny = try await cliRun(
        kind: .testExplain,
        command: "git reset --hard",
        probe: prettyProbe(),
        requested: .automatic
    )
    #expect(deny.exitCode == 1)
    let allow = try await cliRun(
        kind: .testExplain,
        command: "git status",
        probe: prettyProbe(),
        requested: .automatic
    )
    #expect(allow.exitCode == 0)
}
