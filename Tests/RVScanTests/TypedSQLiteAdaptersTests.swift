import Foundation
#if canImport(SQLite3)
import SQLite3
#endif
import Testing
import RVDomain
@testable import RVScan

// MARK: - OpenClaw goldens

@Test func openClawTyped_fixtureGoldens() throws {
    let execJSON = try String(contentsOf: fixtureURL("openclaw/exec-tool-call.json"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let nestedJSON = try String(contentsOf: fixtureURL("openclaw/nested-message-exec.json"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let events = try extractTypedOpenClaw(rows: [
        (sessionID: "sess_fixture_1", eventJSON: execJSON, createdAt: 1_710_000_000),
        (sessionID: "sess_nested", eventJSON: nestedJSON, createdAt: 1_710_000_000),
    ])
    #expect(events.map(\.command.rawValue) == ["git reset --hard", "git status"])
    #expect(events.allSatisfy { $0.host == .openclaw })
    #expect(events.map(\.sessionID) == [SessionID(validating: "sess_fixture_1"), SessionID(validating: "sess_nested")])
    #expect(events.allSatisfy { $0.occurredAt == Date(timeIntervalSince1970: 1_710_000_000) })
    #expect(events.map { $0.workingDirectory?.rawValue } == ["/tmp/ws", "/tmp/nested"])
}

@Test func openClawTyped_skipsBadRowsWithoutAborting() throws {
    let events = try extractTypedOpenClaw(rows: [
        (sessionID: "s", eventJSON: #"{"name":"read","params":{"command":"dropped"}}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"name":"exec","params":{"command":""}}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"name":"exec","params":{}}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"name":"exec"}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"name":"exec","params":{"command":42}}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: "not-json", createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: "[1,2]", createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: "[{}]", createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: "42", createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: "null", createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: "\"just a string\"", createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: "{}", createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: nil, createdAt: 1_710_000_000),
        (sessionID: nil, eventJSON: #"{"name":"exec","arguments":{"command":"kept"}}"#, createdAt: 1_710_000_000),
    ])
    #expect(events.map(\.command.rawValue) == ["kept"])
    #expect(events[0].sessionID == nil)
    #expect(events[0].occurredAt == Date(timeIntervalSince1970: 1_710_000_000))
    #expect(events[0].workingDirectory == nil)
}

@Test func openClawTyped_wrongTypeScalarsKeepRow() throws {
    // Old per-field `as?` ignored mistyped scalars: a wrong-typed command or
    // carrier falls through to the next source, and a wrong-typed `name`
    // still falls back to `toolName`. String carriers are never re-parsed,
    // and a non-object element fails the whole `content` array.
    let events = try extractTypedOpenClaw(rows: [
        (sessionID: "s", eventJSON: #"{"name":"exec","arguments":{"command":42},"params":{"command":"one"}}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"name":42,"params":{"command":"dropped"}}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"name":42,"toolName":"exec","params":{"command":"two"}}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"name":"exec","arguments":42,"params":{"command":"three"}}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"name":"exec","arguments":"{\"command\":\"shadow\"}","params":{"command":"four"}}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"name":"exec","arguments":{"command":"five"},"params":42,"input":true,"cwd":42}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"name":"exec","params":{"command":"six"},"toolCall":"x","message":42}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"toolCall":"x","message":42}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"message":{"content":[{"name":"exec","params":{"command":"dropped"}},42]}}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"message":{"content":[{"name":"exec","params":{"command":"seven"}}]}}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"message":{"content":"nope"}}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"message":42,"name":"exec","params":{"command":"eight"}}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"name":"exec","arguments":42,"params":{"command":42},"input":{"command":"nine"}}"#, createdAt: 1_710_000_000),
    ])
    #expect(events.map(\.command.rawValue) == ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"])
    #expect(events.allSatisfy { $0.occurredAt == Date(timeIntervalSince1970: 1_710_000_000) })
    #expect(events.allSatisfy { $0.workingDirectory == nil })
}

@Test func openClawTyped_toolCallAndMessageRouting() throws {
    // Envelope match wins over `toolCall`; `toolCall` cwd wins over envelope
    // cwd; content scans in order with one shell per row at most.
    let events = try extractTypedOpenClaw(rows: [
        (sessionID: "s", eventJSON: #"{"name":"exec","params":{"command":"envelope"},"toolCall":{"name":"exec","params":{"command":"shadow"}}}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"cwd":"/tmp/env","toolCall":{"name":"exec","cwd":"/tmp/tool","input":{"command":"via-tool"}}}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"cwd":"/tmp/env","toolCall":{"name":"exec","input":{"command":"via-tool-2"}}}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"message":{"content":[{"name":"exec","params":{"command":"first"}},{"name":"exec","params":{"command":"second"}}]}}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"message":{"content":[{"toolCall":{"name":"exec","arguments":{"command":"deep"}}}]}}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"toolCall":{"toolName":"exec","params":{"command":"toolname"}}}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"toolCall":{"name":"exec","params":{"command":"via-tool-wins"}},"message":{"content":[{"name":"exec","params":{"command":"shadow"}}]}}"#, createdAt: 1_710_000_000),
    ])
    #expect(events.map(\.command.rawValue) == ["envelope", "via-tool", "via-tool-2", "first", "deep", "toolname", "via-tool-wins"])
    #expect(events.map { $0.workingDirectory?.rawValue } == [nil, "/tmp/tool", "/tmp/env", nil, nil, nil, nil])
}

@Test func openClawTyped_workingDirectoryPriority() throws {
    // Cwd follows the old crawl's probe order (params, input, arguments,
    // envelope) — not command-fallthrough order. A content-item match reads
    // the item subtree only, never the outer envelope.
    let events = try extractTypedOpenClaw(rows: [
        (sessionID: "s", eventJSON: #"{"name":"exec","cwd":"/tmp/env","arguments":{"cwd":"/tmp/args"},"input":{"cwd":"/tmp/input"},"params":{"command":"x","cwd":"/tmp/params"}}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"name":"exec","arguments":{"cwd":"/tmp/args"},"input":{"command":"x","cwd":"/tmp/input"}}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"name":"exec","cwd":"/tmp/env","arguments":{"command":"x","cwd":"/tmp/args"}}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"name":"exec","working_directory":"/tmp/env","params":{"command":"x"}}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"cwd":"/tmp/outer","message":{"content":[{"name":"exec","params":{"command":"x"}}]}}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"cwd":"/tmp/outer","message":{"content":[{"name":"exec","cwd":"/tmp/item","params":{"command":"x"}}]}}"#, createdAt: 1_710_000_000),
    ])
    #expect(events.map(\.command.rawValue) == ["x", "x", "x", "x", "x", "x"])
    #expect(events.map { $0.workingDirectory?.rawValue } == ["/tmp/params", "/tmp/input", "/tmp/args", "/tmp/env", nil, "/tmp/item"])
}

@Test func openClawTyped_createdAtSecondsAndMillis() throws {
    let events = try extractTypedOpenClaw(rows: [
        (sessionID: "s", eventJSON: #"{"name":"exec","params":{"command":"one"}}"#, createdAt: 1_710_000_000),
        (sessionID: "s", eventJSON: #"{"name":"exec","params":{"command":"two"}}"#, createdAt: 1_710_000_000_000),
        (sessionID: "s", eventJSON: #"{"name":"exec","params":{"command":"three"}}"#, createdAt: 0),
        (sessionID: "s", eventJSON: #"{"name":"exec","params":{"command":"four"}}"#, createdAt: -5),
    ])
    #expect(events.map(\.command.rawValue) == ["one", "two", "three", "four"])
    #expect(events[0].occurredAt == Date(timeIntervalSince1970: 1_710_000_000))
    #expect(events[1].occurredAt == Date(timeIntervalSince1970: 1_710_000_000))
    #expect(events[2].occurredAt == nil)
    #expect(events[3].occurredAt == nil)
}

// MARK: - Hermes goldens

@Test func hermesTyped_fixtureGoldens() throws {
    // Note the swapped-looking fixtures: terminal-tool-call.json carries a
    // JSON-string `function.arguments`, while nested-function-terminal.json is
    // a direct object call.
    let terminalJSON = try String(contentsOf: fixtureURL("hermes/terminal-tool-call.json"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let nestedJSON = try String(contentsOf: fixtureURL("hermes/nested-function-terminal.json"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let events = try extractTypedHermes(rows: [
        (sessionID: "sess_fixture_1", toolCalls: terminalJSON, timestamp: 1_710_000_000),
        (sessionID: "sess_nested", toolCalls: nestedJSON, timestamp: 1_710_000_000),
    ])
    #expect(events.map(\.command.rawValue) == ["git reset --hard", "git status"])
    #expect(events.allSatisfy { $0.host == .hermes })
    #expect(events.map(\.sessionID) == [SessionID(validating: "sess_fixture_1"), SessionID(validating: "sess_nested")])
    #expect(events.allSatisfy { $0.occurredAt == Date(timeIntervalSince1970: 1_710_000_000) })
    #expect(events.map { $0.workingDirectory?.rawValue } == ["/tmp/ws", "/tmp/ws"])
}

@Test func hermesTyped_skipsBadRowsWithoutAborting() throws {
    // A payload is a list of calls or a single call; a non-object element
    // fails a list payload entirely.
    let events = try extractTypedHermes(rows: [
        (sessionID: "s", toolCalls: #"[{"name":"shell","arguments":{"command":"dropped"}}]"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"[{"name":"terminal","arguments":{"command":""}}]"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"[{"name":"terminal","arguments":{}}]"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"[{"name":"terminal"}]"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"[{"name":"terminal","arguments":{"command":42}}]"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: "not-json", timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: "[1,2]", timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: "42", timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: "\"x\"", timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: "null", timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: "[{}]", timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: "{}", timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: "[null]", timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"[{"name":"terminal","arguments":{"command":"dropped"}},42]"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: nil, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"{"name":"terminal","arguments":{"command":"single"}}"#, timestamp: 1_710_000_000),
        (sessionID: nil, toolCalls: #"[{"name":"terminal","arguments":{"command":"kept"}}]"#, timestamp: 1_710_000_000),
    ])
    #expect(events.map(\.command.rawValue) == ["single", "kept"])
    #expect(events[0].sessionID == SessionID(validating: "s"))
    #expect(events[1].sessionID == nil)
    #expect(events.allSatisfy { $0.occurredAt == Date(timeIntervalSince1970: 1_710_000_000) })
}

@Test func hermesTyped_wrongTypeScalarsKeepRow() throws {
    // Old per-field `as?` ignored mistyped scalars: a wrong-typed command or
    // carrier falls through to the next source, and a wrong-typed `name`
    // still falls back to `toolName` or the function branch.
    let events = try extractTypedHermes(rows: [
        (sessionID: "s", toolCalls: #"[{"name":"terminal","arguments":{"command":42},"params":{"command":"one"}}]"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"[{"name":42,"params":{"command":"dropped"}}]"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"[{"name":42,"toolName":"terminal","params":{"command":"two"}}]"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"[{"name":"terminal","arguments":42,"params":{"command":"three"}}]"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"[{"name":"terminal","arguments":true,"input":{"command":"four"}}]"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"[{"name":"terminal","arguments":null,"params":{"command":"five"}}]"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"[{"name":"terminal","arguments":[{"command":"dropped"}],"params":{"command":"six"}}]"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"[{"name":"terminal","function":42,"arguments":{"command":"seven"}}]"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"[{"name":42,"function":{"name":"terminal","arguments":{"command":"eight"}}}]"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"[{"function":{"name":42,"arguments":{"command":"dropped"}}}]"#, timestamp: 1_710_000_000),
    ])
    #expect(events.map(\.command.rawValue) == ["one", "two", "three", "four", "five", "six", "seven", "eight"])
    #expect(events.allSatisfy { $0.occurredAt == Date(timeIntervalSince1970: 1_710_000_000) })
    #expect(events.allSatisfy { $0.workingDirectory == nil })
}

@Test func hermesTyped_functionRouting() throws {
    // A `terminal` function reads its own arguments, then params, then the
    // OUTER arguments — never the outer params/input, and never
    // `function.input`. A direct `terminal` name shadows the function branch.
    let events = try extractTypedHermes(rows: [
        (sessionID: "s", toolCalls: #"{"function":{"name":"terminal","params":{"command":"fn-params"}},"arguments":{"command":"outer-args"}}"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"{"function":{"name":"terminal"},"arguments":{"command":"outer-args"}}"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"{"name":"other","function":{"name":"terminal"},"params":{"command":"nope"}}"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"{"name":"other","function":{"name":"terminal"},"input":{"command":"nope"}}"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"{"function":{"name":"terminal","input":{"command":"nope"}},"arguments":{"command":"outer-args-2"}}"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"{"name":"terminal","arguments":{"command":"direct"},"function":{"name":"terminal","arguments":{"command":"shadow"}}}"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"{"function":{"toolName":"terminal","arguments":{"command":"fn-toolname"}}}"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"{"function":{"name":"terminal","arguments":{"command":""}},"arguments":{"command":"fallthrough"}}"#, timestamp: 1_710_000_000),
    ])
    #expect(events.map(\.command.rawValue) == ["fn-params", "outer-args", "outer-args-2", "direct", "fn-toolname", "fallthrough"])
}

@Test func hermesTyped_stringCarriers() throws {
    // Unlike OpenClaw, string carriers re-parse as JSON for both command and
    // cwd; a string that is not a JSON object is inert and falls through.
    let events = try extractTypedHermes(rows: [
        (sessionID: "s", toolCalls: #"{"name":"terminal","arguments":"{\"command\":\"s-args\",\"workdir\":\"/tmp/sa\"}"}"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"{"name":"terminal","params":"{\"command\":\"s-params\"}"}"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"{"name":"terminal","input":"{\"command\":\"s-input\"}"}"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"{"function":{"name":"terminal","params":"{\"command\":\"s-fn-params\"}"}}"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"{"name":"terminal","arguments":"not json"}"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"{"name":"terminal","arguments":"[1,2]"}"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"{"name":"terminal","arguments":"42"}"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"{"name":"terminal","arguments":"\"plain\""}"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"{"name":"terminal","arguments":"","params":{"command":"after-empty"}}"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"{"name":"terminal","arguments":"{\"command\":\"\"}","params":{"command":"after-empty-cmd"}}"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"{"name":"terminal","arguments":"{\"command\":42}","params":{"command":"after-wrong-cmd"}}"#, timestamp: 1_710_000_000),
    ])
    #expect(events.map(\.command.rawValue) == ["s-args", "s-params", "s-input", "s-fn-params", "after-empty", "after-empty-cmd", "after-wrong-cmd"])
    #expect(events[0].workingDirectory?.rawValue == "/tmp/sa")
    #expect(events[1...].allSatisfy { $0.workingDirectory == nil })
}

@Test func hermesTyped_workingDirectoryPriority() throws {
    // Cwd follows the old crawl's probe order (params, input, arguments,
    // function subtree, envelope) — not command-fallthrough order.
    let events = try extractTypedHermes(rows: [
        (sessionID: "s", toolCalls: #"{"name":"terminal","cwd":"/tmp/env","arguments":{"command":"x","cwd":"/tmp/args"},"input":{"cwd":"/tmp/input"},"params":{"cwd":"/tmp/params"},"function":{"name":"other","cwd":"/tmp/fn"}}"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"{"name":"terminal","arguments":{"command":"x","cwd":"/tmp/args"},"input":{"cwd":"/tmp/input"}}"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"{"name":"terminal","cwd":"/tmp/env","arguments":{"command":"x","cwd":"/tmp/args"},"function":{"name":"other","cwd":"/tmp/fn"}}"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"{"name":"terminal","cwd":"/tmp/env","arguments":{"command":"x"},"function":{"name":"other","cwd":"/tmp/fn"}}"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"{"name":"terminal","workingDirectory":"/tmp/env","arguments":{"command":"x"}}"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"{"name":"terminal","arguments":{"command":"x"},"function":{"name":"terminal","cwd":"/tmp/fn-env","arguments":{"cwd":"/tmp/fn-args"},"params":{"cwd":"/tmp/fn-params"}}}"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"{"name":"terminal","arguments":{"command":"x"},"function":{"name":"terminal","arguments":{"cwd":"/tmp/fn-args"}}}"#, timestamp: 1_710_000_000),
    ])
    #expect(events.map(\.command.rawValue) == ["x", "x", "x", "x", "x", "x", "x"])
    #expect(events.map { $0.workingDirectory?.rawValue } == ["/tmp/params", "/tmp/input", "/tmp/args", "/tmp/fn", "/tmp/env", "/tmp/fn-params", "/tmp/fn-args"])
}

@Test func hermesTyped_multiCallRow() throws {
    // One row yields one event per terminal call; sibling calls extract
    // independently (unlike OpenClaw's one-shell-per-row).
    let events = try extractTypedHermes(rows: [
        (sessionID: "sess_multi", toolCalls: #"[{"name":"terminal","arguments":{"command":"one"}},{"name":"other"},{"name":"terminal","params":{"command":"two"},"cwd":"/tmp/c2"}]"#, timestamp: 1_710_000_000),
    ])
    #expect(events.map(\.command.rawValue) == ["one", "two"])
    #expect(events.allSatisfy { $0.sessionID == SessionID(validating: "sess_multi") })
    #expect(events.map { $0.workingDirectory?.rawValue } == [nil, "/tmp/c2"])
}

@Test func hermesTyped_timestampSecondsAndMillis() throws {
    let events = try extractTypedHermes(rows: [
        (sessionID: "s", toolCalls: #"{"name":"terminal","arguments":{"command":"one"}}"#, timestamp: 1_710_000_000),
        (sessionID: "s", toolCalls: #"{"name":"terminal","arguments":{"command":"two"}}"#, timestamp: 1_710_000_000_000),
        (sessionID: "s", toolCalls: #"{"name":"terminal","arguments":{"command":"three"}}"#, timestamp: 0),
        (sessionID: "s", toolCalls: #"{"name":"terminal","arguments":{"command":"four"}}"#, timestamp: -5),
    ])
    #expect(events.map(\.command.rawValue) == ["one", "two", "three", "four"])
    #expect(events[0].occurredAt == Date(timeIntervalSince1970: 1_710_000_000))
    #expect(events[1].occurredAt == Date(timeIntervalSince1970: 1_710_000_000))
    #expect(events[2].occurredAt == nil)
    #expect(events[3].occurredAt == nil)
}

// MARK: - SQLite test support

private enum TypedSQLiteAdaptersFixtureError: Error {
    case openFailed
    case execFailed
    case prepareFailed
    case insertFailed
}

private func extractTypedOpenClaw(rows: [(sessionID: String?, eventJSON: String?, createdAt: Int64)]) throws -> [ExtractedEvent] {
    var events: [ExtractedEvent] = []
    try withTempHome { homeURL in
        let dbURL = homeURL.appendingPathComponent("openclaw-agent.sqlite")
        try writeTypedOpenClawDatabase(at: dbURL, rows: rows)
        events = try OpenClawStoreAdapter().extract(fileURL: dbURL, data: Data(contentsOf: dbURL))
        #expect(events.allSatisfy { $0.sourcePath == dbURL.path })
    }
    return events
}

private func extractTypedHermes(rows: [(sessionID: String?, toolCalls: String?, timestamp: Double)]) throws -> [ExtractedEvent] {
    var events: [ExtractedEvent] = []
    try withTempHome { homeURL in
        let dbURL = homeURL.appendingPathComponent("state.db")
        try writeTypedHermesDatabase(at: dbURL, rows: rows)
        events = try HermesStoreAdapter().extract(fileURL: dbURL, data: Data(contentsOf: dbURL))
        #expect(events.allSatisfy { $0.sourcePath == dbURL.path })
    }
    return events
}

private func writeTypedOpenClawDatabase(
    at url: URL,
    rows: [(sessionID: String?, eventJSON: String?, createdAt: Int64)]
) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
        throw TypedSQLiteAdaptersFixtureError.openFailed
    }
    defer { sqlite3_close(db) }

    let ddl = """
    CREATE TABLE transcript_events (
      session_id TEXT,
      seq INTEGER,
      event_json TEXT,
      created_at INTEGER
    );
    """
    guard sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK else {
        throw TypedSQLiteAdaptersFixtureError.execFailed
    }

    let insert = "INSERT INTO transcript_events (session_id, seq, event_json, created_at) VALUES (?, 1, ?, ?);"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw TypedSQLiteAdaptersFixtureError.prepareFailed
    }
    defer { sqlite3_finalize(statement) }

    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for row in rows {
        _ = sqlite3_reset(statement)
        _ = sqlite3_clear_bindings(statement)
        if let sessionID = row.sessionID {
            _ = sessionID.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
        } else {
            _ = sqlite3_bind_null(statement, 1)
        }
        if let eventJSON = row.eventJSON {
            _ = eventJSON.withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) }
        } else {
            _ = sqlite3_bind_null(statement, 2)
        }
        _ = sqlite3_bind_int64(statement, 3, row.createdAt)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TypedSQLiteAdaptersFixtureError.insertFailed
        }
    }
}

private func writeTypedHermesDatabase(
    at url: URL,
    rows: [(sessionID: String?, toolCalls: String?, timestamp: Double)]
) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
        throw TypedSQLiteAdaptersFixtureError.openFailed
    }
    defer { sqlite3_close(db) }

    let ddl = """
    CREATE TABLE messages (
      session_id TEXT,
      role TEXT,
      content TEXT,
      tool_calls TEXT,
      timestamp REAL
    );
    """
    guard sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK else {
        throw TypedSQLiteAdaptersFixtureError.execFailed
    }

    let insert = "INSERT INTO messages (session_id, role, content, tool_calls, timestamp) VALUES (?, 'assistant', NULL, ?, ?);"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw TypedSQLiteAdaptersFixtureError.prepareFailed
    }
    defer { sqlite3_finalize(statement) }

    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for row in rows {
        _ = sqlite3_reset(statement)
        _ = sqlite3_clear_bindings(statement)
        if let sessionID = row.sessionID {
            _ = sessionID.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
        } else {
            _ = sqlite3_bind_null(statement, 1)
        }
        if let toolCalls = row.toolCalls {
            _ = toolCalls.withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) }
        } else {
            _ = sqlite3_bind_null(statement, 2)
        }
        _ = sqlite3_bind_double(statement, 3, row.timestamp)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TypedSQLiteAdaptersFixtureError.insertFailed
        }
    }
}
