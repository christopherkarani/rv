import Foundation
#if canImport(SQLite3)
import SQLite3
#endif
import Testing
import RVDomain
@testable import RVScan

private func extractGrok(_ payload: String, sessionDir: String = "inline-grok") throws -> [ExtractedEvent] {
    let url = URL(fileURLWithPath: "/tmp/\(sessionDir)/chat_history.jsonl")
    return try GrokStoreAdapter().extract(fileURL: url, data: Data(payload.utf8))
}

private func extractPi(_ payload: String, fileName: String = "inline-pi.jsonl") throws -> [ExtractedEvent] {
    let url = URL(fileURLWithPath: "/tmp/\(fileName)")
    return try PiStoreAdapter().extract(fileURL: url, data: Data(payload.utf8))
}

// MARK: - Grok goldens

@Test func grokTyped_fixtureGoldens() throws {
    let fixture = try fixtureURL("grok/chat_history.jsonl")
    let fileURL = URL(fileURLWithPath: "/tmp/sess-grok-1/chat_history.jsonl")
    let events = try GrokStoreAdapter().extract(fileURL: fileURL, data: Data(contentsOf: fixture))
    #expect(events.map(\.command.rawValue) == ["git reset --hard", "git status"])
    #expect(events.allSatisfy { $0.host == .grok })
    #expect(events.allSatisfy { $0.sessionID == SessionID(validating: "sess-grok-1") })
    #expect(events.allSatisfy { $0.sourcePath == fileURL.path })
    #expect(events.allSatisfy { $0.occurredAt == nil })
    // No `.grok/sessions/<cwd>/` layout — recovery would guess. Leave nil.
    #expect(events.allSatisfy { $0.workingDirectory == nil })
}

@Test func grokTyped_failurePolicy() throws {
    // Best-effort: never throws; undecodable input yields zero events.
    let adapter = GrokStoreAdapter()
    let source = URL(fileURLWithPath: "/tmp/inline-grok/chat_history.jsonl")
    #expect(try adapter.extract(fileURL: source, data: Data()).isEmpty)
    #expect(try adapter.extract(fileURL: source, data: Data([0xFF, 0xFE])).isEmpty)
    #expect(try adapter.extract(fileURL: source, data: Data("not-json\n".utf8)).isEmpty)
    #expect(try adapter.extract(fileURL: source, data: Data("   \n".utf8)).isEmpty)
    #expect(try adapter.extract(fileURL: source, data: Data("{}\n".utf8)).isEmpty)
}

@Test func grokTyped_skipsBadLinesWithoutAborting() throws {
    let payload = """
    not-json
    {"type":"assistant","tool_calls":[{"id":"c1","name":"run_terminal_command","arguments":"{\\"command\\":\\"git reset --hard\\"}"}]}
    [1,2]
    {"type":"assistant","tool_calls":[{"id":"c2","name":"Bash","arguments":"{\\"command\\":\\"git status\\"}"}]}
    """
    let events = try extractGrok(payload)
    #expect(events.map(\.command.rawValue) == ["git reset --hard", "git status"])
    #expect(events.allSatisfy { $0.sessionID == SessionID(validating: "inline-grok") })
}

@Test func grokTyped_wrongTypeScalarsKeepLine() throws {
    // Old per-field `as?` ignored mistyped scalars and still extracted the
    // line; a wrong-typed call must not drop its siblings.
    let payload = """
    {"type":"assistant","tool_calls":[{"name":42,"arguments":42},{"name":"Bash","arguments":{"command":42}},{"name":"Bash","arguments":"{\\"command\\":\\"git status\\"}"}]}
    {"type":42,"tool_calls":[{"name":"Bash","arguments":"{\\"command\\":\\"dropped\\"}"}]}
    """
    let events = try extractGrok(payload)
    #expect(events.map(\.command.rawValue) == ["git status"])
}

@Test func grokTyped_objectArgumentsAndEmptyFiltering() throws {
    // `arguments` may be an object directly; missing/empty commands are skipped.
    let payload = """
    {"type":"assistant","tool_calls":[{"name":"Bash","arguments":{"command":"git log"}},{"name":"Bash","arguments":{"command":""}},{"name":"Bash","arguments":{}},{"name":"Bash"}]}
    """
    #expect(try extractGrok(payload).map(\.command.rawValue) == ["git log"])
    // A string that is not a JSON object yields no command.
    let nonObjects = """
    {"type":"assistant","tool_calls":[{"name":"Bash","arguments":"[1,2]"},{"name":"Bash","arguments":"not json"},{"name":"Bash","arguments":42}]}
    """
    #expect(try extractGrok(nonObjects).isEmpty)
}

@Test func grokTyped_toolRouting() throws {
    // Non-assistant entries and non-shell tools are skipped.
    let payload = """
    {"type":"user","tool_calls":[{"name":"Bash","arguments":"{\\"command\\":\\"dropped\\"}"}]}
    {"type":"assistant","tool_calls":[{"name":"grep","arguments":"{\\"command\\":\\"dropped\\"}"}]}
    {"type":"assistant"}
    {"type":"assistant","tool_calls":[{"name":"run_terminal_cmd","arguments":"{\\"command\\":\\"kept\\"}"}]}
    """
    #expect(try extractGrok(payload).map(\.command.rawValue) == ["kept"])
}

@Test func grokTyped_nonObjectCallSkipsLine() throws {
    // A non-object `tool_calls` element fails the whole array, matching the
    // old `as? [[String: Any]]` line check; the next line still extracts.
    let payload = """
    {"type":"assistant","tool_calls":[{"name":"Bash","arguments":"{\\"command\\":\\"one\\"}"},"junk"]}
    {"type":"assistant","tool_calls":[{"name":"Bash","arguments":"{\\"command\\":\\"two\\"}"}]}
    """
    #expect(try extractGrok(payload).map(\.command.rawValue) == ["two"])
}

// MARK: - Pi goldens

@Test func piTyped_fixtureGoldens() throws {
    let fixture = try fixtureURL("pi/session.jsonl")
    let events = try PiStoreAdapter().extract(fileURL: fixture, data: Data(contentsOf: fixture))
    #expect(events.map(\.command.rawValue) == ["git reset --hard", "git status"])
    #expect(events.allSatisfy { $0.host == .pi })
    #expect(events.allSatisfy { $0.sessionID == SessionID(validating: "pi-sess-fixture-1") })
    #expect(events.allSatisfy { $0.sourcePath == fixture.path })
    // Line timestamps win over the numeric message timestamps.
    #expect(events[0].occurredAt == ScanTimestamp.parse("2026-01-15T12:01:00.000Z"))
    #expect(events[1].occurredAt == ScanTimestamp.parse("2026-01-15T12:02:00.000Z"))
    #expect(events.allSatisfy { $0.workingDirectory?.rawValue == "/tmp/rv-scan-fixture" })
}

@Test func piTyped_failurePolicy() throws {
    // Best-effort: never throws; undecodable input yields zero events.
    let adapter = PiStoreAdapter()
    let source = URL(fileURLWithPath: "/tmp/inline-pi.jsonl")
    #expect(try adapter.extract(fileURL: source, data: Data()).isEmpty)
    #expect(try adapter.extract(fileURL: source, data: Data([0xFF, 0xFE])).isEmpty)
    #expect(try adapter.extract(fileURL: source, data: Data("not-json\n".utf8)).isEmpty)
    #expect(try adapter.extract(fileURL: source, data: Data("   \n".utf8)).isEmpty)
    #expect(try adapter.extract(fileURL: source, data: Data("{}\n".utf8)).isEmpty)
}

@Test func piTyped_skipsBadLinesWithoutAborting() throws {
    let payload = """
    not-json
    {"type":"session","id":"s1","cwd":"/tmp/ws"}
    {"type":"message","timestamp":"2026-01-15T12:01:00.000Z","message":{"role":"assistant","content":[{"type":"toolCall","name":"bash","arguments":{"command":"git reset --hard"}}]}}
    [1,2]
    {"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","name":"bash","arguments":{"command":"git status"}}]}}
    """
    let events = try extractPi(payload)
    #expect(events.map(\.command.rawValue) == ["git reset --hard", "git status"])
    #expect(events.allSatisfy { $0.sessionID == SessionID(validating: "s1") })
    #expect(events.allSatisfy { $0.workingDirectory?.rawValue == "/tmp/ws" })
    #expect(events[0].occurredAt == ScanTimestamp.parse("2026-01-15T12:01:00.000Z"))
    #expect(events[1].occurredAt == nil)
}

@Test func piTyped_wrongTypeScalarsKeepLine() throws {
    // Old per-field `as?` ignored mistyped scalars; the line still extracts
    // with nil session/timestamps/cwd.
    let payload = """
    {"type":"session","id":42,"cwd":42,"timestamp":[42]}
    {"type":"message","timestamp":true,"message":{"role":"assistant","timestamp":{"x":1},"content":[{"type":"toolCall","name":42,"arguments":{"command":"dropped"}},{"type":"toolCall","name":"bash","arguments":{"command":"git status","cwd":42}}]}}
    {"type":42,"message":{"role":"assistant","content":[{"type":"toolCall","name":"bash","arguments":{"command":"dropped"}}]}}
    """
    let events = try extractPi(payload)
    #expect(events.map(\.command.rawValue) == ["git status"])
    #expect(events[0].sessionID == nil)
    #expect(events[0].occurredAt == nil)
    #expect(events[0].workingDirectory == nil)
}

@Test func piTyped_timestampFallback() throws {
    // A present-but-unparseable line timestamp falls through to the message
    // timestamp (unlike Codex presence-shadowing); numbers are epoch seconds
    // (milliseconds above 1e12).
    let payload = """
    {"type":"message","timestamp":"bogus","message":{"role":"assistant","timestamp":1736942460000,"content":[{"type":"toolCall","name":"bash","arguments":{"command":"one"}}]}}
    {"type":"message","timestamp":1736942520,"message":{"role":"assistant","content":[{"type":"toolCall","name":"bash","arguments":{"command":"two"}}]}}
    """
    let events = try extractPi(payload)
    #expect(events.map(\.command.rawValue) == ["one", "two"])
    #expect(events[0].occurredAt == Date(timeIntervalSince1970: 1_736_942_460))
    #expect(events[1].occurredAt == Date(timeIntervalSince1970: 1_736_942_520))
}

@Test func piTyped_workingDirectoryPriority() throws {
    // Arguments cwd wins over item cwd wins over session cwd.
    let payload = """
    {"type":"session","id":"s","cwd":"/tmp/session"}
    {"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","name":"bash","arguments":{"command":"one","cwd":"/tmp/args"},"cwd":"/tmp/item"},{"type":"toolCall","name":"bash","arguments":{"command":"two"},"workdir":"/tmp/item2"},{"type":"toolCall","name":"bash","arguments":{"command":"three"}}]}}
    """
    let events = try extractPi(payload)
    #expect(events.map(\.command.rawValue) == ["one", "two", "three"])
    #expect(events.map { $0.workingDirectory?.rawValue } == ["/tmp/args", "/tmp/item2", "/tmp/session"])
}

@Test func piTyped_sessionAccumulation() throws {
    // Messages before any session line carry nil; later session lines win.
    let payload = """
    {"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","name":"bash","arguments":{"command":"one"}}]}}
    {"type":"session","id":"s1"}
    {"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","name":"bash","arguments":{"command":"two"}}]}}
    {"type":"session","id":"s2"}
    {"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","name":"bash","arguments":{"command":"three"}}]}}
    """
    let events = try extractPi(payload)
    #expect(events.map(\.command.rawValue) == ["one", "two", "three"])
    #expect(events[0].sessionID == nil)
    #expect(events[1].sessionID == SessionID(validating: "s1"))
    #expect(events[2].sessionID == SessionID(validating: "s2"))
}

@Test func piTyped_toolRouting() throws {
    // Non-assistant roles, non-bash tools, and string content are skipped; a
    // non-object content element fails the whole line (old `as?` check).
    // Unlike Grok, string `arguments` are never re-parsed as JSON.
    let payload = """
    {"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","name":"bash","arguments":{"command":"one"}},"junk"]}}
    {"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","name":"bash","arguments":{"command":"two"}}]}}
    {"type":"message","message":{"role":"toolResult","content":[{"type":"toolCall","name":"bash","arguments":{"command":"dropped"}}]}}
    {"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","name":"read","arguments":{"command":"dropped"}}]}}
    {"type":"message","message":{"role":"assistant","content":"just a string"}}
    {"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","name":"bash","arguments":"{\\"command\\":\\"dropped\\"}"}]}}
    """
    #expect(try extractPi(payload).map(\.command.rawValue) == ["two"])
}

// MARK: - OpenCode goldens

@Test func openCodeTyped_fixtureGoldens() throws {
    let partJSON = try String(contentsOf: fixtureURL("opencode/bash-part.json"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let events = try extractOpenCode(rows: [(sessionID: "ses_fixture_1", partJSON: partJSON)])
    #expect(events.map(\.command.rawValue) == ["git reset --hard"])
    #expect(events.allSatisfy { $0.host == .opencode })
    #expect(events.allSatisfy { $0.sessionID == SessionID(validating: "ses_fixture_1") })
    #expect(events.allSatisfy { $0.occurredAt == Date(timeIntervalSince1970: 1_736_942_460) })
    #expect(events.allSatisfy { $0.workingDirectory == nil })
}

@Test func openCodeTyped_skipsBadRowsWithoutAborting() throws {
    let events = try extractOpenCode(rows: [
        (sessionID: "s", partJSON: #"{"type":"text","tool":"bash","state":{"input":{"command":"dropped"}}}"#),
        (sessionID: "s", partJSON: #"{"type":"tool","tool":"read","state":{"input":{"command":"dropped"}}}"#),
        (sessionID: "s", partJSON: #"{"type":"tool","tool":"bash","state":{"input":{}}}"#),
        (sessionID: "s", partJSON: #"{"type":"tool","tool":"bash","state":{"input":{"command":""}}}"#),
        (sessionID: "s", partJSON: #"{"type":"tool","tool":"bash"}"#),
        (sessionID: "s", partJSON: "not-json"),
        (sessionID: "s", partJSON: "[1,2]"),
        (sessionID: "s", partJSON: nil),
        (sessionID: nil, partJSON: #"{"type":"tool","tool":"bash","state":{"input":{"command":"kept"}}}"#),
    ])
    #expect(events.map(\.command.rawValue) == ["kept"])
    #expect(events[0].sessionID == nil)
    #expect(events[0].occurredAt == nil)
}

@Test func openCodeTyped_wrongTypeScalarsKeepRow() throws {
    // Old per-field `as?` ignored mistyped scalars; the row still extracts
    // with nil timestamps/cwd, while mistyped routing/command skips the row.
    let events = try extractOpenCode(rows: [
        (sessionID: "s", partJSON: #"{"type":"tool","tool":"bash","cwd":42,"state":{"input":{"command":"one","cwd":42},"time":{"start":"nope"}}}"#),
        (sessionID: "s", partJSON: #"{"type":42,"tool":"bash","state":{"input":{"command":"dropped"}}}"#),
        (sessionID: "s", partJSON: #"{"type":"tool","tool":"bash","state":{"input":{"command":42}}}"#),
        (sessionID: "s", partJSON: #"{"type":"tool","tool":"bash","state":"oops"}"#),
        (sessionID: "s", partJSON: #"{"type":"tool","tool":"bash","state":{"input":{"command":"two"},"time":42}}"#),
    ])
    #expect(events.map(\.command.rawValue) == ["one", "two"])
    #expect(events.allSatisfy { $0.occurredAt == nil })
    #expect(events.allSatisfy { $0.workingDirectory == nil })
}

@Test func openCodeTyped_workingDirectoryPriority() throws {
    // Input cwd wins over state cwd wins over row cwd.
    let events = try extractOpenCode(rows: [
        (sessionID: "s", partJSON: #"{"type":"tool","tool":"bash","cwd":"/tmp/row","state":{"cwd":"/tmp/state","input":{"command":"one","cwd":"/tmp/input"}}}"#),
        (sessionID: "s", partJSON: #"{"type":"tool","tool":"bash","workdir":"/tmp/row2","state":{"workdir":"/tmp/state2","input":{"command":"two"}}}"#),
        (sessionID: "s", partJSON: #"{"type":"tool","tool":"bash","working_directory":"/tmp/row3","state":{"input":{"command":"three"}}}"#),
    ])
    #expect(events.map(\.command.rawValue) == ["one", "two", "three"])
    #expect(events.map { $0.workingDirectory?.rawValue } == ["/tmp/input", "/tmp/state2", "/tmp/row3"])
}

@Test func openCodeTyped_timestampSecondsAndMillis() throws {
    let events = try extractOpenCode(rows: [
        (sessionID: "s", partJSON: #"{"type":"tool","tool":"bash","state":{"input":{"command":"one"},"time":{"start":1736942460}}}"#),
        (sessionID: "s", partJSON: #"{"type":"tool","tool":"bash","state":{"input":{"command":"two"},"time":{"start":1736942460000}}}"#),
    ])
    #expect(events.map(\.command.rawValue) == ["one", "two"])
    #expect(events.allSatisfy { $0.occurredAt == Date(timeIntervalSince1970: 1_736_942_460) })
}

// MARK: - OpenCode test support

private enum TypedOpenCodeFixtureError: Error {
    case openFailed
    case execFailed
    case prepareFailed
    case insertFailed
}

private func extractOpenCode(rows: [(sessionID: String?, partJSON: String?)]) throws -> [ExtractedEvent] {
    var events: [ExtractedEvent] = []
    try withTempHome { homeURL in
        let dbURL = homeURL.appendingPathComponent("opencode.db")
        try writeTypedOpenCodeDatabase(at: dbURL, rows: rows)
        events = try OpenCodeStoreAdapter().extract(fileURL: dbURL, data: Data(contentsOf: dbURL))
        #expect(events.allSatisfy { $0.sourcePath == dbURL.path })
    }
    return events
}

private func writeTypedOpenCodeDatabase(
    at url: URL,
    rows: [(sessionID: String?, partJSON: String?)]
) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
        throw TypedOpenCodeFixtureError.openFailed
    }
    defer { sqlite3_close(db) }

    let ddl = """
    CREATE TABLE part (
      id TEXT PRIMARY KEY,
      message_id TEXT,
      session_id TEXT,
      time_created INTEGER,
      time_updated INTEGER,
      data TEXT
    );
    """
    guard sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK else {
        throw TypedOpenCodeFixtureError.execFailed
    }

    let insert = "INSERT INTO part (id, message_id, session_id, data) VALUES (?, ?, ?, ?);"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw TypedOpenCodeFixtureError.prepareFailed
    }
    defer { sqlite3_finalize(statement) }

    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (index, row) in rows.enumerated() {
        _ = sqlite3_reset(statement)
        _ = sqlite3_clear_bindings(statement)
        _ = "part_\(index)".withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
        _ = "msg_\(index)".withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) }
        if let sessionID = row.sessionID {
            _ = sessionID.withCString { sqlite3_bind_text(statement, 3, $0, -1, transient) }
        } else {
            _ = sqlite3_bind_null(statement, 3)
        }
        if let partJSON = row.partJSON {
            _ = partJSON.withCString { sqlite3_bind_text(statement, 4, $0, -1, transient) }
        } else {
            _ = sqlite3_bind_null(statement, 4)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TypedOpenCodeFixtureError.insertFailed
        }
    }
}
