import Foundation
import Synchronization
import Testing
import RVDomain
@testable import RVHooks

@Test func claudeDecode_readToolIsFileWithoutEmptyCommand() {
    let stdin = """
    {"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/rv-hook-fixture/README.md"}}
    """
    let outcome = ClaudeHostCodec().decode(stdin)
    #expect(
        outcome == .request(
            .file(
                host: .claude,
                file: FileToolAction(
                    kind: .read,
                    path: FileToolPath(rawValue: "/tmp/rv-hook-fixture/README.md")
                ),
                cwd: nil,
                session: nil
            )
        )
    )
    guard case .request(let request) = outcome else {
        Issue.record("expected .request for Claude Read")
        return
    }
    switch request {
    case .file(_, let file, _, _):
        #expect(file.kind == .read)
        #expect(file.path.rawValue == "/tmp/rv-hook-fixture/README.md")
    case .shell, .spend:
        Issue.record("expected .file, not a shell or spend request")
    }
}

@Test func piDecode_hostAskSpendIsSpendCase() {
    let stdin = """
    {"toolName":"bash","cwd":"/tmp/ws","input":{"command":"git reset --hard"},"hostAsk":"spend"}
    """
    let outcome = PiHostCodec().decode(stdin)
    #expect(
        outcome == .request(
            .spend(
                host: .pi,
                command: ShellCommand(rawValue: "git reset --hard"),
                cwd: wd("/tmp/ws"),
                session: nil
            )
        )
    )
    guard case .request(let request) = outcome else {
        Issue.record("expected .request for Pi spend")
        return
    }
    switch request {
    case .spend(_, let command, let cwd, _):
        #expect(command.rawValue == "git reset --hard")
        #expect(cwd == wd("/tmp/ws"))
    case .shell, .file:
        Issue.record("expected .spend, not a shell or file request")
    }
}

@Test func claudeDecode_fileWinsOverSpendFlag() {
    let stdin = """
    {"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/rv-oracle/.env"},"hostAsk":"spend"}
    """
    let outcome = ClaudeHostCodec().decode(stdin)
    #expect(
        outcome == .request(
            .file(
                host: .claude,
                file: FileToolAction(
                    kind: .read,
                    path: FileToolPath(rawValue: "/tmp/rv-oracle/.env")
                ),
                cwd: nil,
                session: nil
            )
        )
    )
}

@Test func piDecode_spendWithoutCommandIsMissingCommand() {
    #expect(
        PiHostCodec().decode(#"{"toolName":"bash","hostAsk":"spend","input":{}}"#)
            == .malformed(.missingCommand)
    )
}

@Test func grokDecode_bashEqualityUsesShellCase() {
    let stdin = """
    {"hookEventName":"pre_tool_use","toolName":"Bash","toolInput":{"command":"git status"}}
    """
    #expect(
        GrokHostCodec().decode(stdin)
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

@Test func proposedAction_shellAndSpendKeepFingerprint() {
    let command = ShellCommand(rawValue: "git reset --hard")
    let cwd = wd("/tmp/ws")
    let session = SessionID(validating: "sess_1")
    let shell = HookRequest.shell(
        host: .pi,
        command: command,
        cwd: cwd,
        session: session
    )
    let spend = HookRequest.spend(
        host: .pi,
        command: command,
        cwd: cwd,
        session: session
    )
    let codec = PiHostCodec()
    let expected = ActionFingerprint.make(
        host: .pi,
        session: session,
        cwd: cwd,
        command: command
    )
    #expect(codec.proposedAction(from: shell).fingerprint == expected)
    #expect(codec.proposedAction(from: spend).fingerprint == expected)
    #expect(codec.proposedAction(from: shell).supportingCommand == command)
    #expect(codec.proposedAction(from: spend).supportingCommand == command)
}

@Test func proposedAction_fileIsNotEmptyCommandShell() {
    let request = HookRequest.file(
        host: .claude,
        file: FileToolAction(
            kind: .read,
            path: FileToolPath(rawValue: "/tmp/rv-oracle/.env")
        ),
        cwd: wd("/tmp/ws"),
        session: SessionID(validating: "abc-123")
    )
    let file = FileToolAction(
        kind: .read,
        path: FileToolPath(rawValue: "/tmp/rv-oracle/.env")
    )
    let action = ClaudeHostCodec().proposedAction(from: request)
    #expect(action.supportingCommand == nil)
    #expect(
        action.fingerprint
            == ActionFingerprint.make(
                host: .claude,
                session: request.session,
                cwd: request.cwd,
                file: file
            )
    )
    #expect(
        action.fingerprint
            != ActionFingerprint.make(
                host: .claude,
                session: request.session,
                cwd: request.cwd,
                command: ShellCommand(rawValue: file.path.rawValue)
            )
    )
    guard case .file(let fileAction) = action else {
        Issue.record("expected ProposedAction.file")
        return
    }
    #expect(fileAction.resources.path == file.path.rawValue)
    #expect(fileAction.effects.kinds.isEmpty)
}

@Test func hookDispatch_fileWinsOverSpendCallback() async {
    let probe = DoorProbe()
    let stdin = """
    {"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/rv-oracle/.env"},"hostAsk":"spend"}
    """
    let wire = await hookWire(
        host: .claude,
        stdin: stdin,
        world: hookWorld(
            evaluate: { command, cwd in probe.evaluate(command, cwd) },
            evaluateFile: { action, cwd in probe.evaluateFile(action, cwd) },
            spend: { command, cwd in probe.spend(command, cwd) }
        )
    )
    #expect(probe.commands.isEmpty)
    #expect(probe.spends.isEmpty)
    #expect(probe.files == ["/tmp/rv-oracle/.env"])
    #expect(wire.stdout.contains("permissionDecision\":\"deny\""))
}

private final class DoorProbe: Sendable {
    private let state = Mutex<State>(State())

    private struct State: Sendable {
        var commands: [String] = []
        var files: [String] = []
        var spends: [String] = []
    }

    var commands: [String] { state.withLock { $0.commands } }
    var files: [String] { state.withLock { $0.files } }
    var spends: [String] { state.withLock { $0.spends } }

    func evaluate(_ command: ShellCommand, _: WorkingDirectory?) -> EvaluationResult {
        state.withLock { $0.commands.append(command.rawValue) }
        return EvaluationResult(outcome: .plain)
    }

    func spend(_ command: ShellCommand, _: WorkingDirectory?) -> EvaluationResult {
        state.withLock { $0.spends.append(command.rawValue) }
        return EvaluationResult(outcome: .plain)
    }

    func evaluateFile(_ action: FileToolAction, _: WorkingDirectory?) -> EvaluationResult {
        state.withLock { $0.files.append(action.path.rawValue) }
        if let rule = SecretPathCatalog.dayOne.firstMatch(of: action.path.rawValue) {
            let ruleID = RuleID(pack: .coreSecrets, pattern: rule.pattern)
            return EvaluationResult(
                outcome: .deny(
                    Deny(ruleID: ruleID, reason: rule.reason),
                    matched: RuleMatch(
                        ruleID: ruleID,
                        severity: .high,
                        reason: rule.reason
                    )
                )
            )
        }
        return EvaluationResult(outcome: .plain)
    }
}
