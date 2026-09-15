import Foundation
import Testing
import RVDomain
@testable import RVHooks

/// Illegal program named by T3: `HookRequest(command: "", file: file, hostAsk: .spend)`.
/// File+spend and empty shell-as-file-event must not inhabit `HookRequest`.
@Test func hookRequest_fileInvocationCannotCarrySpend() {
    let file = FileToolAction(
        kind: .read,
        path: FileToolPath(rawValue: "/tmp/rv-oracle/.env")
    )
    let request = HookRequest(
        host: .claude,
        invocation: .file(file)
    )
    switch request.invocation {
    case .file(let decoded):
        #expect(decoded == file)
    case .shell(_, .spend):
        Issue.record("file+spend is unrepresentable")
    case .shell:
        Issue.record("expected .file, not .shell")
    }
}

@Test func hookRequest_shellSpendHasNoFile() {
    let command = ShellCommand(rawValue: "git reset --hard")
    let request = HookRequest(
        host: .claude,
        invocation: .shell(command: command, ask: .spend)
    )
    switch request.invocation {
    case .shell(let decoded, .spend):
        #expect(decoded == command)
    case .file:
        Issue.record("shell spend is not a file event")
    case .shell:
        Issue.record("expected .spend on shell")
    }
}

@Test func claudeDecode_fileToolHasNoAsk() throws {
    let stdin = """
    {"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/rv-oracle/.env"},"hostAsk":"spend"}
    """
    guard case .request(let request) = ClaudeHostCodec().decode(stdin) else {
        Issue.record("expected .request for Claude file+hostAsk envelope")
        return
    }
    switch request.invocation {
    case .file(let file):
        #expect(file.kind == .read)
        #expect(file.path.rawValue == "/tmp/rv-oracle/.env")
    case .shell(_, .spend):
        Issue.record("Claude file decode must not carry HostAskHookIntent")
    case .shell:
        Issue.record("expected .file")
    }
}

@Test func grokDecode_emptyCommandWithoutFileIsMalformed() throws {
    #expect(
        GrokHostCodec().decode(try grokEmptyCommandFixture()) == .malformed(.missingCommand)
    )
}

@Test func proposedAction_fileRequestIsNotEmptyShellFingerprint() throws {
    guard case .request(let request) = GrokHostCodec().decode(try grokFileEnvFixture()) else {
        Issue.record("expected .request for grok file env")
        return
    }
    guard case .file = request.invocation else {
        Issue.record("expected .file")
        return
    }
    let action = GrokHostCodec().proposedAction(from: request)
    #expect(action.supportingCommand == nil)
    #expect(
        action.fingerprint
            != ActionFingerprint.make(
                host: .grok,
                session: request.session,
                cwd: request.cwd,
                command: ShellCommand(rawValue: "")
            )
    )
}

@Test func hookDispatch_fileDenyVoiceDoesNotUseEmptyShellCommand() async throws {
    let reason = "Access to a sensitive path is not allowed."
    let stdin = try grokFileEnvFixture()
    let wire = await hookWire(
        host: .grok,
        stdin: stdin,
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
                        packID: .coreSecrets,
                        patternName: "env",
                        severity: .high,
                        reason: reason
                    )
                )
            )
        }
    )
    #expect(wire.stdout.contains(hostFileDenyLine(reason: reason)))
    #expect(wire.stdout.contains("\"decision\":\"deny\""))
    #expect(wire.stdout.contains("Blocked  (") == false)
}

private func grokEmptyCommandFixture() throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/grok/deny-empty-command.json")
    return try String(contentsOf: url, encoding: .utf8)
}

private func grokFileEnvFixture() throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/grok/deny-file-env.json")
    return try String(contentsOf: url, encoding: .utf8)
}
