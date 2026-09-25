import Foundation
import Testing
import RVDomain
@testable import RVScan

// MARK: - ScanJSONLines

@Test func scanJSONLines_splitsOnLFAndSkipsEmpty() {
    let data = Data("{\"a\":1}\n\n{\"b\":2}\n".utf8)
    let lines = ScanJSONLines.lines(from: data)
    #expect(lines.count == 2)
    #expect(String(data: lines[0], encoding: .utf8) == "{\"a\":1}")
    #expect(String(data: lines[1], encoding: .utf8) == "{\"b\":2}")
}

@Test func scanJSONLines_emptyDataYieldsNoLines() {
    #expect(ScanJSONLines.lines(from: Data()).isEmpty)
    #expect(ScanJSONLines.lines(from: Data("\n\n".utf8)).isEmpty)
}

@Test func scanJSONLines_skipsInvalidUTF8Lines() {
    var data = Data("{\"a\":1}\n".utf8)
    data.append(contentsOf: [0xFF, 0xFE, 0x0A])
    data.append(contentsOf: Data("{\"b\":2}".utf8))
    let lines = ScanJSONLines.lines(from: data)
    #expect(lines.count == 2)
    #expect(String(data: lines[0], encoding: .utf8) == "{\"a\":1}")
    #expect(String(data: lines[1], encoding: .utf8) == "{\"b\":2}")
}

private struct DecodingProbe: Decodable, Equatable {
    var name: String?
}

@Test func scanJSONLines_decodeRoundTrip() throws {
    let line = try #require(ScanJSONLines.decode(DecodingProbe.self, from: Data("{\"name\":\"x\"}".utf8)))
    #expect(line == DecodingProbe(name: "x"))
    #expect(ScanJSONLines.decode(DecodingProbe.self, from: Data("not-json".utf8)) == nil)
    #expect(ScanJSONLines.decode(DecodingProbe.self, from: Data("[1,2]".utf8)) == nil)
}

// MARK: - ScanTimestamp

@Test func scanTimestamp_parsesFractionalAndPlain() {
    #expect(ScanTimestamp.parse("2026-08-20T12:00:01.000Z") != nil)
    #expect(ScanTimestamp.parse("2026-08-20T12:00:01Z") != nil)
    #expect(ScanTimestamp.parse(nil) == nil)
    #expect(ScanTimestamp.parse("") == nil)
    #expect(ScanTimestamp.parse("not-a-date") == nil)
}

// MARK: - Claude goldens (typed pilot)

private func extractClaude(_ payload: String, fileName: String = "inline-claude.jsonl") throws -> [ExtractedEvent] {
    let url = URL(fileURLWithPath: "/tmp/\(fileName)")
    return try ClaudeSessionStoreAdapter().extract(fileURL: url, data: Data(payload.utf8))
}

@Test func claudeTyped_extractsFixtureGoldens() throws {
    let reset = try fixtureURL("claude/projects/-tmp-rv-scan-fixture/ac001-reset-hard.jsonl")
    let resetEvents = try ClaudeSessionStoreAdapter().extract(
        fileURL: reset, data: Data(contentsOf: reset)
    )
    #expect(resetEvents.count == 1)
    #expect(resetEvents[0].host == .claude)
    #expect(resetEvents[0].command.rawValue == "git reset --hard")
    #expect(resetEvents[0].sessionID == SessionID(validating: "ac001-session"))
    #expect(resetEvents[0].sourcePath == reset.path)
    #expect(resetEvents[0].occurredAt != nil)

    let status = try fixtureURL("claude/projects/-tmp-rv-scan-fixture/allow-status.jsonl")
    let statusEvents = try ClaudeSessionStoreAdapter().extract(
        fileURL: status, data: Data(contentsOf: status)
    )
    #expect(statusEvents.map(\.command.rawValue) == ["git status"])
}

@Test func claudeTyped_stringContentYieldsZeroEvents() throws {
    let payload = """
    {"type":"user","sessionId":"s","timestamp":"2026-08-20T12:00:00.000Z","message":{"role":"user","content":"reset the branch"}}
    """
    #expect(try extractClaude(payload).isEmpty)
}

@Test func claudeTyped_mixedContentSkipsNonObjects() throws {
    let payload = """
    {"type":"assistant","sessionId":"s","message":{"content":["noise",42,{"type":"tool_use","name":"Bash","input":{"command":"git status"}}]}}
    """
    let events = try extractClaude(payload)
    #expect(events.map(\.command.rawValue) == ["git status"])
}

@Test func claudeTyped_inputCwdWinsOverEnvelopeCwd() throws {
    let payload = """
    {"type":"assistant","sessionId":"s","cwd":"/tmp/envelope","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git status","cwd":"/tmp/input"}}]}}
    {"type":"assistant","sessionId":"s","cwd":"/tmp/envelope","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git log"}}]}}
    """
    let events = try extractClaude(payload)
    #expect(events.count == 2)
    #expect(events[0].workingDirectory == WorkingDirectory(validating: "/tmp/input"))
    #expect(events[1].workingDirectory == WorkingDirectory(validating: "/tmp/envelope"))
}

@Test func claudeTyped_cwdKeyPriorityOrder() throws {
    let payload = """
    {"type":"assistant","sessionId":"s","workdir":"/tmp/workdir","working_directory":"/tmp/snake","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git status"}}]}}
    """
    let events = try extractClaude(payload)
    #expect(events.count == 1)
    #expect(events[0].workingDirectory == WorkingDirectory(validating: "/tmp/workdir"))
}

@Test func claudeTyped_sessionFallbackUsesFileStem() throws {
    let payload = """
    {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git status"}}]}}
    """
    let events = try extractClaude(payload, fileName: "fallback-session.jsonl")
    #expect(events.count == 1)
    #expect(events[0].sessionID == SessionID(validating: "fallback-session"))
}

@Test func claudeTyped_emptySessionFallsBack() throws {
    let payload = """
    {"type":"assistant","sessionId":"","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git status"}}]}}
    """
    let events = try extractClaude(payload, fileName: "fallback-session.jsonl")
    #expect(events.count == 1)
    #expect(events[0].sessionID == SessionID(validating: "fallback-session"))
}

@Test func claudeTyped_timestampVariants() throws {
    let payload = """
    {"type":"assistant","sessionId":"s","timestamp":"2026-08-20T12:00:01.000Z","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"one"}}]}}
    {"type":"assistant","sessionId":"s","timestamp":"2026-08-20T12:00:01Z","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"two"}}]}}
    {"type":"assistant","sessionId":"s","timestamp":"garbage","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"three"}}]}}
    """
    let events = try extractClaude(payload)
    #expect(events.count == 3)
    #expect(events[0].occurredAt != nil)
    #expect(events[1].occurredAt != nil)
    #expect(events[2].occurredAt == nil)
}
