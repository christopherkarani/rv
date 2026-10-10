import Foundation
import Testing
import RVDomain

/// Host wire vocabulary: per-host closed-known + open-other tables with
/// explicit strict (hook-codec) and loose (scan-adapter) policies.
///
/// Each row pins today's matching behavior exactly (see the 9
/// `*HostCodec.decode` bodies and the 8 `*StoreAdapter.extract` paths);
/// T3b/T3c adopt these tables without redesigning them. Plain
/// `import RVDomain` (not `@testable`) proves the API is public, as the
/// RVHooks and RVScan consumers require.
@Suite("Host wire vocabulary")
struct HostWireVocabularyTests {
    @Test func firstNonEmptySkipsNilAndEmpty() {
        #expect(firstNonEmpty(nil, "", "a", "b") == "a")
        #expect(firstNonEmpty(nil, "", nil) == nil)
        #expect(firstNonEmpty() == nil)
        #expect(firstNonEmpty("solo") == "solo")
        #expect(firstNonEmpty("", "second") == "second")
    }

    @Test func firstNonEmptyCountsWhitespaceAsNonEmpty() {
        // Codec parity pin: the nine private copies test `isEmpty` only.
        // This deliberately differs from FileToolPath.firstPresent.
        #expect(firstNonEmpty("  ", "x") == "  ")
        #expect(FileToolPath.firstPresent("  ", "x")?.rawValue == "x")
    }

    @Test func firstNonEmptyArrayFormMatchesVariadic() {
        #expect(firstNonEmpty([nil, "", "a", "b"]) == "a")
        #expect(firstNonEmpty([nil, "", nil]) == nil)
        #expect(firstNonEmpty([String?]()) == nil)
        #expect(firstNonEmpty(["  ", "x"]) == "  ")
    }

    @Test func grokToolNames() {
        let rows: [(String, GrokToolName, HostToolMatch, HostToolMatch)] = [
            ("run_terminal_command", .runTerminalCommand, .shell, .shell),
            ("run_terminal_cmd", .runTerminalCmd, .shell, .shell),
            ("Bash", .bash, .shell, .shell),
        ]
        for (spelling, expected, strict, loose) in rows {
            let parsed = GrokToolName(wireValue: spelling)
            #expect(parsed == expected)
            #expect(parsed.wireValue == spelling)
            #expect(parsed.strictMatch == strict)
            #expect(parsed.looseMatch == loose)
            #expect(parsed.match(policy: .strict) == strict)
            #expect(parsed.match(policy: .loose) == loose)
            #expect(GrokToolName(wireValue: Optional(spelling)) == expected)
        }
        // Shared file aliases delegate to FileToolKind; the wire value
        // canonicalizes to the ledger name.
        let aliases: [(String, FileToolKind, String)] = [
            ("Read", .read, "Read"),
            ("read_file", .read, "Read"),
            ("Edit", .edit, "Edit"),
            ("edit_file", .edit, "Edit"),
            ("Write", .write, "Write"),
            ("write_file", .write, "Write"),
        ]
        for (spelling, kind, canonical) in aliases {
            let parsed = GrokToolName(wireValue: spelling)
            #expect(parsed == .file(kind))
            #expect(parsed.wireValue == canonical)
            #expect(parsed.strictMatch == .file(kind))
            // Loose skips file tools: shell extraction only.
            #expect(parsed.looseMatch == .foreign)
        }
        #expect(GrokToolName(wireValue: "Grep") == .other("Grep"))
    }

    @Test func grokToolNamesCarryUnknown() {
        let unknown = GrokToolName(wireValue: "RunTerminal")
        #expect(unknown == .other("RunTerminal"))
        #expect(unknown.wireValue == "RunTerminal")
        #expect(unknown.strictMatch == .foreign)
        #expect(unknown.looseMatch == .foreign)
        #expect(GrokToolName(wireValue: "") == .other(""))
        #expect(GrokToolName(wireValue: "").strictMatch == .foreign)
        #expect(GrokToolName(wireValue: nil) == nil)
    }

    @Test func grokToolNamesCodeAsWireStrings() throws {
        let encoded = try JSONEncoder().encode(GrokToolName.runTerminalCmd)
        #expect(String(data: encoded, encoding: .utf8) == "\"run_terminal_cmd\"")
        #expect(try JSONDecoder().decode(GrokToolName.self, from: encoded) == .runTerminalCmd)
        let exotic = Data("\"RunTerminal\"".utf8)
        #expect(try JSONDecoder().decode(GrokToolName.self, from: exotic) == .other("RunTerminal"))
    }

    @Test func piToolNames() {
        let parsed = PiToolName(wireValue: "bash")
        #expect(parsed == .bash)
        #expect(parsed.wireValue == "bash")
        #expect(parsed.strictMatch == .shell)
        #expect(parsed.looseMatch == .shell)
        #expect(parsed.match(policy: .strict) == .shell)
        #expect(parsed.match(policy: .loose) == .shell)
        #expect(PiToolName(wireValue: Optional("bash")) == .bash)
        let unknown = PiToolName(wireValue: "Bash")
        #expect(unknown == .other("Bash"))
        #expect(unknown.strictMatch == .foreign)
        #expect(unknown.looseMatch == .foreign)
        #expect(PiToolName(wireValue: nil) == nil)
    }

    @Test func piToolNamesCodeAsWireStrings() throws {
        let encoded = try JSONEncoder().encode(PiToolName.bash)
        #expect(String(data: encoded, encoding: .utf8) == "\"bash\"")
        #expect(try JSONDecoder().decode(PiToolName.self, from: encoded) == .bash)
    }

    @Test func openCodeToolNames() {
        // Reversed policy direction: strict admits the TUI door.
        let rows: [(String, OpenCodeToolName, HostToolMatch, HostToolMatch)] = [
            ("bash", .bash, .shell, .shell),
            ("session.shell", .sessionShell, .shell, .foreign),
        ]
        for (spelling, expected, strict, loose) in rows {
            let parsed = OpenCodeToolName(wireValue: spelling)
            #expect(parsed == expected)
            #expect(parsed.wireValue == spelling)
            #expect(parsed.strictMatch == strict)
            #expect(parsed.looseMatch == loose)
            #expect(parsed.match(policy: .strict) == strict)
            #expect(parsed.match(policy: .loose) == loose)
            #expect(OpenCodeToolName(wireValue: Optional(spelling)) == expected)
        }
        #expect(OpenCodeToolName(wireValue: "Bash") == .other("Bash"))
        #expect(OpenCodeToolName(wireValue: "Bash").strictMatch == .foreign)
        #expect(OpenCodeToolName(wireValue: nil) == nil)
    }

    @Test func openCodeToolNamesCodeAsWireStrings() throws {
        let encoded = try JSONEncoder().encode(OpenCodeToolName.sessionShell)
        #expect(String(data: encoded, encoding: .utf8) == "\"session.shell\"")
        #expect(try JSONDecoder().decode(OpenCodeToolName.self, from: encoded) == .sessionShell)
    }

    @Test func claudeToolNames() {
        let rows: [(String, ClaudeToolName, HostToolMatch, HostToolMatch)] = [
            ("Bash", .bash, .shell, .shell),
            ("bash", .bashLowercase, .foreign, .shell),
            ("Shell", .shell, .foreign, .shell),
            ("shell", .shellLowercase, .foreign, .shell),
        ]
        for (spelling, expected, strict, loose) in rows {
            let parsed = ClaudeToolName(wireValue: spelling)
            #expect(parsed == expected)
            #expect(parsed.wireValue == spelling)
            #expect(parsed.strictMatch == strict)
            #expect(parsed.looseMatch == loose)
            #expect(parsed.match(policy: .strict) == strict)
            #expect(parsed.match(policy: .loose) == loose)
            #expect(ClaudeToolName(wireValue: Optional(spelling)) == expected)
        }
        let aliases: [(String, FileToolKind, String)] = [
            ("Read", .read, "Read"),
            ("read_file", .read, "Read"),
            ("Edit", .edit, "Edit"),
            ("edit_file", .edit, "Edit"),
            ("Write", .write, "Write"),
            ("write_file", .write, "Write"),
        ]
        for (spelling, kind, canonical) in aliases {
            let parsed = ClaudeToolName(wireValue: spelling)
            #expect(parsed == .file(kind))
            #expect(parsed.wireValue == canonical)
            #expect(parsed.strictMatch == .file(kind))
            // Loose skips file tools: shell extraction only.
            #expect(parsed.looseMatch == .foreign)
        }
        #expect(ClaudeToolName(wireValue: "Grep") == .other("Grep"))
        #expect(ClaudeToolName(wireValue: "Grep").looseMatch == .foreign)
        #expect(ClaudeToolName(wireValue: nil) == nil)
    }

    @Test func claudeToolNamesCodeAsWireStrings() throws {
        let encoded = try JSONEncoder().encode(ClaudeToolName.bash)
        #expect(String(data: encoded, encoding: .utf8) == "\"Bash\"")
        #expect(try JSONDecoder().decode(ClaudeToolName.self, from: encoded) == .bash)
        let file = try JSONEncoder().encode(ClaudeToolName.file(.edit))
        #expect(String(data: file, encoding: .utf8) == "\"Edit\"")
    }

    @Test func openClawToolNames() {
        let parsed = OpenClawToolName(wireValue: "exec")
        #expect(parsed == .exec)
        #expect(parsed.wireValue == "exec")
        #expect(parsed.strictMatch == .shell)
        #expect(parsed.looseMatch == .shell)
        #expect(parsed.match(policy: .strict) == .shell)
        #expect(parsed.match(policy: .loose) == .shell)
        #expect(OpenClawToolName(wireValue: Optional("exec")) == .exec)
        #expect(OpenClawToolName(wireValue: "execute") == .other("execute"))
        #expect(OpenClawToolName(wireValue: "execute").looseMatch == .foreign)
        #expect(OpenClawToolName(wireValue: nil) == nil)
    }

    @Test func openClawToolNamesCodeAsWireStrings() throws {
        let encoded = try JSONEncoder().encode(OpenClawToolName.exec)
        #expect(String(data: encoded, encoding: .utf8) == "\"exec\"")
        #expect(try JSONDecoder().decode(OpenClawToolName.self, from: encoded) == .exec)
    }

    @Test func openClawToolKinds() throws {
        let excluded = OpenClawToolKind(wireValue: "code_mode_exec")
        #expect(excluded == .codeModeExec)
        #expect(excluded.wireValue == "code_mode_exec")
        #expect(excluded.isExcludedCodeMode)
        let plain = OpenClawToolKind(wireValue: "exec")
        #expect(plain == .other("exec"))
        #expect(plain.isExcludedCodeMode == false)
        #expect(OpenClawToolKind(wireValue: nil) == nil)
        let encoded = try JSONEncoder().encode(OpenClawToolKind.codeModeExec)
        #expect(String(data: encoded, encoding: .utf8) == "\"code_mode_exec\"")
        #expect(try JSONDecoder().decode(OpenClawToolKind.self, from: encoded) == .codeModeExec)
    }

    @Test func hermesToolNames() {
        let parsed = HermesToolName(wireValue: "terminal")
        #expect(parsed == .terminal)
        #expect(parsed.wireValue == "terminal")
        #expect(parsed.strictMatch == .shell)
        #expect(parsed.looseMatch == .shell)
        #expect(parsed.match(policy: .strict) == .shell)
        #expect(parsed.match(policy: .loose) == .shell)
        #expect(HermesToolName(wireValue: Optional("terminal")) == .terminal)
        #expect(HermesToolName(wireValue: "shell") == .other("shell"))
        #expect(HermesToolName(wireValue: "shell").strictMatch == .foreign)
        #expect(HermesToolName(wireValue: nil) == nil)
    }

    @Test func hermesToolNamesCodeAsWireStrings() throws {
        let encoded = try JSONEncoder().encode(HermesToolName.terminal)
        #expect(String(data: encoded, encoding: .utf8) == "\"terminal\"")
        #expect(try JSONDecoder().decode(HermesToolName.self, from: encoded) == .terminal)
    }

    @Test func codexToolNames() {
        let rows: [(String, CodexToolName, HostToolMatch, HostToolMatch)] = [
            ("Bash", .bash, .shell, .shell),
            ("bash", .bashLowercase, .foreign, .shell),
            ("shell", .shell, .foreign, .shell),
            ("local_shell", .localShell, .foreign, .shell),
        ]
        for (spelling, expected, strict, loose) in rows {
            let parsed = CodexToolName(wireValue: spelling)
            #expect(parsed == expected)
            #expect(parsed.wireValue == spelling)
            #expect(parsed.strictMatch == strict)
            #expect(parsed.looseMatch == loose)
            #expect(parsed.match(policy: .strict) == strict)
            #expect(parsed.match(policy: .loose) == loose)
            #expect(CodexToolName(wireValue: Optional(spelling)) == expected)
        }
        #expect(CodexToolName(wireValue: "localShell") == .other("localShell"))
        #expect(CodexToolName(wireValue: "localShell").looseMatch == .foreign)
        #expect(CodexToolName(wireValue: nil) == nil)
    }

    @Test func codexToolNamesCodeAsWireStrings() throws {
        let encoded = try JSONEncoder().encode(CodexToolName.localShell)
        #expect(String(data: encoded, encoding: .utf8) == "\"local_shell\"")
        #expect(try JSONDecoder().decode(CodexToolName.self, from: encoded) == .localShell)
    }

    @Test func cursorToolNames() {
        let rows: [(String, CursorToolName, HostToolMatch, HostToolMatch)] = [
            ("Shell", .shell, .shell, .shell),
            ("Bash", .bash, .shell, .shell),
            ("shell", .shellLowercase, .foreign, .shell),
            ("bash", .bashLowercase, .foreign, .shell),
        ]
        for (spelling, expected, strict, loose) in rows {
            let parsed = CursorToolName(wireValue: spelling)
            #expect(parsed == expected)
            #expect(parsed.wireValue == spelling)
            #expect(parsed.strictMatch == strict)
            #expect(parsed.looseMatch == loose)
            #expect(parsed.match(policy: .strict) == strict)
            #expect(parsed.match(policy: .loose) == loose)
            #expect(CursorToolName(wireValue: Optional(spelling)) == expected)
        }
        let aliases: [(String, FileToolKind, String)] = [
            ("Read", .read, "Read"),
            ("read_file", .read, "Read"),
            ("Edit", .edit, "Edit"),
            ("edit_file", .edit, "Edit"),
            ("Write", .write, "Write"),
            ("write_file", .write, "Write"),
        ]
        for (spelling, kind, canonical) in aliases {
            let parsed = CursorToolName(wireValue: spelling)
            #expect(parsed == .file(kind))
            #expect(parsed.wireValue == canonical)
            #expect(parsed.strictMatch == .file(kind))
            // Loose skips file tools: shell extraction only.
            #expect(parsed.looseMatch == .foreign)
        }
        #expect(CursorToolName(wireValue: "Terminal") == .other("Terminal"))
        #expect(CursorToolName(wireValue: "Terminal").strictMatch == .foreign)
        #expect(CursorToolName(wireValue: nil) == nil)
    }

    @Test func cursorToolNamesCodeAsWireStrings() throws {
        let encoded = try JSONEncoder().encode(CursorToolName.shell)
        #expect(String(data: encoded, encoding: .utf8) == "\"Shell\"")
        #expect(try JSONDecoder().decode(CursorToolName.self, from: encoded) == .shell)
    }

    @Test func antigravityToolNames() {
        #expect(AntigravityToolName(wireValue: "run_command") == .runCommand)
        #expect(AntigravityToolName(wireValue: "run_command").wireValue == "run_command")
        #expect(AntigravityToolName(wireValue: "run_command").strictMatch == .shell)
        #expect(AntigravityToolName(wireValue: "run_command").looseMatch == .shell)
        #expect(AntigravityToolName(wireValue: "run_command").match(policy: .strict) == .shell)
        #expect(AntigravityToolName(wireValue: "run_command").match(policy: .loose) == .shell)
        let files: [(String, FileToolKind)] = [
            ("view_file", .read),
            ("replace_file_content", .edit),
            ("multi_replace_file_content", .edit),
            ("write_to_file", .write),
        ]
        for (spelling, kind) in files {
            let parsed = AntigravityToolName(wireValue: spelling)
            #expect(parsed.wireValue == spelling)
            #expect(parsed.fileKind == kind)
            #expect(parsed.strictMatch == .file(kind))
            #expect(parsed.looseMatch == .file(kind))
            #expect(parsed.match(policy: .strict) == .file(kind))
            #expect(parsed.match(policy: .loose) == .file(kind))
            #expect(AntigravityToolName(wireValue: Optional(spelling)) == parsed)
        }
        #expect(AntigravityToolName.runCommand.fileKind == nil)
        #expect(AntigravityToolName(wireValue: "runCommand") == .other("runCommand"))
        #expect(AntigravityToolName(wireValue: "runCommand").strictMatch == .foreign)
        #expect(AntigravityToolName(wireValue: "Read") == .other("Read"))
        #expect(AntigravityToolName(wireValue: nil) == nil)
    }

    @Test func antigravityToolNamesCodeAsWireStrings() throws {
        let encoded = try JSONEncoder().encode(AntigravityToolName.multiReplaceFileContent)
        #expect(String(data: encoded, encoding: .utf8) == "\"multi_replace_file_content\"")
        #expect(
            try JSONDecoder().decode(AntigravityToolName.self, from: encoded)
                == .multiReplaceFileContent
        )
    }

    @Test func grokEventNames() throws {
        let parsed = GrokEventName(wireValue: "pre_tool_use")
        #expect(parsed == .preToolUse)
        #expect(parsed.wireValue == "pre_tool_use")
        #expect(parsed.strictMatch)
        #expect(parsed.looseMatch)
        #expect(parsed.match(policy: .strict))
        #expect(parsed.match(policy: .loose))
        #expect(GrokEventName(wireValue: Optional("pre_tool_use")) == .preToolUse)
        #expect(GrokEventName(wireValue: "PreToolUse") == .other("PreToolUse"))
        #expect(GrokEventName(wireValue: "PreToolUse").strictMatch == false)
        #expect(GrokEventName(wireValue: nil) == nil)
        let encoded = try JSONEncoder().encode(GrokEventName.preToolUse)
        #expect(String(data: encoded, encoding: .utf8) == "\"pre_tool_use\"")
        #expect(try JSONDecoder().decode(GrokEventName.self, from: encoded) == .preToolUse)
    }

    @Test func claudeEventNames() throws {
        let parsed = ClaudeEventName(wireValue: "PreToolUse")
        #expect(parsed == .preToolUse)
        #expect(parsed.wireValue == "PreToolUse")
        #expect(parsed.strictMatch)
        #expect(parsed.looseMatch)
        #expect(parsed.match(policy: .strict))
        #expect(parsed.match(policy: .loose))
        #expect(ClaudeEventName(wireValue: "pre_tool_use") == .other("pre_tool_use"))
        #expect(ClaudeEventName(wireValue: nil) == nil)
        let encoded = try JSONEncoder().encode(ClaudeEventName.preToolUse)
        #expect(try JSONDecoder().decode(ClaudeEventName.self, from: encoded) == .preToolUse)
    }

    @Test func codexEventNames() throws {
        let parsed = CodexEventName(wireValue: "PreToolUse")
        #expect(parsed == .preToolUse)
        #expect(parsed.wireValue == "PreToolUse")
        #expect(parsed.strictMatch)
        #expect(parsed.looseMatch)
        #expect(parsed.match(policy: .strict))
        #expect(parsed.match(policy: .loose))
        #expect(CodexEventName(wireValue: "preToolUse") == .other("preToolUse"))
        #expect(CodexEventName(wireValue: nil) == nil)
        let encoded = try JSONEncoder().encode(CodexEventName.preToolUse)
        #expect(try JSONDecoder().decode(CodexEventName.self, from: encoded) == .preToolUse)
    }

    @Test func cursorEventNames() throws {
        let rows: [(String, CursorEventName, Bool, Bool)] = [
            ("beforeShellExecution", .beforeShellExecution, true, true),
            ("preToolUse", .preToolUse, true, true),
            ("PreToolUse", .preToolUseCapitalized, false, true),
        ]
        for (spelling, expected, strict, loose) in rows {
            let parsed = CursorEventName(wireValue: spelling)
            #expect(parsed == expected)
            #expect(parsed.wireValue == spelling)
            #expect(parsed.strictMatch == strict)
            #expect(parsed.looseMatch == loose)
            #expect(parsed.match(policy: .strict) == strict)
            #expect(parsed.match(policy: .loose) == loose)
            #expect(CursorEventName(wireValue: Optional(spelling)) == expected)
        }
        #expect(CursorEventName(wireValue: "afterShellExecution") == .other("afterShellExecution"))
        #expect(CursorEventName(wireValue: "afterShellExecution").looseMatch == false)
        #expect(CursorEventName(wireValue: nil) == nil)
        let encoded = try JSONEncoder().encode(CursorEventName.beforeShellExecution)
        #expect(String(data: encoded, encoding: .utf8) == "\"beforeShellExecution\"")
        #expect(
            try JSONDecoder().decode(CursorEventName.self, from: encoded) == .beforeShellExecution
        )
    }

    @Test func sharedKeyProbeListsKeepOrder() {
        #expect(
            HostWireKeys.nestedContainerKeys == [
                "params", "args", "toolInput", "tool_input", "input",
                "arguments", "state", "payload", "function",
            ]
        )
        #expect(
            HostWireKeys.workingDirectoryKeys == [
                "cwd", "workdir", "workingDirectory", "working_directory",
            ]
        )
    }

    @Test func perHostKeyProbeListsKeepOrder() {
        #expect(CodexWireKeys.sessionKeys == ["session_id", "sessionId"])
        #expect(CodexWireKeys.recurseSessionKeys == ["payload"])
        #expect(CodexWireKeys.timestampKeys == ["timestamp", "ts"])
        #expect(CursorWireKeys.sessionKeys == ["conversation_id", "session_id", "sessionId"])
        #expect(CursorWireKeys.timestampKeys == ["timestamp", "ts"])
        #expect(ClaudeWireKeys.sessionKeys == ["sessionId"])
    }
}
