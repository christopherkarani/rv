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

private func grokOversizeHookStdin(paddingCount: Int = 65_537) -> String {
    let command = String(repeating: "A", count: paddingCount) + " git reset --hard"
    return """
    {"hookEventName":"pre_tool_use","toolName":"run_terminal_command","toolInput":{"command":\(jsonFragment(command))}}
    """
}

private func jsonFragment(_ value: String) -> String {
    guard
        let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
        let text = String(data: data, encoding: .utf8)
    else {
        return "\"\""
    }
    return text
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
])
func grokDecode_extractsShellCommand(_ file: String, expected: String) throws {
    guard case .request(let request) = codec.decode(try grokFixture(file)) else {
        Issue.record("expected .request for \(file)")
        return
    }
    #expect(request.host == .grok)
    guard case .shell(_, let command, _, _) = request else {
        Issue.record("expected .shell for \(file)")
        return
    }
    #expect(command.rawValue == expected)
}

@Test func grokDecode_oversizeExtractsFullCommand() throws {
    let stdin = grokOversizeHookStdin()
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for oversize stdin")
        return
    }
    #expect(request.host == .grok)
    guard case .shell(_, let command, _, _) = request else {
        Issue.record("expected .shell for oversize stdin")
        return
    }
    #expect(command.rawValue.utf8.count > 65_536)
    #expect(command.rawValue.hasSuffix(" git reset --hard"))
}

@Test(arguments: [
    "ignore-passive-session-start.json",
])
func grokDecode_otherToolOrEventIsForeign(_ file: String) throws {
    #expect(codec.decode(try grokFixture(file)) == .foreign)
}

@Test func grokDecode_readFileIsFileTool() throws {
    guard case .request(let request) = codec.decode(try grokFixture("allow-non-shell-read.json")) else {
        Issue.record("expected .request for read_file")
        return
    }
    guard case .file(_, let file, _, _) = request else {
        Issue.record("expected .file for read_file")
        return
    }
    #expect(file.kind == .read)
    #expect(file.path.rawValue == "/tmp/rv-hook-fixture/README.md")
}

@Test func grokDecode_readFileEnvIsCatalogPath() throws {
    guard case .request(let request) = codec.decode(try grokFixture("deny-file-env.json")) else {
        Issue.record("expected .request for deny-file-env")
        return
    }
    guard case .file(_, let file, _, _) = request else {
        Issue.record("expected .file for deny-file-env")
        return
    }
    #expect(file.kind == .read)
    #expect(file.path.rawValue == "/tmp/rv-oracle/.env")
}

@Test func grokDecode_emptyCommandIsMissingCommand() throws {
    #expect(codec.decode(try grokFixture("deny-empty-command.json")) == .malformed(.missingCommand))
}

@Test func grokDecode_malformedIsUnreadable() throws {
    #expect(codec.decode(try grokFixture("malformed.txt")) == .malformed(.unreadable))
}

@Test func grokDecode_acceptsBashToolName() {
    let stdin = """
    {"hookEventName":"pre_tool_use","toolName":"Bash","toolInput":{"command":"git status"}}
    """
    #expect(
        codec.decode(stdin)
            == .request(
                .shell(
                    host: .grok,
                    command: ShellCommand(rawValue: "git status"),
                    cwd: nil,
                    session: nil
                )
            )
    )
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
        resetHardHostDeny
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
        resetHardHostDeny
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

@Test func grokDecode_emptyCwdIsNil() {
    let stdin = """
    {"hookEventName":"pre_tool_use","cwd":"","toolName":"run_terminal_command","toolInput":{"command":"git status"}}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for empty cwd")
        return
    }
    #expect(request.cwd == nil)
}

@Test func grokDecode_missingCwdIsNil() {
    let stdin = """
    {"hookEventName":"pre_tool_use","toolName":"run_terminal_command","toolInput":{"command":"git status"}}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for missing cwd")
        return
    }
    #expect(request.cwd == nil)
    #expect(request.session == nil)
}

@Test func grokDecode_readsSessionId() throws {
    guard case .request(let request) = codec.decode(try grokFixture("allow-git-status.json")) else {
        Issue.record("expected .request for sessionId")
        return
    }
    #expect(request.session == SessionID(validating: "abc-123"))
}

@Test func grokDecode_emptySessionIsNil() {
    let stdin = """
    {"hookEventName":"pre_tool_use","sessionId":"","toolName":"run_terminal_command","toolInput":{"command":"git status"}}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for empty sessionId")
        return
    }
    #expect(request.session == nil)
}

@Test func hookDispatch_fileDenyVoiceDoesNotUseEmptyShellCommand() async throws {
    let reason = "Access to a sensitive path is not allowed."
    let stdin = try grokFixture("deny-file-env.json")
    let wire = await hookWire(
        host: .grok,
        stdin: stdin,
        world: hookWorld(
            evaluate: { _, _ in
                Issue.record("file event must not evaluate an empty shell command")
                return EvaluationResult(outcome: .plain)
            },
            evaluateFile: { _, _ in
                let ruleID = RuleID(pack: .coreSecrets, pattern: "env")
                return EvaluationResult(
                    outcome: .deny(
                        Deny(ruleID: ruleID, reason: reason),
                        matched: RuleMatch(
                            ruleID: ruleID,
                            severity: .high,
                            reason: reason
                        )
                    )
                )
            }
        )
    )
    #expect(wire.stdout.contains(hostFileDenyLine(reason: reason)))
    #expect(wire.stdout.contains("\"decision\":\"deny\""))
    #expect(wire.stdout.contains("Blocked  (") == false)
}
