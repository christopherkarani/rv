import Foundation
#if canImport(SQLite3)
import SQLite3
#endif
import Testing
import RVDomain
@testable import RVScan

// Loose-policy parity: every adapter admits exactly its legacy/dual tool and
// event spellings through the T3a vocabulary, with nested-JSON behavior
// unchanged. Unknown and file-tool spellings stay foreign (skipped).

@Test func claudeVocabulary_allFourShellSpellingsExtract() throws {
    let payload = """
    {"type":"assistant","sessionId":"s","timestamp":"2026-08-20T12:00:01.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"1","name":"Bash","input":{"command":"cmd-bash"}},{"type":"tool_use","id":"2","name":"bash","input":{"command":"cmd-bash-lower"}},{"type":"tool_use","id":"3","name":"Shell","input":{"command":"cmd-shell"}},{"type":"tool_use","id":"4","name":"shell","input":{"command":"cmd-shell-lower"}}]}}
    """
    let url = URL(fileURLWithPath: "/tmp/parity-claude.jsonl")
    let events = try ClaudeSessionStoreAdapter().extract(fileURL: url, data: Data(payload.utf8))
    #expect(events.map(\.command.rawValue) == ["cmd-bash", "cmd-bash-lower", "cmd-shell", "cmd-shell-lower"])
}

@Test func claudeVocabulary_fileAliasAndUnknownSkipped() throws {
    let payload = """
    {"type":"assistant","sessionId":"s","message":{"content":[{"type":"tool_use","name":"Read","input":{"command":"no-read"}},{"type":"tool_use","name":"read_file","input":{"command":"no-read-file"}},{"type":"tool_use","name":"BashX","input":{"command":"no-unknown"}}]}}
    """
    let url = URL(fileURLWithPath: "/tmp/parity-claude-foreign.jsonl")
    let events = try ClaudeSessionStoreAdapter().extract(fileURL: url, data: Data(payload.utf8))
    #expect(events.isEmpty)
}

@Test func codexVocabulary_hookPathAdmitsAllFourShellSpellings() throws {
    let payload = """
    {"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cmd-bash"}}
    {"session_id":"s","hook_event_name":"PreToolUse","tool_name":"bash","tool_input":{"command":"cmd-bash-lower"}}
    {"session_id":"s","hook_event_name":"PreToolUse","tool_name":"shell","tool_input":{"command":"cmd-shell"}}
    {"session_id":"s","hook_event_name":"PreToolUse","tool_name":"local_shell","tool_input":{"command":"cmd-local"}}
    """
    let url = URL(fileURLWithPath: "/tmp/parity-codex.jsonl")
    let events = try CodexStoreAdapter().extract(fileURL: url, data: Data(payload.utf8))
    #expect(events.map(\.command.rawValue) == ["cmd-bash", "cmd-bash-lower", "cmd-shell", "cmd-local"])
}

@Test func codexVocabulary_functionCallPathKeepsNestedJSONBehavior() throws {
    let payload = """
    {"session_id":"s","type":"function_call","name":"shell","arguments":{"command":"cmd-object"}}
    {"session_id":"s","type":"function_call","name":"local_shell","arguments":"{\\"command\\":\\"cmd-string\\"}"}
    {"session_id":"s","type":"tool_use","name":"Bash","input":"{\\"command\\":\\"cmd-input-string\\"}"}
    """
    let url = URL(fileURLWithPath: "/tmp/parity-codex-nested.jsonl")
    let events = try CodexStoreAdapter().extract(fileURL: url, data: Data(payload.utf8))
    #expect(events.map(\.command.rawValue) == ["cmd-object", "cmd-string", "cmd-input-string"])
}

@Test func codexVocabulary_eventGateParity() throws {
    let gated = """
    {"session_id":"s","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"no-gated"}}
    {"session_id":"s","hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":"no-foreign"}}
    """
    let gatedURL = URL(fileURLWithPath: "/tmp/parity-codex-gated.jsonl")
    #expect(try CodexStoreAdapter().extract(fileURL: gatedURL, data: Data(gated.utf8)).isEmpty)

    // A missing event still opens the hook path (flow, not a spelling).
    let missing = """
    {"session_id":"s","tool_name":"Bash","tool_input":{"command":"cmd-no-event"}}
    """
    let missingURL = URL(fileURLWithPath: "/tmp/parity-codex-noevent.jsonl")
    let events = try CodexStoreAdapter().extract(fileURL: missingURL, data: Data(missing.utf8))
    #expect(events.map(\.command.rawValue) == ["cmd-no-event"])
}

@Test func cursorVocabulary_preToolUseAdmitsAllFourShellSpellings() throws {
    let payload = """
    {"conversation_id":"s","hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{"command":"cmd-shell"}}
    {"conversation_id":"s","hook_event_name":"preToolUse","tool_name":"Bash","tool_input":{"command":"cmd-bash"}}
    {"conversation_id":"s","hook_event_name":"preToolUse","tool_name":"shell","tool_input":{"command":"cmd-shell-lower"}}
    {"conversation_id":"s","hook_event_name":"preToolUse","tool_name":"bash","tool_input":{"command":"cmd-bash-lower"}}
    {"conversation_id":"s","hook_event_name":"PreToolUse","tool_name":"shell","tool_input":{"command":"cmd-capital-event"}}
    """
    let url = URL(fileURLWithPath: "/tmp/parity-cursor.jsonl")
    let events = try CursorStoreAdapter().extract(fileURL: url, data: Data(payload.utf8))
    #expect(events.map(\.command.rawValue) == [
        "cmd-shell", "cmd-bash", "cmd-shell-lower", "cmd-bash-lower", "cmd-capital-event",
    ])
}

@Test func cursorVocabulary_eventPathsDoNotCross() throws {
    let payload = """
    {"conversation_id":"s","hook_event_name":"preToolUse","command":"no-command-path"}
    {"conversation_id":"s","hook_event_name":"beforeShellExecution","tool_name":"Shell","tool_input":{"command":"no-tool-path"}}
    {"conversation_id":"s","hook_event_name":"PostToolUse","tool_name":"Shell","tool_input":{"command":"no-unknown-event"}}
    {"conversation_id":"s","hook_event_name":"preToolUse","tool_name":"Read","tool_input":{"command":"no-file-alias"}}
    """
    let url = URL(fileURLWithPath: "/tmp/parity-cursor-cross.jsonl")
    let events = try CursorStoreAdapter().extract(fileURL: url, data: Data(payload.utf8))
    #expect(events.isEmpty)
}

@Test func cursorVocabulary_missingEventKeepsBothPaths() throws {
    let payload = """
    {"conversation_id":"s","command":"cmd-top-level"}
    {"conversation_id":"s","tool_name":"bash","tool_input":{"command":"cmd-tool"}}
    """
    let url = URL(fileURLWithPath: "/tmp/parity-cursor-noevent.jsonl")
    let events = try CursorStoreAdapter().extract(fileURL: url, data: Data(payload.utf8))
    #expect(events.map(\.command.rawValue) == ["cmd-top-level", "cmd-tool"])
}

@Test func grokVocabulary_allThreeShellSpellingsExtract() throws {
    let payload = """
    {"type":"assistant","tool_calls":[{"id":"1","name":"run_terminal_command","arguments":"{\\"command\\":\\"cmd-full\\"}"},{"id":"2","name":"run_terminal_cmd","arguments":"{\\"command\\":\\"cmd-short\\"}"},{"id":"3","name":"Bash","arguments":{"command":"cmd-object"}},{"id":"4","name":"grep","arguments":"{\\"pattern\\":\\"x\\"}"},{"id":"5","name":"Read","arguments":"{\\"command\\":\\"no-file\\"}"}]}
    """
    let url = URL(fileURLWithPath: "/home/u/.grok/sessions/%2Ftmp%2Fws/sess-1/chat_history.jsonl")
    let events = try GrokStoreAdapter().extract(fileURL: url, data: Data(payload.utf8))
    #expect(events.map(\.command.rawValue) == ["cmd-full", "cmd-short", "cmd-object"])
}

@Test func piVocabulary_bashExtractsOthersSkipped() throws {
    let payload = """
    {"type":"session","id":"pi-parity-1","cwd":"/tmp/rv-scan-fixture"}
    {"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"a","name":"bash","arguments":{"command":"cmd-bash"}},{"type":"toolCall","id":"b","name":"Bash","arguments":{"command":"no-capital"}},{"type":"toolCall","id":"c","name":"read","arguments":{"command":"no-read"}},{"type":"text","text":"nope"}]}}
    """
    let url = URL(fileURLWithPath: "/tmp/parity-pi.jsonl")
    let events = try PiStoreAdapter().extract(fileURL: url, data: Data(payload.utf8))
    #expect(events.map(\.command.rawValue) == ["cmd-bash"])
    #expect(events.allSatisfy { $0.sessionID == SessionID(validating: "pi-parity-1") })
}

#if canImport(SQLite3)
@Test func hermesVocabulary_terminalExtractsOthersSkipped() throws {
    try withTempHome { homeURL in
        let dbURL = homeURL.appendingPathComponent("state.db")
        try writeParityHermesDatabase(at: dbURL, rows: [
            ("s1", #"[{"name":"terminal","arguments":{"command":"cmd-terminal"}}]"#),
            ("s1", #"{"function":{"name":"terminal","arguments":{"command":"cmd-nested"}}}"#),
            ("s1", #"[{"toolName":"terminal","params":"{\"command\":\"cmd-string\"}"}]"#),
            ("s1", #"[{"name":"shell","arguments":{"command":"no-shell"}}]"#),
            ("s1", #"[{"name":"Read","arguments":{"command":"no-file"}}]"#),
            ("s1", #"[{"arguments":{"command":"no-name"}}]"#),
        ])
        let events = try HermesStoreAdapter().extract(fileURL: dbURL, data: Data(contentsOf: dbURL))
        #expect(events.map(\.command.rawValue) == ["cmd-terminal", "cmd-nested", "cmd-string"])
    }
}

@Test func openClawVocabulary_execExtractsOthersSkipped() throws {
    try withTempHome { homeURL in
        let dbURL = homeURL.appendingPathComponent("openclaw-agent.sqlite")
        try writeParityOpenClawDatabase(at: dbURL, rows: [
            ("s1", #"{"name":"exec","arguments":{"command":"cmd-exec"}}"#),
            ("s1", #"{"toolName":"exec","params":{"command":"cmd-dual-keys"}}"#),
            ("s1", #"{"toolCall":{"name":"exec","input":{"command":"cmd-nested"}}}"#),
            ("s1", #"{"name":"run","arguments":{"command":"no-run"}}"#),
            ("s1", #"{"name":"Exec","arguments":{"command":"no-capital"}}"#),
        ])
        let events = try OpenClawStoreAdapter().extract(fileURL: dbURL, data: Data(contentsOf: dbURL))
        #expect(events.map(\.command.rawValue) == ["cmd-exec", "cmd-dual-keys", "cmd-nested"])
    }
}

@Test func openCodeVocabulary_bashExtractsStrictOnlySpellingSkipped() throws {
    try withTempHome { homeURL in
        let dbURL = homeURL.appendingPathComponent("opencode.db")
        try writeParityOpenCodeDatabase(at: dbURL, rows: [
            ("s1", #"{"type":"tool","tool":"bash","state":{"input":{"command":"cmd-bash"}}}"#),
            // `session.shell` is the strict-side TUI door: foreign on the loose side.
            ("s1", #"{"type":"tool","tool":"session.shell","state":{"input":{"command":"no-strict-only"}}}"#),
            ("s1", #"{"type":"tool","tool":"read","state":{"input":{"command":"no-read"}}}"#),
            ("s1", #"{"type":"text","tool":"bash","state":{"input":{"command":"no-text"}}}"#),
        ])
        let events = try OpenCodeStoreAdapter().extract(fileURL: dbURL, data: Data(contentsOf: dbURL))
        #expect(events.map(\.command.rawValue) == ["cmd-bash"])
    }
}

private enum ParityFixtureError: Error {
    case openFailed
    case execFailed
    case prepareFailed
    case stepFailed
}

private func openParityDatabase(at url: URL, ddl: String, insertSQL: String, rows: [(String, String)]) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
        throw ParityFixtureError.openFailed
    }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK else {
        throw ParityFixtureError.execFailed
    }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw ParityFixtureError.prepareFailed
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (sessionID, json) in rows {
        _ = sessionID.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
        _ = json.withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ParityFixtureError.stepFailed
        }
        sqlite3_reset(statement)
    }
}

private func writeParityHermesDatabase(at url: URL, rows: [(String, String)]) throws {
    try openParityDatabase(
        at: url,
        ddl: "CREATE TABLE messages (session_id TEXT, role TEXT, content TEXT, tool_calls TEXT, timestamp REAL);",
        insertSQL: "INSERT INTO messages (session_id, role, content, tool_calls, timestamp) VALUES (?, 'assistant', NULL, ?, 1710000000.0);",
        rows: rows
    )
}

private func writeParityOpenClawDatabase(at url: URL, rows: [(String, String)]) throws {
    try openParityDatabase(
        at: url,
        ddl: "CREATE TABLE transcript_events (session_id TEXT, seq INTEGER, event_json TEXT, created_at INTEGER);",
        insertSQL: "INSERT INTO transcript_events (session_id, seq, event_json, created_at) VALUES (?, 1, ?, 1);",
        rows: rows
    )
}

private func writeParityOpenCodeDatabase(at url: URL, rows: [(String, String)]) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
        throw ParityFixtureError.openFailed
    }
    defer { sqlite3_close(db) }
    let ddl = "CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);"
    guard sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK else {
        throw ParityFixtureError.execFailed
    }
    var statement: OpaquePointer?
    let insert = "INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, 1, 1, ?);"
    guard sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw ParityFixtureError.prepareFailed
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (index, row) in rows.enumerated() {
        _ = "part_\(index)".withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
        _ = "msg_\(index)".withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) }
        _ = row.0.withCString { sqlite3_bind_text(statement, 3, $0, -1, transient) }
        _ = row.1.withCString { sqlite3_bind_text(statement, 4, $0, -1, transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ParityFixtureError.stepFailed
        }
        sqlite3_reset(statement)
    }
}
#endif
