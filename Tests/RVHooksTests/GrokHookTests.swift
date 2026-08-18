import Foundation
import Testing
import RVDomain
@testable import RVHooks

private let codec = GrokHostCodec()

private func grokFixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/grok/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

private func grokExpected(_ stem: String) throws -> (stdout: String, exit: Int32) {
    let stdout = try grokFixture("\(stem).out")
    let exitText = try grokFixture("\(stem).exit")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let code = try #require(Int32(exitText))
    return (stdout, code)
}

@Test(arguments: [
    ("allow-git-status.json", "git status"),
    ("deny-git-reset-hard.json", "git reset --hard"),
    ("deny-reason-is-one-line.json", "git reset --hard"),
    ("allow-legacy-run-terminal-cmd.json", "git status"),
    ("allow-medium-stash-drop.json", "git stash drop"),
    ("deny-indeterminate-oversize.json", "git reset --hard"),
])
func grokDecode_extractsShellCommand(_ file: String, expected: String) throws {
    let request = codec.decode(try grokFixture(file))
    #expect(request.host == .grok)
    #expect(request.command?.rawValue == expected)
}

@Test(arguments: [
    "allow-non-shell-read.json",
    "allow-empty-command.json",
    "ignore-passive-session-start.json",
    "malformed.txt",
])
func grokDecode_skipsEvaluate(_ file: String) throws {
    let request = codec.decode(try grokFixture(file))
    #expect(request.host == .grok)
    #expect(request.command == nil)
}

@Test func grokDecode_acceptsBashToolName() {
    let stdin = """
    {"hookEventName":"pre_tool_use","toolName":"Bash","toolInput":{"command":"git status"}}
    """
    #expect(codec.decode(stdin).command?.rawValue == "git status")
}

@Test func grokEncodeAllow_isEmptyExitZero() throws {
    let wire = codec.encodeAllow()
    let expected = try grokExpected("allow-git-status")
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    #expect(wire.stdout.isEmpty)
}

@Test func grokEncodeDeny_matchesResetHardFixture() throws {
    let reason =
        "Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once."
    let wire = codec.encodeDeny(reason: reason)
    let expected = try grokExpected("deny-git-reset-hard")
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    #expect(wire.stdout.hasSuffix("\n"))
    #expect(wire.stdout.contains("\"decision\":\"deny\""))
    #expect(wire.stdout.contains("block") == false)
    #expect(wire.stdout.contains("hookSpecificOutput") == false)
    #expect(wire.stdout.contains("updatedInput") == false)
}

@Test func grokEncodeDeny_reasonIsOneLine() throws {
    let reason =
        "Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once."
    let wire = codec.encodeDeny(reason: reason)
    let parsed = try grokDenyObject(wire.stdout)
    #expect(parsed.reason.contains("\n") == false)
    #expect(parsed.reason.contains("═") == false)
    #expect(parsed.reason.contains("\u{001B}") == false)
    #expect(parsed.keys.sorted() == ["decision", "reason"])
}

@Test func grokEncodeDeny_indeterminateUsesPlanSentence() throws {
    let reason = "rv could not finish evaluating this command. Run it in Terminal."
    let wire = codec.encodeDeny(reason: reason)
    let expected = try grokExpected("deny-indeterminate-oversize")
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    #expect(wire.stdout.contains("core.git") == false)
    #expect(wire.stdout.contains("reset-hard") == false)
}

private struct GrokDenyObject {
    var reason: String
    var keys: [String]
}

private func grokDenyObject(_ stdout: String) throws -> GrokDenyObject {
    let data = try #require(stdout.data(using: .utf8))
    let object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let reason = try #require(object["reason"] as? String)
    return GrokDenyObject(reason: reason, keys: Array(object.keys))
}
