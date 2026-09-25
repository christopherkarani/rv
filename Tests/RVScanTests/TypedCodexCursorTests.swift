import Foundation
import Testing
import RVDomain
@testable import RVScan

private func extractCodex(_ payload: String, fileName: String = "inline-codex.jsonl") throws -> [ExtractedEvent] {
    let url = URL(fileURLWithPath: "/tmp/\(fileName)")
    return try CodexStoreAdapter().extract(fileURL: url, data: Data(payload.utf8))
}

private func extractCursor(_ payload: String, fileName: String = "inline-cursor.jsonl") throws -> [ExtractedEvent] {
    let url = URL(fileURLWithPath: "/tmp/\(fileName)")
    return try CursorStoreAdapter().extract(fileURL: url, data: Data(payload.utf8))
}

// MARK: - Codex goldens

@Test func codexTyped_fixtureGoldens() throws {
    let functionCall = try fixtureURL("codex/bash-function-call.jsonl")
    let functionEvents = try CodexStoreAdapter().extract(
        fileURL: functionCall, data: Data(contentsOf: functionCall)
    )
    #expect(functionEvents.map(\.command.rawValue) == ["git reset --hard"])
    #expect(functionEvents.allSatisfy { $0.host == .codex })
    #expect(functionEvents.allSatisfy { $0.sessionID == SessionID(validating: "sess_fixture_1") })
    #expect(functionEvents.allSatisfy { $0.sourcePath == functionCall.path })
    #expect(functionEvents.allSatisfy { $0.occurredAt == nil })
    // workdir inside the JSON-encoded arguments string.
    #expect(functionEvents.map { $0.workingDirectory?.rawValue } == ["/tmp/ws"])

    let pretool = try fixtureURL("codex/pretool-bash.jsonl")
    let pretoolEvents = try CodexStoreAdapter().extract(
        fileURL: pretool, data: Data(contentsOf: pretool)
    )
    #expect(pretoolEvents.map(\.command.rawValue) == ["git status"])
    #expect(pretoolEvents.allSatisfy { $0.sessionID == SessionID(validating: "sess_hook") })
    #expect(pretoolEvents.map { $0.workingDirectory?.rawValue } == ["/tmp/ws"])
}

@Test func codexTyped_failurePolicy() throws {
    let adapter = CodexStoreAdapter()
    let source = URL(fileURLWithPath: "/tmp/codex-typed-unreadable.jsonl")
    #expect(throws: CodexStoreError.unreadable(sourcePath: source.path)) {
        _ = try adapter.extract(fileURL: source, data: Data())
    }
    #expect(throws: CodexStoreError.unreadable(sourcePath: source.path)) {
        _ = try adapter.extract(fileURL: source, data: Data([0xFF, 0xFE]))
    }
    #expect(throws: CodexStoreError.unreadable(sourcePath: source.path)) {
        _ = try adapter.extract(fileURL: source, data: Data("not-json\n".utf8))
    }
    #expect(throws: CodexStoreError.unreadable(sourcePath: source.path)) {
        _ = try adapter.extract(fileURL: source, data: Data("   \n".utf8))
    }
    // Any JSON object counts as usable, even with zero events or wrong-typed fields.
    #expect(try adapter.extract(fileURL: source, data: Data("{}\n".utf8)).isEmpty)
    #expect(try adapter.extract(fileURL: source, data: Data("{\"session_id\":42}\n".utf8)).isEmpty)
    // Non-object JSON lines never count as usable.
    #expect(throws: CodexStoreError.unreadable(sourcePath: source.path)) {
        _ = try adapter.extract(fileURL: source, data: Data("[1,2]\n\"hi\"\n42\n".utf8))
    }
}

@Test func codexTyped_skipsBadLinesWithoutAborting() throws {
    let payload = """
    not-json
    {"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git reset --hard"}}
    [1,2]
    {"session_id":"s","type":"function_call","name":"shell","arguments":"{\\"command\\":\\"git status\\"}"}
    """
    let events = try extractCodex(payload)
    #expect(events.map(\.command.rawValue) == ["git reset --hard", "git status"])
}

@Test func codexTyped_wrongTypeScalarsKeepLine() throws {
    // Old per-field `as?` ignored a mistyped scalar and still extracted the
    // line; the whole line must not be dropped.
    let payload = """
    {"session_id":42,"timestamp":[42],"cwd":42,"tool_name":"Bash","tool_input":{"command":"git status"}}
    """
    let events = try extractCodex(payload, fileName: "rollout-fallback.jsonl")
    #expect(events.count == 1)
    #expect(events[0].command.rawValue == "git status")
    #expect(events[0].occurredAt == nil)
    #expect(events[0].sessionID == SessionID(validating: "rollout-fallback"))
    #expect(events[0].workingDirectory == nil)
}

@Test func codexTyped_wrongTypeNestedCwdFallsBackToEnvelope() throws {
    // A mistyped nested cwd is ignored; the line still extracts with the
    // envelope cwd (old `fromEnvelope` nested-miss behavior).
    let payload = """
    {"tool_name":"Bash","tool_input":{"command":"git status","workdir":42},"cwd":"/tmp/envelope"}
    """
    let events = try extractCodex(payload)
    #expect(events.count == 1)
    #expect(events[0].workingDirectory == WorkingDirectory(validating: "/tmp/envelope"))
}

@Test func codexTyped_hookRouting() throws {
    #expect(
        try extractCodex(
            #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"one"}}"#
        ).map(\.command.rawValue) == ["one"]
    )
    // Missing event behaves like PreToolUse.
    #expect(
        try extractCodex(
            #"{"tool_name":"local_shell","tool_input":{"command":"two"}}"#
        ).map(\.command.rawValue) == ["two"]
    )
    // Any other event (including lowercase preToolUse) rejects the hook.
    #expect(
        try extractCodex(
            #"{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"x"}}"#
        ).isEmpty
    )
    #expect(
        try extractCodex(
            #"{"hook_event_name":"preToolUse","tool_name":"Bash","tool_input":{"command":"x"}}"#
        ).isEmpty
    )
    // Non-shell tools and missing tool names yield nothing.
    #expect(
        try extractCodex(
            #"{"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":"x"}}"#
        ).isEmpty
    )
    #expect(
        try extractCodex(
            #"{"hook_event_name":"PreToolUse","tool_input":{"command":"x"}}"#
        ).isEmpty
    )
    // snake_case tool_name wins over camelCase toolName.
    #expect(
        try extractCodex(
            #"{"tool_name":"Bash","toolName":"Read","tool_input":{"command":"snake"}}"#
        ).map(\.command.rawValue) == ["snake"]
    )
}

@Test func codexTyped_functionCallRouting() throws {
    #expect(
        try extractCodex(
            #"{"type":"function_call","name":"shell","arguments":{"command":"one"}}"#
        ).map(\.command.rawValue) == ["one"]
    )
    #expect(
        try extractCodex(
            #"{"type":"tool_use","name":"bash","input":{"command":"two"}}"#
        ).map(\.command.rawValue) == ["two"]
    )
    // function_call reads `name`/`toolName` only — snake_case tool_name does not count.
    #expect(
        try extractCodex(
            #"{"type":"function_call","tool_name":"Bash","arguments":{"command":"x"}}"#
        ).isEmpty
    )
    #expect(
        try extractCodex(
            #"{"type":"function_call","name":"apply_patch","arguments":{"command":"x"}}"#
        ).isEmpty
    )
    // Command carrier priority: arguments, then input, then tool_input.
    #expect(
        try extractCodex(
            #"{"type":"function_call","name":"Bash","arguments":{"command":"args"},"input":{"command":"in"},"tool_input":{"command":"tool"}}"#
        ).map(\.command.rawValue) == ["args"]
    )
    #expect(
        try extractCodex(
            #"{"type":"function_call","name":"Bash","input":{"command":"in"},"tool_input":{"command":"tool"}}"#
        ).map(\.command.rawValue) == ["in"]
    )
}

@Test func codexTyped_execCommandShapes() throws {
    #expect(
        try extractCodex(
            #"{"type":"exec_command_begin","command":"git reset --hard"}"#
        ).map(\.command.rawValue) == ["git reset --hard"]
    )
    // exec_command has no tool-name gate and joins token arrays.
    #expect(
        try extractCodex(
            #"{"type":"exec_command","command":["git","status"]}"#
        ).map(\.command.rawValue) == ["git status"]
    )
    #expect(
        try extractCodex(
            #"{"type":"exec_command","command":{"command":"from-map"}}"#
        ).map(\.command.rawValue) == ["from-map"]
    )
}

@Test func codexTyped_commandValueShapes() throws {
    // Token arrays join; non-string elements are dropped.
    #expect(
        try extractCodex(
            #"{"tool_name":"Bash","tool_input":{"command":["git",42,"status"]}}"#
        ).map(\.command.rawValue) == ["git status"]
    )
    // JSON-encoded arguments string re-parses (object and array forms).
    #expect(
        try extractCodex(
            #"{"type":"function_call","name":"shell","arguments":"{\"command\":\"git status\"}"}"#
        ).map(\.command.rawValue) == ["git status"]
    )
    #expect(
        try extractCodex(
            #"{"type":"function_call","name":"shell","arguments":"[\"git\",\"log\"]"}"#
        ).map(\.command.rawValue) == ["git log"]
    )
    // Strings that are not top-level arrays/objects stay literal (no fragment re-parse).
    #expect(
        try extractCodex(
            #"{"type":"function_call","name":"shell","arguments":"123"}"#
        ).map(\.command.rawValue) == ["123"]
    )
    #expect(
        try extractCodex(
            #"{"type":"function_call","name":"shell","arguments":"git status"}"#
        ).map(\.command.rawValue) == ["git status"]
    )
    // A string under an object's `command` is literal, never re-parsed.
    #expect(
        try extractCodex(
            #"{"tool_name":"Bash","tool_input":{"command":"{\"not\":\"command\"}"}}"#
        ).map(\.command.rawValue) == ["{\"not\":\"command\"}"]
    )
    // A nested object under `command` yields nothing.
    #expect(
        try extractCodex(
            #"{"tool_name":"Bash","tool_input":{"command":{"command":"x"}}}"#
        ).isEmpty
    )
}

@Test func codexTyped_payloadQuirks() throws {
    // Envelope hook beats the payload.
    #expect(
        try extractCodex(
            #"{"tool_name":"Bash","tool_input":{"command":"env"},"payload":{"type":"function_call","name":"shell","arguments":{"command":"nested"}}}"#
        ).map(\.command.rawValue) == ["env"]
    )
    // Payload supplies the command when the envelope hook is absent.
    #expect(
        try extractCodex(
            #"{"session_id":"s","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":{"command":"nested"}}}"#
        ).map(\.command.rawValue) == ["nested"]
    )
    // A present-but-empty payload shadows the envelope function call.
    #expect(
        try extractCodex(
            #"{"type":"function_call","name":"shell","arguments":{"command":"env"},"payload":{"type":"response"}}"#
        ).isEmpty
    )
    // Payload nesting recurses for sessions too.
    let events = try extractCodex(
        #"{"payload":{"payload":{"session_id":"deep","type":"function_call","name":"shell","arguments":{"command":"x"}}}}"#
    )
    #expect(events.map(\.command.rawValue) == ["x"])
    #expect(events.allSatisfy { $0.sessionID == SessionID(validating: "deep") })
}

@Test func codexTyped_timestamps() throws {
    let payload = """
    {"tool_name":"Bash","tool_input":{"command":"a"},"timestamp":"2026-08-20T12:00:01.000Z"}
    {"tool_name":"Bash","tool_input":{"command":"b"},"timestamp":"2026-08-20T12:00:01Z"}
    {"tool_name":"Bash","tool_input":{"command":"c"},"ts":"2026-08-20T12:00:01Z"}
    {"tool_name":"Bash","tool_input":{"command":"d"},"ts":1700000000}
    {"tool_name":"Bash","tool_input":{"command":"e"},"ts":1700000000000}
    {"tool_name":"Bash","tool_input":{"command":"f"},"timestamp":"garbage","ts":"2026-08-20T12:00:01Z"}
    {"tool_name":"Bash","tool_input":{"command":"g"}}
    """
    let events = try extractCodex(payload)
    #expect(events.count == 7)
    #expect(events[0].occurredAt != nil)
    #expect(events[1].occurredAt != nil)
    #expect(events[2].occurredAt != nil)
    #expect(events[3].occurredAt == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(events[4].occurredAt == Date(timeIntervalSince1970: 1_700_000_000))
    // A present-but-garbage timestamp shadows ts.
    #expect(events[5].occurredAt == nil)
    #expect(events[6].occurredAt == nil)
}

@Test func codexTyped_sessions() throws {
    #expect(
        try extractCodex(
            #"{"session_id":"snake","sessionId":"camel","tool_name":"Bash","tool_input":{"command":"x"}}"#
        ).compactMap(\.sessionID) == [SessionID(validating: "snake")]
    )
    // Empty ids fall through; missing ids use the file stem.
    #expect(
        try extractCodex(
            #"{"session_id":"","sessionId":"camel","tool_name":"Bash","tool_input":{"command":"x"}}"#
        ).compactMap(\.sessionID) == [SessionID(validating: "camel")]
    )
    let stemmed = try extractCodex(
        #"{"tool_name":"Bash","tool_input":{"command":"x"}}"#,
        fileName: "rollout-abc.jsonl"
    )
    #expect(stemmed.compactMap(\.sessionID) == [SessionID(validating: "rollout-abc")])
}

@Test func codexTyped_workingDirectory() throws {
    // Nested carrier workdir beats the envelope cwd.
    #expect(
        try extractCodex(
            #"{"tool_name":"Bash","tool_input":{"command":"x","workdir":"/tmp"},"cwd":"/tmp/.ssh"}"#
        ).map { $0.workingDirectory?.rawValue } == ["/tmp"]
    )
    // workdir inside a JSON-encoded arguments string is found.
    #expect(
        try extractCodex(
            #"{"type":"function_call","name":"shell","arguments":"{\"command\":\"x\",\"workdir\":\"/tmp/ws\"}"}"#
        ).map { $0.workingDirectory?.rawValue } == ["/tmp/ws"]
    )
    // workdir follows the nested payload chain.
    #expect(
        try extractCodex(
            #"{"payload":{"tool_name":"Bash","tool_input":{"command":"x","cwd":"/nested"}},"cwd":"/env"}"#
        ).map { $0.workingDirectory?.rawValue } == ["/nested"]
    )
    // Cwd prefers camelCase toolInput while the command prefers snake_case tool_input.
    let events = try extractCodex(
        #"{"tool_name":"Bash","tool_input":{"command":"x","cwd":"/snake"},"toolInput":{"cwd":"/camel"},"cwd":"/env"}"#
    )
    #expect(events.map(\.command.rawValue) == ["x"])
    #expect(events.map { $0.workingDirectory?.rawValue } == ["/camel"])
    // Envelope-only cwd still applies.
    #expect(
        try extractCodex(
            #"{"tool_name":"Bash","tool_input":{"command":"x"},"cwd":"/env"}"#
        ).map { $0.workingDirectory?.rawValue } == ["/env"]
    )
}

@Test func codexTyped_crlfLineEndings() throws {
    let url = URL(fileURLWithPath: "/tmp/inline-codex-crlf.jsonl")
    let payload = "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"one\"}}\r\n{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"two\"}}\r\n"
    let events = try CodexStoreAdapter().extract(fileURL: url, data: Data(payload.utf8))
    #expect(events.map(\.command.rawValue) == ["one", "two"])
}

// MARK: - Cursor goldens

@Test func cursorTyped_fixtureGoldens() throws {
    let beforeShell = try fixtureURL("cursor/before-shell.jsonl")
    let beforeEvents = try CursorStoreAdapter().extract(
        fileURL: beforeShell, data: Data(contentsOf: beforeShell)
    )
    #expect(beforeEvents.map(\.command.rawValue) == ["git reset --hard"])
    #expect(beforeEvents.allSatisfy { $0.host == .cursor })
    #expect(beforeEvents.allSatisfy { $0.sessionID == SessionID(validating: "sess_cursor_1") })
    #expect(beforeEvents.allSatisfy { $0.sourcePath == beforeShell.path })
    #expect(beforeEvents.allSatisfy { $0.occurredAt != nil })
    #expect(beforeEvents.map { $0.workingDirectory?.rawValue } == ["/tmp/ws"])

    let pretool = try fixtureURL("cursor/pretool-shell.jsonl")
    let pretoolEvents = try CursorStoreAdapter().extract(
        fileURL: pretool, data: Data(contentsOf: pretool)
    )
    #expect(pretoolEvents.map(\.command.rawValue) == ["git status"])
    #expect(pretoolEvents.allSatisfy { $0.sessionID == SessionID(validating: "sess_hook") })
    #expect(pretoolEvents.map { $0.workingDirectory?.rawValue } == ["/tmp/ws"])
}

@Test func cursorTyped_failurePolicy() throws {
    let adapter = CursorStoreAdapter()
    let source = URL(fileURLWithPath: "/tmp/cursor-typed-unreadable.jsonl")
    #expect(throws: CursorStoreError.unreadable(sourcePath: source.path)) {
        _ = try adapter.extract(fileURL: source, data: Data())
    }
    #expect(throws: CursorStoreError.unreadable(sourcePath: source.path)) {
        _ = try adapter.extract(fileURL: source, data: Data([0xFF, 0xFE]))
    }
    #expect(throws: CursorStoreError.unreadable(sourcePath: source.path)) {
        _ = try adapter.extract(fileURL: source, data: Data("not-json\n".utf8))
    }
    #expect(throws: CursorStoreError.unreadable(sourcePath: source.path)) {
        _ = try adapter.extract(fileURL: source, data: Data("   \n".utf8))
    }
    // Any JSON object counts as usable, even with zero events or wrong-typed fields.
    #expect(try adapter.extract(fileURL: source, data: Data("{}\n".utf8)).isEmpty)
    #expect(try adapter.extract(fileURL: source, data: Data("{\"conversation_id\":42}\n".utf8)).isEmpty)
    // Non-object JSON lines never count as usable.
    #expect(throws: CursorStoreError.unreadable(sourcePath: source.path)) {
        _ = try adapter.extract(fileURL: source, data: Data("[1,2]\n\"hi\"\n42\n".utf8))
    }
}

@Test func cursorTyped_skipsBadLinesWithoutAborting() throws {
    let payload = """
    {"conversation_id":"s","hook_event_name":"beforeShellExecution","command":"git reset --hard"}
    not-json
    {"conversation_id":"s","hook_event_name":"preToolUse","tool_name":"Read","tool_input":{"path":"x"}}
    {"conversation_id":"s","hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{"command":"git status"}}
    """
    let events = try extractCursor(payload)
    #expect(events.map(\.command.rawValue) == ["git reset --hard", "git status"])
}

@Test func cursorTyped_wrongTypeScalarsKeepLine() throws {
    // Old per-field `as?` ignored a mistyped scalar and still extracted the
    // line; the whole line must not be dropped.
    let payload = """
    {"conversation_id":42,"timestamp":42,"cwd":42,"hook_event_name":"beforeShellExecution","command":"git status"}
    """
    let events = try extractCursor(payload, fileName: "sess-fallback.jsonl")
    #expect(events.count == 1)
    #expect(events[0].command.rawValue == "git status")
    #expect(events[0].occurredAt == nil)
    #expect(events[0].sessionID == SessionID(validating: "sess-fallback"))
    #expect(events[0].workingDirectory == nil)
}

@Test func cursorTyped_wrongTypeInputCwdFallsBackToEnvelope() throws {
    // A mistyped input cwd is ignored; the line still extracts with the
    // envelope cwd (old `fromEnvelope` nested-miss behavior).
    let payload = """
    {"tool_name":"Shell","tool_input":{"command":"git status","cwd":42},"cwd":"/tmp/envelope"}
    """
    let events = try extractCursor(payload)
    #expect(events.count == 1)
    #expect(events[0].workingDirectory == WorkingDirectory(validating: "/tmp/envelope"))
}

@Test func cursorTyped_beforeShellExecution() throws {
    #expect(
        try extractCursor(
            #"{"hook_event_name":"beforeShellExecution","command":"git reset --hard"}"#
        ).map(\.command.rawValue) == ["git reset --hard"]
    )
    // beforeShellExecution reads the direct command only: a tool alone yields nothing.
    #expect(
        try extractCursor(
            #"{"hook_event_name":"beforeShellExecution","tool_name":"Shell","tool_input":{"command":"x"}}"#
        ).isEmpty
    )
    #expect(
        try extractCursor(
            #"{"hook_event_name":"beforeShellExecution","command":""}"#
        ).isEmpty
    )
}

@Test func cursorTyped_preToolUseRouting() throws {
    #expect(
        try extractCursor(
            #"{"hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{"command":"one"}}"#
        ).map(\.command.rawValue) == ["one"]
    )
    #expect(
        try extractCursor(
            #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"two"}}"#
        ).map(\.command.rawValue) == ["two"]
    )
    // Missing event: the direct command wins over the tool.
    #expect(
        try extractCursor(
            #"{"tool_name":"Shell","tool_input":{"command":"tool"},"command":"direct"}"#
        ).map(\.command.rawValue) == ["direct"]
    )
    #expect(
        try extractCursor(
            #"{"tool_name":"Shell","tool_input":{"command":"tool"}}"#
        ).map(\.command.rawValue) == ["tool"]
    )
    // Other events and non-shell tools yield nothing.
    #expect(
        try extractCursor(
            #"{"hook_event_name":"postToolUse","tool_name":"Shell","tool_input":{"command":"x"}}"#
        ).isEmpty
    )
    #expect(
        try extractCursor(
            #"{"hook_event_name":"preToolUse","tool_name":"Read","tool_input":{"command":"x"}}"#
        ).isEmpty
    )
}

@Test func cursorTyped_toolInputShapes() throws {
    // Object form yields its string command; array commands are ignored.
    #expect(
        try extractCursor(
            #"{"tool_name":"Shell","tool_input":{"command":"git status"}}"#
        ).map(\.command.rawValue) == ["git status"]
    )
    #expect(
        try extractCursor(
            #"{"tool_name":"Shell","tool_input":{"command":["git","status"]}}"#
        ).isEmpty
    )
    // String form is literal — never re-parsed as JSON, unlike Codex.
    #expect(
        try extractCursor(
            #"{"tool_name":"Shell","tool_input":"git status"}"#
        ).map(\.command.rawValue) == ["git status"]
    )
    #expect(
        try extractCursor(
            #"{"tool_name":"Shell","tool_input":"{\"command\":\"x\"}"}"#
        ).map(\.command.rawValue) == ["{\"command\":\"x\"}"]
    )
    // Numbers and arrays are inert.
    #expect(
        try extractCursor(
            #"{"tool_name":"Shell","tool_input":42}"#
        ).isEmpty
    )
    #expect(
        try extractCursor(
            #"{"tool_name":"Shell","tool_input":["git","status"]}"#
        ).isEmpty
    )
    // snake_case tool_input wins over camelCase toolInput for the command.
    #expect(
        try extractCursor(
            #"{"tool_name":"Shell","tool_input":{"command":"snake"},"toolInput":{"command":"camel"}}"#
        ).map(\.command.rawValue) == ["snake"]
    )
}

@Test func cursorTyped_timestamps() throws {
    let payload = """
    {"tool_name":"Shell","tool_input":{"command":"a"},"timestamp":"2026-08-27T00:00:00Z"}
    {"tool_name":"Shell","tool_input":{"command":"b"},"ts":"2026-08-27T00:00:00Z"}
    {"tool_name":"Shell","tool_input":{"command":"c"},"timestamp":1700000000}
    {"tool_name":"Shell","tool_input":{"command":"d"},"timestamp":"garbage","ts":"2026-08-27T00:00:00Z"}
    """
    let events = try extractCursor(payload)
    #expect(events.count == 4)
    #expect(events[0].occurredAt != nil)
    #expect(events[1].occurredAt != nil)
    // Numeric timestamps are ignored (and still shadow ts).
    #expect(events[2].occurredAt == nil)
    // A present-but-garbage timestamp shadows ts.
    #expect(events[3].occurredAt == nil)
}

@Test func cursorTyped_sessions() throws {
    #expect(
        try extractCursor(
            #"{"conversation_id":"conv","session_id":"snake","sessionId":"camel","tool_name":"Shell","tool_input":{"command":"x"}}"#
        ).compactMap(\.sessionID) == [SessionID(validating: "conv")]
    )
    #expect(
        try extractCursor(
            #"{"session_id":"snake","sessionId":"camel","tool_name":"Shell","tool_input":{"command":"x"}}"#
        ).compactMap(\.sessionID) == [SessionID(validating: "snake")]
    )
    let stemmed = try extractCursor(
        #"{"tool_name":"Shell","tool_input":{"command":"x"}}"#,
        fileName: "sess-99.jsonl"
    )
    #expect(stemmed.compactMap(\.sessionID) == [SessionID(validating: "sess-99")])
}

@Test func cursorTyped_workingDirectory() throws {
    // Nested tool_input workdir beats the envelope cwd.
    #expect(
        try extractCursor(
            #"{"tool_name":"Shell","tool_input":{"command":"x","workdir":"/tmp"},"cwd":"/tmp/.ssh"}"#
        ).map { $0.workingDirectory?.rawValue } == ["/tmp"]
    )
    // Cwd prefers camelCase toolInput while the command prefers snake_case tool_input.
    let events = try extractCursor(
        #"{"tool_name":"Shell","tool_input":{"command":"x","cwd":"/snake"},"toolInput":{"cwd":"/camel"},"cwd":"/env"}"#
    )
    #expect(events.map(\.command.rawValue) == ["x"])
    #expect(events.map { $0.workingDirectory?.rawValue } == ["/camel"])
    // workdir inside a JSON-encoded tool_input string is found.
    #expect(
        try extractCursor(
            #"{"tool_name":"Shell","tool_input":"{\"cwd\":\"/tmp/ws\"}","cwd":"/env"}"#
        ).map { $0.workingDirectory?.rawValue } == ["/tmp/ws"]
    )
    // Envelope-only cwd still applies.
    #expect(
        try extractCursor(
            #"{"tool_name":"Shell","tool_input":{"command":"x"},"cwd":"/env"}"#
        ).map { $0.workingDirectory?.rawValue } == ["/env"]
    )
}

@Test func cursorTyped_crlfLineEndings() throws {
    let url = URL(fileURLWithPath: "/tmp/inline-cursor-crlf.jsonl")
    let payload = "{\"hook_event_name\":\"beforeShellExecution\",\"command\":\"one\"}\r\n{\"hook_event_name\":\"beforeShellExecution\",\"command\":\"two\"}\r\n"
    let events = try CursorStoreAdapter().extract(fileURL: url, data: Data(payload.utf8))
    #expect(events.map(\.command.rawValue) == ["one", "two"])
}
