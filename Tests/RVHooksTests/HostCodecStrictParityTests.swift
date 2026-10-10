import Foundation
import Testing
import RVDomain
@testable import RVHooks

// Strict-policy parity: each codec must match today's exact wire spellings
// through the T3a vocabulary. Loose-only spellings stay foreign here.

private func shellCommand(of outcome: HookDecodeOutcome) -> String? {
    guard case .request(let request) = outcome,
          case .shell(_, let command, _, _) = request
    else { return nil }
    return command.rawValue
}

private func fileKind(of outcome: HookDecodeOutcome) -> FileToolKind? {
    guard case .request(let request) = outcome,
          case .file(_, let action, _, _) = request
    else { return nil }
    return action.kind
}

private func sessionOf(_ outcome: HookDecodeOutcome) -> String? {
    guard case .request(let request) = outcome else { return nil }
    return request.session?.rawValue
}

@Test func strictParity_piAdmitsOnlyBash() {
    let codec = PiHostCodec()
    #expect(shellCommand(of: codec.decode(#"{"toolName":"bash","input":{"command":"git status"}}"#)) == "git status")
    for tool in ["Bash", "shell", "Shell", "exec", "", "run_command"] {
        #expect(codec.decode(#"{"toolName":"\#(tool)","input":{"command":"git status"}}"#) == .foreign)
    }
    #expect(codec.decode(#"{"input":{"command":"git status"}}"#) == .foreign)
}

@Test func strictParity_openCodeAdmitsBashAndSessionShell() {
    let codec = OpenCodeHostCodec()
    #expect(shellCommand(of: codec.decode(#"{"tool":"bash","args":{"command":"git status"}}"#)) == "git status")
    #expect(shellCommand(of: codec.decode(#"{"tool":"session.shell","args":{"command":"git status"}}"#)) == "git status")
    for tool in ["Bash", "shell", "exec", "session.bash", ""] {
        #expect(codec.decode(#"{"tool":"\#(tool)","args":{"command":"git status"}}"#) == .foreign)
    }
    #expect(codec.decode(#"{"args":{"command":"git status"}}"#) == .foreign)
}

@Test func strictParity_openCodeSessionFallsBackThroughSharedHelper() {
    let codec = OpenCodeHostCodec()
    let outcome = codec.decode(#"{"tool":"bash","args":{"command":"git status"},"sessionID":"","sessionId":"sess_1"}"#)
    #expect(shellCommand(of: outcome) == "git status")
    #expect(sessionOf(outcome) == "sess_1")
}

@Test func strictParity_claudeEventGateAndBash() {
    let codec = ClaudeHostCodec()
    let shell = shellCommand(of: codec.decode(
        #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"}}"#))
    #expect(shell == "git status")
    for event in ["pre_tool_use", "preToolUse", "PostToolUse", ""] {
        #expect(codec.decode(
            #"{"hook_event_name":"\#(event)","tool_name":"Bash","tool_input":{"command":"git status"}}"#) == .foreign)
    }
    #expect(codec.decode(#"{"tool_name":"Bash","tool_input":{"command":"git status"}}"#) == .foreign)
    // Loose-only spellings stay foreign under the strict policy.
    for tool in ["bash", "Shell", "shell", "local_shell", "Grep"] {
        #expect(codec.decode(
            #"{"hook_event_name":"PreToolUse","tool_name":"\#(tool)","tool_input":{"command":"git status"}}"#) == .foreign)
    }
}

@Test func strictParity_claudeFileToolsStillDecode() {
    let codec = ClaudeHostCodec()
    #expect(fileKind(of: codec.decode(
        #"{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/a.txt"}}"#)) == .read)
    #expect(fileKind(of: codec.decode(
        #"{"hook_event_name":"PreToolUse","tool_name":"edit_file","tool_input":{"path":"/tmp/a.txt"}}"#)) == .edit)
    #expect(fileKind(of: codec.decode(
        #"{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"target":"/tmp/a.txt"}}"#)) == .write)
}

@Test func strictParity_openClawExecWithCodeModeExclusion() {
    let codec = OpenClawHostCodec()
    #expect(shellCommand(of: codec.decode(#"{"toolName":"exec","params":{"command":"git status"}}"#)) == "git status")
    #expect(shellCommand(of: codec.decode(
        #"{"toolName":"exec","toolKind":"shell","params":{"command":"git status"}}"#)) == "git status")
    #expect(codec.decode(
        #"{"toolName":"exec","toolKind":"code_mode_exec","params":{"command":"git status"}}"#) == .foreign)
    for tool in ["bash", "Bash", "run_command", ""] {
        #expect(codec.decode(#"{"toolName":"\#(tool)","params":{"command":"git status"}}"#) == .foreign)
    }
}

@Test func strictParity_hermesAdmitsOnlyTerminal() {
    let codec = HermesHostCodec()
    #expect(shellCommand(of: codec.decode(#"{"toolName":"terminal","args":{"command":"git status"}}"#)) == "git status")
    for tool in ["bash", "exec", "shell", "Terminal", ""] {
        #expect(codec.decode(#"{"toolName":"\#(tool)","args":{"command":"git status"}}"#) == .foreign)
    }
}

@Test func strictParity_grokEventGateAndShellSet() {
    let codec = GrokHostCodec()
    for tool in ["run_terminal_command", "run_terminal_cmd", "Bash"] {
        #expect(shellCommand(of: codec.decode(
            #"{"hookEventName":"pre_tool_use","toolName":"\#(tool)","toolInput":{"command":"git status"}}"#)) == "git status")
    }
    for event in ["PreToolUse", "preToolUse", "post_tool_use", ""] {
        #expect(codec.decode(
            #"{"hookEventName":"\#(event)","toolName":"Bash","toolInput":{"command":"git status"}}"#) == .foreign)
    }
    #expect(codec.decode(#"{"toolName":"Bash","toolInput":{"command":"git status"}}"#) == .foreign)
    for tool in ["bash", "shell", "run_command", "Grep"] {
        #expect(codec.decode(
            #"{"hookEventName":"pre_tool_use","toolName":"\#(tool)","toolInput":{"command":"git status"}}"#) == .foreign)
    }
}

@Test func strictParity_grokFileToolsStillDecode() {
    let codec = GrokHostCodec()
    #expect(fileKind(of: codec.decode(
        #"{"hookEventName":"pre_tool_use","toolName":"Read","toolInput":{"file_path":"/tmp/a.txt"}}"#)) == .read)
    #expect(fileKind(of: codec.decode(
        #"{"hookEventName":"pre_tool_use","toolName":"edit_file","toolInput":{"path":"/tmp/a.txt"}}"#)) == .edit)
}

@Test func strictParity_codexEventGateAndBash() {
    let codec = CodexHostCodec()
    #expect(shellCommand(of: codec.decode(
        #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"}}"#)) == "git status")
    #expect(codec.decode(
        #"{"hook_event_name":"pre_tool_use","tool_name":"Bash","tool_input":{"command":"git status"}}"#) == .foreign)
    #expect(codec.decode(#"{"tool_name":"Bash","tool_input":{"command":"git status"}}"#) == .foreign)
    // Loose-only rollout spellings stay foreign under the strict policy.
    for tool in ["bash", "shell", "local_shell", "Shell"] {
        #expect(codec.decode(
            #"{"hook_event_name":"PreToolUse","tool_name":"\#(tool)","tool_input":{"command":"git status"}}"#) == .foreign)
    }
}

@Test func strictParity_cursorEventDispatch() {
    let codec = CursorHostCodec()
    // beforeShellExecution and the missing/empty event are the shell door.
    #expect(shellCommand(of: codec.decode(
        #"{"hook_event_name":"beforeShellExecution","command":"git status"}"#)) == "git status")
    #expect(shellCommand(of: codec.decode(#"{"command":"git status"}"#)) == "git status")
    #expect(shellCommand(of: codec.decode(#"{"hook_event_name":"","command":"git status"}"#)) == "git status")
    // preToolUse dispatches on the tool name.
    for tool in ["Shell", "Bash"] {
        #expect(shellCommand(of: codec.decode(
            #"{"hook_event_name":"preToolUse","tool_name":"\#(tool)","tool_input":{"command":"git status"}}"#)) == "git status")
    }
    // Loose-only spellings and the capitalized event stay foreign under strict.
    for tool in ["shell", "bash", "Grep"] {
        #expect(codec.decode(
            #"{"hook_event_name":"preToolUse","tool_name":"\#(tool)","tool_input":{"command":"git status"}}"#) == .foreign)
    }
    #expect(codec.decode(
        #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"}}"#) == .foreign)
    #expect(codec.decode(
        #"{"hook_event_name":"afterShellExecution","command":"git status"}"#) == .foreign)
}

@Test func strictParity_cursorFileToolsStillDecode() {
    let codec = CursorHostCodec()
    #expect(fileKind(of: codec.decode(
        #"{"hook_event_name":"preToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/a.txt"}}"#)) == .read)
    #expect(fileKind(of: codec.decode(
        #"{"hook_event_name":"preToolUse","tool_name":"write_file","tool_input":{"path":"/tmp/a.txt"}}"#)) == .write)
}

@Test func strictParity_antigravityShellAndNativeFileNames() {
    let codec = AntigravityHostCodec()
    #expect(shellCommand(of: codec.decode(
        #"{"conversationId":"s","toolCall":{"name":"run_command","args":{"CommandLine":"git status"}},"workspacePaths":["/tmp/ws"]}"#)) == "git status")
    for (tool, kind) in [
        ("view_file", FileToolKind.read),
        ("replace_file_content", FileToolKind.edit),
        ("multi_replace_file_content", FileToolKind.edit),
        ("write_to_file", FileToolKind.write),
    ] as [(String, FileToolKind)] {
        #expect(fileKind(of: codec.decode(
            #"{"conversationId":"s","toolCall":{"name":"\#(tool)","args":{"TargetFile":"/tmp/ws/f.txt"}},"workspacePaths":["/tmp/ws"]}"#)) == kind)
    }
    for tool in ["Read", "bash", "exec", "delete_file", ""] {
        #expect(codec.decode(
            #"{"conversationId":"s","toolCall":{"name":"\#(tool)","args":{"CommandLine":"git status"}},"workspacePaths":["/tmp/ws"]}"#) == .foreign)
    }
    #expect(codec.decode(#"{"conversationId":"s","workspacePaths":["/tmp/ws"]}"#) == .foreign)
}
