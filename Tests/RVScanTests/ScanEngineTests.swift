import Foundation
#if canImport(SQLite3)
import SQLite3
#endif
import Testing
import RVDomain
@testable import RVScan

// Unit tests for the T1 shared extraction cores: line splitting, timestamps,
// session lookup, the fail-closed loop, the SQLite row runner, and the
// unified error type. Per-host shape matching stays covered by the existing
// adapter tests plus the byte-identical golden.

@Test func scanLines_byteSplit_skipsEmptyKeepsPerLineIndependence() {
    #expect(ScanJSONLEngine.byteLines(in: Data()).isEmpty)
    let lines = ScanJSONLEngine.byteLines(in: Data("a\n\nb\n".utf8))
    #expect(lines == [Data("a".utf8), Data("b".utf8)])
    // No trailing newline: final segment still returned.
    #expect(ScanJSONLEngine.byteLines(in: Data("a".utf8)) == [Data("a".utf8)])
    // Non-UTF-8 bytes survive as segments; the JSON parse rejects them
    // per line instead of poisoning the whole file.
    let mixed = Data([0xFF, 0x0A]) + Data("{\"k\":1}\n".utf8)
    let segments = ScanJSONLEngine.byteLines(in: mixed)
    #expect(segments.count == 2)
    #expect(ScanJSONLEngine.parseObject(segments[0]) == nil)
    #expect(ScanJSONLEngine.parseObject(segments[1])?["k"] as? Int == 1)
}

@Test func scanLines_textSplit_gatesOnWholeFileUTF8AndSkipsBlanks() {
    #expect(ScanJSONLEngine.textLines(in: Data([0xFF, 0xFE])) == nil)
    let lines = ScanJSONLEngine.textLines(in: Data("  \n{\"k\":1}  \n\t\n".utf8))
    #expect(lines == [Data("{\"k\":1}".utf8)])
    #expect(ScanJSONLEngine.textLines(in: Data()) == [])
}

@Test func scanLines_parseObject_rejectsScalarsAndMalformed() {
    #expect(ScanJSONLEngine.parseObject(Data("{\"a\":1}".utf8))?["a"] as? Int == 1)
    #expect(ScanJSONLEngine.parseObject(Data("not-json".utf8)) == nil)
    #expect(ScanJSONLEngine.parseObject(Data("null".utf8)) == nil)
    #expect(ScanJSONLEngine.parseObject(Data("[1,2]".utf8)) == nil)
}

@Test func scanSession_lookup_prefersFirstValidKey() {
    let object: [String: Any] = ["a": "", "b": "sess-b", "c": "sess-c"]
    #expect(ScanJSONLEngine.sessionID(keys: ["missing", "a", "b", "c"], in: object) == SessionID(validating: "sess-b"))
    #expect(ScanJSONLEngine.sessionID(keys: ["missing"], in: object) == nil)
    #expect(ScanJSONLEngine.sessionID(keys: [], in: object) == nil)
}

@Test func scanSession_deepLookup_descendsPayloadChains() {
    let object: [String: Any] = ["payload": ["payload": ["session_id": "deep"]]]
    #expect(
        ScanJSONLEngine.sessionIDDeep(keys: ["session_id", "sessionId"], recurse: ["payload"], in: object)
            == SessionID(validating: "deep")
    )
    let shallow: [String: Any] = ["sessionId": "top", "payload": ["session_id": "deep"]]
    #expect(
        ScanJSONLEngine.sessionIDDeep(keys: ["session_id", "sessionId"], recurse: ["payload"], in: shallow)
            == SessionID(validating: "top")
    )
    let none: [String: Any] = ["payload": ["other": 1]]
    #expect(ScanJSONLEngine.sessionIDDeep(keys: ["session_id"], recurse: ["payload"], in: none) == nil)
}

@Test func scanTimestamp_iso8601_fractionalPlainAndRejects() {
    #expect(ScanTimestamp.iso8601("2026-08-20T12:00:01.000Z") != nil)
    #expect(ScanTimestamp.iso8601("2026-08-27T00:00:00Z") != nil)
    #expect(
        ScanTimestamp.iso8601("2026-08-20T12:00:01.000Z")
            == ScanTimestamp.iso8601("2026-08-20T12:00:01Z")
    )
    #expect(ScanTimestamp.iso8601("") == nil)
    #expect(ScanTimestamp.iso8601("not-a-date") == nil)
}

@Test func scanTimestamp_epoch_secondsMillisAndPositivity() {
    #expect(ScanTimestamp.epoch(1_710_000_000) == Date(timeIntervalSince1970: 1_710_000_000))
    #expect(ScanTimestamp.epoch(1_736_942_460_000) == Date(timeIntervalSince1970: 1_736_942_460))
    // Strictly-greater threshold: exactly 1e12 stays seconds.
    #expect(ScanTimestamp.epoch(1_000_000_000_000) == Date(timeIntervalSince1970: 1_000_000_000_000))
    #expect(ScanTimestamp.epoch(0) == nil)
    #expect(ScanTimestamp.epoch(-5) == nil)
    #expect(ScanTimestamp.epoch(0, requirePositive: false) == Date(timeIntervalSince1970: 0))
    #expect(ScanTimestamp.epoch(-5, requirePositive: false) == Date(timeIntervalSince1970: -5))
}

@Test func scanTimestamp_epochValue_numbersAndJSONBooleansBridge() throws {
    let parsed = try #require(
        ScanJSONLEngine.parseObject(Data(#"{"i":1710000000,"f":1710000000.5,"s":"x","b":true,"c":false}"#.utf8))
    )
    #expect(ScanTimestamp.epochValue(parsed["i"]) == Date(timeIntervalSince1970: 1_710_000_000))
    #expect(ScanTimestamp.epochValue(parsed["f"]) == Date(timeIntervalSince1970: 1_710_000_000.5))
    #expect(ScanTimestamp.epochValue(parsed["s"]) == nil)
    #expect(ScanTimestamp.epochValue(nil) == nil)
    // Historical bridging preserved byte-identically: JSON booleans arrive as
    // NSNumber, and `as? NSNumber` converts true->1.0 / false->0.0 exactly as
    // the pre-T1 `as? NSNumber` (Pi) path did.
    #expect(ScanTimestamp.epochValue(parsed["b"]) == Date(timeIntervalSince1970: 1))
    #expect(ScanTimestamp.epochValue(parsed["c"]) == nil)
    #expect(ScanTimestamp.epochValue(parsed["c"], requirePositive: false) == Date(timeIntervalSince1970: 0))
}

@Test func scanTimestamp_epochValue_nativeScalarsBridgeLikeNSNumber() {
    // Pins the Pi `as? NSNumber` semantics for scalars without ObjC
    // bridging (Linux JSON, native Swift values): booleans map to 1/0 and
    // integers convert, exactly as `NSNumber.doubleValue` does.
    // `as? Double` alone yields nil for all of these.
    let nativeTrue: Any = true
    let nativeFalse: Any = false
    #expect(ScanTimestamp.epochValue(nativeTrue) == Date(timeIntervalSince1970: 1))
    #expect(ScanTimestamp.epochValue(nativeFalse) == nil)
    #expect(ScanTimestamp.epochValue(nativeFalse, requirePositive: false) == Date(timeIntervalSince1970: 0))
    let nativeInt: Any = 1_710_000_000
    #expect(ScanTimestamp.epochValue(nativeInt) == Date(timeIntervalSince1970: 1_710_000_000))
    let nativeInt64: Any = Int64(1_710_000_000)
    #expect(ScanTimestamp.epochValue(nativeInt64) == Date(timeIntervalSince1970: 1_710_000_000))
    let nativeUInt64: Any = UInt64(1_710_000_000)
    #expect(ScanTimestamp.epochValue(nativeUInt64) == Date(timeIntervalSince1970: 1_710_000_000))
    let nativeDouble: Any = 1_710_000_000.5
    #expect(ScanTimestamp.epochValue(nativeDouble) == Date(timeIntervalSince1970: 1_710_000_000.5))
    // Millis integers divide by 1000 (Pi message timestamps).
    let nativeMillis: Any = 1_736_942_460_000
    #expect(ScanTimestamp.epochValue(nativeMillis) == Date(timeIntervalSince1970: 1_736_942_460))
    // Strings and nil never convert.
    #expect(ScanTimestamp.epochValue("1710000000") == nil)
    #expect(ScanTimestamp.epochValue(nil) == nil)
}

@Test func scanTimestamp_firstValue_presentEmptyStringBlocksLaterKey() {
    // Matches `object["timestamp"] ?? object["ts"]`: presence wins, then
    // coercion yields nil rather than falling through.
    let object: [String: Any] = ["timestamp": "", "ts": "2026-08-27T00:00:00Z"]
    // Cast before requiring: `#require` on `Any?` is vacuous (the macro
    // type-erases the optional) and warns as redundant.
    let value = try? #require(ScanTimestamp.firstValue(keys: ["timestamp", "ts"], in: object) as? String)
    #expect(value == "")
    #expect(ScanTimestamp.coerce(value, allowEpoch: true) == nil)
    let missing: [String: Any] = [:]
    #expect(ScanTimestamp.firstValue(keys: ["timestamp", "ts"], in: missing) == nil)
}

@Test func scanTimestamp_coerce_stringVsNumberPaths() {
    #expect(ScanTimestamp.coerce("2026-08-27T00:00:00Z", allowEpoch: false) != nil)
    #expect(ScanTimestamp.coerce("garbage", allowEpoch: true) == nil)
    #expect(ScanTimestamp.coerce(NSNumber(value: 1_710_000_000), allowEpoch: true) != nil)
    #expect(ScanTimestamp.coerce(NSNumber(value: 1_710_000_000), allowEpoch: false) == nil)
}

@Test func scanFailClosed_emptyNonUTF8OrJSONLessThrows() {
    let source = "/tmp/engine-fail-closed.jsonl"
    let fallback = SessionID(validating: "fb")
    #expect(throws: ScanStoreError.unreadable(sourcePath: source)) {
        _ = try ScanJSONLEngine.extractFailClosed(
            host: .codex,
            data: Data(),
            sourcePath: source,
            fallbackSession: fallback,
            profile: ScanJSONLProfile(
                sessionKeys: ["session_id"],
                timestampKeys: ["timestamp"],
                allowEpochTimestamp: true,
                commands: { _ in [] }
            )
        )
    }
    #expect(throws: ScanStoreError.unreadable(sourcePath: source)) {
        _ = try ScanJSONLEngine.extractFailClosed(
            host: .codex,
            data: Data([0xFF, 0xFE]),
            sourcePath: source,
            fallbackSession: fallback,
            profile: ScanJSONLProfile(
                sessionKeys: ["session_id"],
                timestampKeys: ["timestamp"],
                allowEpochTimestamp: true,
                commands: { _ in [] }
            )
        )
    }
    #expect(throws: ScanStoreError.unreadable(sourcePath: source)) {
        _ = try ScanJSONLEngine.extractFailClosed(
            host: .codex,
            data: Data("not-json\n".utf8),
            sourcePath: source,
            fallbackSession: fallback,
            profile: ScanJSONLProfile(
                sessionKeys: ["session_id"],
                timestampKeys: ["timestamp"],
                allowEpochTimestamp: true,
                commands: { _ in [] }
            )
        )
    }
}

@Test func scanFailClosed_assemblesSessionTimestampCwdPerLine() throws {
    let payload = """
    {"session_id":"s1","timestamp":"2026-08-27T00:00:00Z","cwd":"/tmp/ws","tool_name":"Bash"}
    not-json
    {"session_id":"s2","ts":1710000000.0,"tool_name":"Bash"}
    """
    let events = try ScanJSONLEngine.extractFailClosed(
        host: .codex,
        data: Data(payload.utf8),
        sourcePath: "/tmp/engine.jsonl",
        fallbackSession: SessionID(validating: "fb"),
        profile: ScanJSONLProfile(
            sessionKeys: ["session_id", "sessionId"],
            timestampKeys: ["timestamp", "ts"],
            allowEpochTimestamp: true,
            commands: { _ in ["echo hi"] }
        )
    )
    #expect(events.count == 2)
    #expect(events[0].sessionID == SessionID(validating: "s1"))
    #expect(events[0].occurredAt == ScanTimestamp.iso8601("2026-08-27T00:00:00Z"))
    #expect(events[0].workingDirectory?.rawValue == "/tmp/ws")
    #expect(events[1].sessionID == SessionID(validating: "s2"))
    #expect(events[1].occurredAt == Date(timeIntervalSince1970: 1_710_000_000))
    #expect(events[1].workingDirectory == nil)
    #expect(events.allSatisfy { $0.host == .codex && $0.sourcePath == "/tmp/engine.jsonl" })
}

@Test func scanFailClosed_fallsBackToFileSession() throws {
    let events = try ScanJSONLEngine.extractFailClosed(
        host: .cursor,
        data: Data("{\"tool_name\":\"Shell\"}\n".utf8),
        sourcePath: "/tmp/engine-fb.jsonl",
        fallbackSession: SessionID(validating: "file-sess"),
        profile: ScanJSONLProfile(
            sessionKeys: ["conversation_id", "session_id", "sessionId"],
            timestampKeys: ["timestamp", "ts"],
            allowEpochTimestamp: false,
            commands: { _ in ["ls"] }
        )
    )
    #expect(events.count == 1)
    #expect(events[0].sessionID == SessionID(validating: "file-sess"))
    #expect(events[0].occurredAt == nil)
}

@Test func scanStoreError_unifiesHistoricalPerHostEnums() {
    // The compatibility aliases are the same type and cases, so every
    // pre-existing `throws:` expectation matches unchanged.
    let unreadable = ScanStoreError.unreadable(sourcePath: "/tmp/x")
    #expect(CodexStoreError.unreadable(sourcePath: "/tmp/x") == unreadable)
    #expect(CursorStoreError.unreadable(sourcePath: "/tmp/x") == unreadable)
    #expect(HermesStoreError.unreadable(sourcePath: "/tmp/x") == unreadable)
    #expect(OpenClawStoreError.unreadable(sourcePath: "/tmp/x") == unreadable)
    #expect(OpenCodeStoreError.unreadable(sourcePath: "/tmp/x") == unreadable)
    let prepareFailed = ScanStoreError.prepareFailed(sourcePath: "/tmp/x")
    #expect(HermesStoreError.prepareFailed(sourcePath: "/tmp/x") == prepareFailed)
    #expect(OpenClawStoreError.prepareFailed(sourcePath: "/tmp/x") == prepareFailed)
    #expect(OpenCodeStoreError.prepareFailed(sourcePath: "/tmp/x") == prepareFailed)
}

@Test func scanSQLite_rows_visitsRowsAndMapsErrors() throws {
    try withTempHome { homeURL in
        let dbURL = homeURL.appendingPathComponent("rows.db")
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
            Issue.record("open failed")
            return
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "CREATE TABLE t (a TEXT); INSERT INTO t VALUES ('x'); INSERT INTO t VALUES ('y');", nil, nil, nil) == SQLITE_OK else {
            Issue.record("setup failed")
            return
        }
        let data = try Data(contentsOf: dbURL)
        var seen: [String] = []
        try ScanSQLiteEngine.rows(in: data, sourcePath: dbURL.path, sql: "SELECT a FROM t;") { statement in
            if let value = ScanSQLiteEngine.textColumn(statement, index: 0) {
                seen.append(value)
            }
        }
        #expect(seen == ["x", "y"])

        #expect(throws: ScanStoreError.unreadable(sourcePath: dbURL.path)) {
            try ScanSQLiteEngine.rows(in: Data("not-a-database".utf8), sourcePath: dbURL.path, sql: "SELECT a FROM t;") { _ in }
        }
        #expect(throws: ScanStoreError.prepareFailed(sourcePath: dbURL.path)) {
            try ScanSQLiteEngine.rows(in: data, sourcePath: dbURL.path, sql: "SELECT a FROM missing;") { _ in }
        }
    }
}
