import Foundation
#if canImport(SQLite3)
import SQLite3
#endif
import Testing
import RVDomain
@testable import RVScan

// Byte-identical prover for the T1 scan-engine consolidation.
//
// `Tests/RVScanTests/Fixtures/scan-golden.json` was captured from the
// pre-consolidation adapters. This test re-extracts every checked-in fixture
// (plus error and best-effort edge inputs) and requires the full event fields
// to match the golden exactly.
//
// To regenerate (only when extraction semantics intentionally change):
//   RV_SCAN_GOLDEN_DUMP=/tmp/scan-golden.json swift test --filter ScanGoldenTests

private struct GoldenEvent: Codable, Equatable {
    var host: String
    var session: String?
    var at: Double?
    var command: String
    var cwd: String?

    init(_ event: ExtractedEvent) {
        host = event.host.rawValue
        session = event.sessionID?.rawValue
        at = event.occurredAt?.timeIntervalSince1970
        command = event.command.rawValue
        cwd = event.workingDirectory?.rawValue
    }
}

private struct GoldenCase: Codable, Equatable {
    var label: String
    var events: [GoldenEvent]
    var thrown: String?
}

private func goldenExtract(
    label: String,
    adapter: any SessionStoreAdapter,
    fileURL: URL,
    data: Data
) -> GoldenCase {
    do {
        let events = try adapter.extract(fileURL: fileURL, data: data)
        return GoldenCase(label: label, events: events.map(GoldenEvent.init), thrown: nil)
    } catch {
        // Normalize the temp SQLite parent dir (random UUID) for determinism.
        let raw = String(describing: error)
        let parent = fileURL.deletingLastPathComponent().path
        let normalized = raw.replacingOccurrences(of: parent, with: "<tmp>")
        return GoldenCase(label: label, events: [], thrown: normalized)
    }
}

private func goldenFixtureCases() throws -> [GoldenCase] {
    var cases: [GoldenCase] = []

    let claude = ClaudeSessionStoreAdapter()
    for name in ["ac001-reset-hard.jsonl", "allow-status.jsonl"] {
        let url = try fixtureURL("claude/projects/-tmp-rv-scan-fixture/\(name)")
        cases.append(
            goldenExtract(
                label: "claude/\(name)",
                adapter: claude,
                fileURL: url,
                data: try Data(contentsOf: url)
            )
        )
    }
    // Best-effort edges: non-UTF8 bytes and unrecognized extensions yield no
    // events (never throw) on the lenient adapters.
    let claudeData = try Data(contentsOf: fixtureURL("claude/projects/-tmp-rv-scan-fixture/ac001-reset-hard.jsonl"))
    cases.append(
        goldenExtract(
            label: "claude/non-utf8",
            adapter: claude,
            fileURL: URL(fileURLWithPath: "/tmp/golden-claude.jsonl"),
            data: Data([0xFF, 0xFE, 0x0A])
        )
    )
    cases.append(
        goldenExtract(
            label: "claude/unrecognized-ext",
            adapter: claude,
            fileURL: URL(fileURLWithPath: "/tmp/golden-claude-noise.txt"),
            data: claudeData
        )
    )

    let codex = CodexStoreAdapter()
    for name in ["bash-function-call.jsonl", "pretool-bash.jsonl"] {
        let url = try fixtureURL("codex/\(name)")
        cases.append(
            goldenExtract(
                label: "codex/\(name)",
                adapter: codex,
                fileURL: url,
                data: try Data(contentsOf: url)
            )
        )
    }
    let codexSource = URL(fileURLWithPath: "/tmp/golden-codex.jsonl")
    cases.append(goldenExtract(label: "codex/empty", adapter: codex, fileURL: codexSource, data: Data()))
    cases.append(
        goldenExtract(label: "codex/non-utf8", adapter: codex, fileURL: codexSource, data: Data([0xFF, 0xFE]))
    )
    cases.append(
        goldenExtract(label: "codex/not-json", adapter: codex, fileURL: codexSource, data: Data("not-json\n".utf8))
    )
    // The checked-in codex fixtures carry no timestamp/ts keys, so the
    // riskiest coercion (NSNumber-first epoch, ts fallback, millis divide)
    // pins here instead. Expected `at` values verified against python3
    // datetime, not against the code under test.
    let codexTimestamps = """
        {"session_id":"sess_ts","type":"function_call","name":"shell","arguments":{"command":"echo iso"},"cwd":"/tmp/ws","timestamp":"2024-03-01T12:00:00Z"}
        {"session_id":"sess_ts","type":"function_call","name":"shell","arguments":{"command":"echo secs"},"cwd":"/tmp/ws","timestamp":1709294460}
        {"session_id":"sess_ts","type":"function_call","name":"shell","arguments":{"command":"echo millis"},"cwd":"/tmp/ws","ts":1709294520123}
        """
    cases.append(
        goldenExtract(
            label: "codex/timestamps",
            adapter: codex,
            fileURL: codexSource,
            data: Data(codexTimestamps.utf8)
        )
    )

    let cursor = CursorStoreAdapter()
    for name in ["before-shell.jsonl", "pretool-shell.jsonl"] {
        let url = try fixtureURL("cursor/\(name)")
        cases.append(
            goldenExtract(
                label: "cursor/\(name)",
                adapter: cursor,
                fileURL: url,
                data: try Data(contentsOf: url)
            )
        )
    }
    let cursorSource = URL(fileURLWithPath: "/tmp/golden-cursor.jsonl")
    cases.append(goldenExtract(label: "cursor/empty", adapter: cursor, fileURL: cursorSource, data: Data()))
    cases.append(
        goldenExtract(label: "cursor/non-utf8", adapter: cursor, fileURL: cursorSource, data: Data([0xFF, 0xFE]))
    )
    cases.append(
        goldenExtract(label: "cursor/not-json", adapter: cursor, fileURL: cursorSource, data: Data("not-json\n".utf8))
    )
    // Cursor ignores epoch numbers (allowEpoch:false) but keeps ISO strings.
    let cursorTimestamps = """
        {"conversation_id":"sess_cursor_ts","hook_event_name":"beforeShellExecution","command":"echo num","cwd":"/tmp/ws","timestamp":1709294400}
        {"conversation_id":"sess_cursor_ts","hook_event_name":"beforeShellExecution","command":"echo iso","cwd":"/tmp/ws","timestamp":"2024-03-01T12:00:00Z"}
        """
    cases.append(
        goldenExtract(
            label: "cursor/numeric-timestamp-ignored",
            adapter: cursor,
            fileURL: cursorSource,
            data: Data(cursorTimestamps.utf8)
        )
    )

    let grok = GrokStoreAdapter()
    let grokData = try Data(contentsOf: fixtureURL("grok/chat_history.jsonl"))
    let grokURLs = [
        "grok/plain": URL(fileURLWithPath: "/tmp/sess-grok-1/chat_history.jsonl"),
        "grok/encoded-layout": URL(fileURLWithPath: "/tmp/rv-scan-grok-home")
            .appendingPathComponent(".grok/sessions/%2Ftmp%2Frv-ws/sess-enc/chat_history.jsonl"),
        "grok/relative-slug": URL(fileURLWithPath: "/tmp/rv-scan-grok-home")
            .appendingPathComponent(".grok/sessions/my-project/sess-rel/chat_history.jsonl"),
    ]
    for (label, url) in grokURLs.sorted(by: { $0.key < $1.key }) {
        cases.append(goldenExtract(label: label, adapter: grok, fileURL: url, data: grokData))
    }
    cases.append(
        goldenExtract(
            label: "grok/non-utf8",
            adapter: grok,
            fileURL: URL(fileURLWithPath: "/tmp/sess-grok-1/chat_history.jsonl"),
            data: Data([0xFF, 0xFE])
        )
    )

    let pi = PiStoreAdapter()
    let piURL = try fixtureURL("pi/session.jsonl")
    cases.append(
        goldenExtract(label: "pi/session", adapter: pi, fileURL: piURL, data: try Data(contentsOf: piURL))
    )
    cases.append(
        goldenExtract(
            label: "pi/non-utf8",
            adapter: pi,
            fileURL: URL(fileURLWithPath: "/tmp/golden-pi.jsonl"),
            data: Data([0xFF, 0xFE])
        )
    )
    // The session fixture's envelope ISO strings shadow every numeric path,
    // so Pi's numeric coercion (envelope millis, message millis fallback,
    // JSON-bool bridging) pins here. The envelope millis deliberately
    // disagrees with the message ISO to pin precedence too.
    let piNumeric = """
        {"type":"session","id":"pi-sess-numeric","cwd":"/tmp/pi-num"}
        {"type":"message","timestamp":1709294400000,"message":{"role":"assistant","content":[{"type":"toolCall","name":"bash","arguments":{"command":"echo envelope"}}],"timestamp":"2024-01-01T00:00:00Z"}}
        {"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","name":"bash","arguments":{"command":"echo fallback"}}],"timestamp":1709294460000}}
        {"type":"message","timestamp":true,"message":{"role":"assistant","content":[{"type":"toolCall","name":"bash","arguments":{"command":"echo bool-true"}}]}}
        {"type":"message","timestamp":false,"message":{"role":"assistant","content":[{"type":"toolCall","name":"bash","arguments":{"command":"echo bool-false"}}]}}
        """
    cases.append(
        goldenExtract(
            label: "pi/numeric-timestamps",
            adapter: pi,
            fileURL: URL(fileURLWithPath: "/tmp/golden-pi.jsonl"),
            data: Data(piNumeric.utf8)
        )
    )

    cases.append(contentsOf: try goldenHermesCases())
    cases.append(contentsOf: try goldenOpenClawCases())
    cases.append(contentsOf: try goldenOpenCodeCases())
    return cases
}

private func goldenEncode(_ cases: [GoldenCase]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    return try encoder.encode(cases)
}

@Test func scanGolden_extractionMatchesCommittedGolden() throws {
    let live = try goldenFixtureCases()
    if let dumpPath = ProcessInfo.processInfo.environment["RV_SCAN_GOLDEN_DUMP"], dumpPath.isEmpty == false {
        try goldenEncode(live).write(to: URL(fileURLWithPath: dumpPath), options: .atomic)
        return
    }
    let goldenURL = try fixtureURL("scan-golden.json")
    let expected = try JSONDecoder().decode([GoldenCase].self, from: Data(contentsOf: goldenURL))
    #expect(live == expected)
}

// MARK: - SQLite golden builders (temp DBs, paths normalized out of the golden)

private enum GoldenSQLiteError: Error {
    case openFailed
    case execFailed
    case prepareFailed
    case insertFailed
}

private func goldenSQLiteDB(at url: URL, ddl: String, insert: String, bindings: [String]) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
        throw GoldenSQLiteError.openFailed
    }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK else {
        throw GoldenSQLiteError.execFailed
    }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw GoldenSQLiteError.prepareFailed
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (index, value) in bindings.enumerated() {
        _ = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, transient) }
    }
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw GoldenSQLiteError.insertFailed
    }
}

private let goldenHermesDDL = """
CREATE TABLE messages (
  session_id TEXT,
  role TEXT,
  content TEXT,
  tool_calls TEXT,
  timestamp REAL
);
"""

private func goldenHermesCases() throws -> [GoldenCase] {
    let adapter = HermesStoreAdapter()
    var cases: [GoldenCase] = []
    try withTempHome { homeURL in
        for (label, fixture, session) in [
            ("hermes/terminal-tool-call", "hermes/terminal-tool-call.json", "sess_fixture_1"),
            ("hermes/nested-function-terminal", "hermes/nested-function-terminal.json", "sess_nested"),
        ] as [(String, String, String)] {
            let dbURL = homeURL.appendingPathComponent("\(session).db")
            let toolCalls = try String(contentsOf: fixtureURL(fixture), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try goldenSQLiteDB(
                at: dbURL,
                ddl: goldenHermesDDL,
                insert: "INSERT INTO messages (session_id, role, content, tool_calls, timestamp) VALUES (?, 'assistant', NULL, ?, 1710000000.0);",
                bindings: [session, toolCalls]
            )
            cases.append(
                goldenExtract(label: label, adapter: adapter, fileURL: dbURL, data: try Data(contentsOf: dbURL))
            )
        }
        // The seconds rows above never cross the >1e12 millis threshold.
        let millisURL = homeURL.appendingPathComponent("sess_millis.db")
        let millisCalls = try String(contentsOf: fixtureURL("hermes/terminal-tool-call.json"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try goldenSQLiteDB(
            at: millisURL,
            ddl: goldenHermesDDL,
            insert: "INSERT INTO messages (session_id, role, content, tool_calls, timestamp) VALUES (?, 'assistant', NULL, ?, 1710000000123.0);",
            bindings: ["sess_millis", millisCalls]
        )
        cases.append(
            goldenExtract(label: "hermes/millis-timestamp", adapter: adapter, fileURL: millisURL, data: try Data(contentsOf: millisURL))
        )
        let source = homeURL.appendingPathComponent("state.db")
        cases.append(goldenExtract(label: "hermes/empty", adapter: adapter, fileURL: source, data: Data()))
        cases.append(
            goldenExtract(label: "hermes/not-db", adapter: adapter, fileURL: source, data: Data("not-a-database".utf8))
        )
        let noMessages = homeURL.appendingPathComponent("no-messages.db")
        var db: OpaquePointer?
        guard sqlite3_open(noMessages.path, &db) == SQLITE_OK, let db else {
            throw GoldenSQLiteError.openFailed
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "CREATE TABLE other (id TEXT);", nil, nil, nil) == SQLITE_OK else {
            throw GoldenSQLiteError.execFailed
        }
        cases.append(
            goldenExtract(
                label: "hermes/no-messages-table",
                adapter: adapter,
                fileURL: noMessages,
                data: try Data(contentsOf: noMessages)
            )
        )
    }
    return cases
}

private let goldenOpenClawDDL = """
CREATE TABLE transcript_events (
  session_id TEXT,
  seq INTEGER,
  event_json TEXT,
  created_at INTEGER
);
"""

private func goldenOpenClawCases() throws -> [GoldenCase] {
    let adapter = OpenClawStoreAdapter()
    var cases: [GoldenCase] = []
    try withTempHome { homeURL in
        for (label, fixture, session) in [
            ("openclaw/exec-tool-call", "openclaw/exec-tool-call.json", "sess_fixture_1"),
            ("openclaw/nested-message-exec", "openclaw/nested-message-exec.json", "sess_nested"),
        ] as [(String, String, String)] {
            let dbURL = homeURL.appendingPathComponent("\(session).db")
            let eventJSON = try String(contentsOf: fixtureURL(fixture), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try goldenSQLiteDB(
                at: dbURL,
                ddl: goldenOpenClawDDL,
                insert: "INSERT INTO transcript_events (session_id, seq, event_json, created_at) VALUES (?, 1, ?, 1);",
                bindings: [session, eventJSON]
            )
            cases.append(
                goldenExtract(label: label, adapter: adapter, fileURL: dbURL, data: try Data(contentsOf: dbURL))
            )
        }
        // created_at=1 above never crosses the >1e12 millis threshold.
        let millisURL = homeURL.appendingPathComponent("sess_millis.db")
        let millisEvent = try String(contentsOf: fixtureURL("openclaw/exec-tool-call.json"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try goldenSQLiteDB(
            at: millisURL,
            ddl: goldenOpenClawDDL,
            insert: "INSERT INTO transcript_events (session_id, seq, event_json, created_at) VALUES (?, 1, ?, 1710000000123);",
            bindings: ["sess_millis", millisEvent]
        )
        cases.append(
            goldenExtract(label: "openclaw/millis-created-at", adapter: adapter, fileURL: millisURL, data: try Data(contentsOf: millisURL))
        )
        let source = homeURL.appendingPathComponent("openclaw-agent.sqlite")
        cases.append(goldenExtract(label: "openclaw/empty", adapter: adapter, fileURL: source, data: Data()))
        cases.append(
            goldenExtract(label: "openclaw/not-db", adapter: adapter, fileURL: source, data: Data("not-a-database".utf8))
        )
        let noEvents = homeURL.appendingPathComponent("no-events.db")
        var db: OpaquePointer?
        guard sqlite3_open(noEvents.path, &db) == SQLITE_OK, let db else {
            throw GoldenSQLiteError.openFailed
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "CREATE TABLE other (id TEXT);", nil, nil, nil) == SQLITE_OK else {
            throw GoldenSQLiteError.execFailed
        }
        cases.append(
            goldenExtract(
                label: "openclaw/no-events-table",
                adapter: adapter,
                fileURL: noEvents,
                data: try Data(contentsOf: noEvents)
            )
        )
    }
    return cases
}

private let goldenOpenCodeDDL = """
CREATE TABLE part (
  id TEXT PRIMARY KEY,
  message_id TEXT,
  session_id TEXT,
  time_created INTEGER,
  time_updated INTEGER,
  data TEXT
);
"""

private func goldenOpenCodeCases() throws -> [GoldenCase] {
    let adapter = OpenCodeStoreAdapter()
    var cases: [GoldenCase] = []
    try withTempHome { homeURL in
        let dbURL = homeURL.appendingPathComponent("opencode.db")
        let partJSON = try String(contentsOf: fixtureURL("opencode/bash-part.json"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try goldenSQLiteDB(
            at: dbURL,
            ddl: goldenOpenCodeDDL,
            insert: "INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES ('part_1', 'msg_1', ?, 1, 1, ?);",
            bindings: ["ses_fixture_1", partJSON]
        )
        cases.append(
            goldenExtract(label: "opencode/bash-part", adapter: adapter, fileURL: dbURL, data: try Data(contentsOf: dbURL))
        )
        let source = homeURL.appendingPathComponent("opencode.db")
        cases.append(goldenExtract(label: "opencode/empty", adapter: adapter, fileURL: source, data: Data()))
        cases.append(
            goldenExtract(label: "opencode/not-db", adapter: adapter, fileURL: source, data: Data("not-a-database".utf8))
        )
        let noPart = homeURL.appendingPathComponent("no-part.db")
        var db: OpaquePointer?
        guard sqlite3_open(noPart.path, &db) == SQLITE_OK, let db else {
            throw GoldenSQLiteError.openFailed
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "CREATE TABLE other (id TEXT);", nil, nil, nil) == SQLITE_OK else {
            throw GoldenSQLiteError.execFailed
        }
        cases.append(
            goldenExtract(
                label: "opencode/no-part-table",
                adapter: adapter,
                fileURL: noPart,
                data: try Data(contentsOf: noPart)
            )
        )
        var image = Data("SQLite format 3\u{0}".utf8)
        image.append(Data(count: 512 - image.count))
        image[16] = 0
        image[17] = 0x03
        image[18] = 1
        image[19] = 1
        cases.append(goldenExtract(label: "opencode/bad-image", adapter: adapter, fileURL: source, data: image))
    }
    return cases
}
