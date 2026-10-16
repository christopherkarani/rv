import Foundation
import Testing
@testable import RVHistory

@Suite("AuditCursor")
struct AuditCursorTests {
    final class Ledgers {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-audit-cursor-\(UUID().uuidString)")

        init() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func append(_ name: String, _ text: String) throws {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) == false {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        }

        func egress(_ host: String, at time: Int) -> String {
            #"{"host":"\#(host)","port":"443","reason":"denied-policy","recordedAt":"\#(time)"}"# + "\n"
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    @Test func readsInBatchesThenOnlyNewLines() throws {
        let ledgers = try Ledgers()
        try ledgers.append("egress-denials.jsonl", ledgers.egress("a.example", at: 100) + ledgers.egress("b.example", at: 101))
        _ = AuditLog.append(
            AuditEvent(time: Date(timeIntervalSince1970: 102), kind: .mcpCall, decision: .allowed, subject: "s/t", source: "mcp-gateway"),
            configDirectory: ledgers.directory)
        let ledger = AuditLedger(configDirectory: ledgers.directory)

        let first = ledger.events(after: AuditCursor(), limit: 2)
        #expect(first.events.map(\.subject) == ["a.example:443", "s/t"])
        let second = ledger.events(after: first.next, limit: 2)
        #expect(second.events.map(\.subject) == ["b.example:443"])
        let idle = ledger.events(after: second.next, limit: 2)
        #expect(idle.events.isEmpty)
        #expect(idle.next == second.next)

        try ledgers.append("egress-denials.jsonl", ledgers.egress("c.example", at: 103))
        #expect(ledger.events(after: second.next, limit: 10).events.map(\.subject) == ["c.example:443"])
    }

    @Test func partialLinesWaitAndRotationRestarts() throws {
        let ledgers = try Ledgers()
        let ledger = AuditLedger(configDirectory: ledgers.directory)
        let line = ledgers.egress("a.example", at: 100)
        try ledgers.append("egress-denials.jsonl", String(line.dropLast(10)))
        let partial = ledger.events(after: AuditCursor(), limit: 10)
        #expect(partial.events.isEmpty)
        #expect(partial.next.positions["egress-denials.jsonl"]?.offset == 0)

        try ledgers.append("egress-denials.jsonl", String(line.suffix(10)))
        let whole = ledger.events(after: partial.next, limit: 10)
        #expect(whole.events.map(\.subject) == ["a.example:443"])

        let url = ledgers.directory.appendingPathComponent("egress-denials.jsonl")
        try FileManager.default.removeItem(at: url)
        try ledgers.append("egress-denials.jsonl", ledgers.egress("rotated.example", at: 200))
        #expect(ledger.events(after: whole.next, limit: 10).events.map(\.subject) == ["rotated.example:443"])
    }

    @Test func rewritePreservingTheFirstLineStillRestarts() throws {
        let ledgers = try Ledgers()
        let ledger = AuditLedger(configDirectory: ledgers.directory)
        let firstLine = ledgers.egress("a.example", at: 100)
        try ledgers.append("egress-denials.jsonl", firstLine + ledgers.egress("b.example", at: 101))
        let first = ledger.events(after: AuditCursor(), limit: 10)
        #expect(first.events.map(\.subject) == ["a.example:443", "b.example:443"])

        // Same inode, same first line, forged second line: the first-line
        // fingerprint alone would resume at the old offset; the last-line
        // hash must not.
        let url = ledgers.directory.appendingPathComponent("egress-denials.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((firstLine + ledgers.egress("forged.example", at: 101)).utf8))
        try handle.close()

        let after = ledger.events(after: first.next, limit: 10)
        #expect(after.events.map(\.subject) == ["a.example:443", "forged.example:443"])
    }

    @Test func fileRewrittenInPlaceWithSameInodeRestarts() throws {
        let ledgers = try Ledgers()
        let ledger = AuditLedger(configDirectory: ledgers.directory)
        try ledgers.append("egress-denials.jsonl", ledgers.egress("a.example", at: 100))
        let first = ledger.events(after: AuditCursor(), limit: 10)
        #expect(first.events.map(\.subject) == ["a.example:443"])

        let url = ledgers.directory.appendingPathComponent("egress-denials.jsonl")
        let replacement = ledgers.egress("replacement.example", at: 200) + ledgers.egress("second.example", at: 201)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(replacement.utf8))
        try handle.close()

        let after = ledger.events(after: first.next, limit: 10)
        #expect(after.events.map(\.subject) == ["replacement.example:443", "second.example:443"])
    }

    @Test func sameInodeRewriteWithSharedPrefixAndNewTimeRestarts() throws {
        let ledgers = try Ledgers()
        let ledger = AuditLedger(configDirectory: ledgers.directory)
        let original = try Self.mcpLine(time: 1_791_826_700, subject: "github/create_issue")
        let rewritten = try Self.mcpLine(time: 1_791_900_000, subject: "github/create_issue")
            + Self.mcpLine(time: 1_791_900_001, subject: "github/list_issues")
        try ledgers.append("audit.jsonl", original)
        let first = ledger.events(after: AuditCursor(), limit: 10)
        #expect(first.events.map(\.subject) == ["github/create_issue"])
        let cursor = try #require(first.next.positions["audit.jsonl"]?.offset)

        let originalBytes = Data(original.utf8)
        let rewrittenBytes = Data(rewritten.utf8)
        #expect(originalBytes.prefix(64) == rewrittenBytes.prefix(64))
        #expect(String(decoding: originalBytes.prefix(64), as: UTF8.self)
            == #"{"decision":"allowed","detail":{"argumentKeys":"","isError":"fal"#)
        let timeAt = try #require(original.range(of: "\"time\":")?.lowerBound)
        #expect(original.distance(from: original.startIndex, to: timeAt) > 64)
        #expect(rewrittenBytes.count >= Int(cursor))

        let url = ledgers.directory.appendingPathComponent("audit.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: rewrittenBytes)
        try handle.close()

        let after = ledger.events(after: first.next, limit: 10)
        #expect(after.events.map(\.subject) == ["github/create_issue", "github/list_issues"])
        #expect(after.events.map(\.time) == [
            Date(timeIntervalSince1970: 1_791_900_000),
            Date(timeIntervalSince1970: 1_791_900_001),
        ])
    }

    private static func mcpLine(time: TimeInterval, subject: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let event = AuditEvent(
            time: Date(timeIntervalSince1970: time), kind: .mcpCall, decision: .allowed, subject: subject,
            source: "mcp-gateway",
            detail: [
                "argumentKeys": "", "isError": "false", "policy": "allow",
                "server": "github", "tool": "create_issue",
            ])
        return String(decoding: try encoder.encode(event), as: UTF8.self) + "\n"
    }

    @Test func endCursorSkipsHistory() throws {
        let ledgers = try Ledgers()
        try ledgers.append("egress-denials.jsonl", ledgers.egress("old.example", at: 100))
        let ledger = AuditLedger(configDirectory: ledgers.directory)
        let now = ledger.endCursor()
        #expect(ledger.events(after: now, limit: 10).events.isEmpty)
        try ledgers.append("egress-denials.jsonl", ledgers.egress("new.example", at: 101))
        #expect(ledger.events(after: now, limit: 10).events.map(\.subject) == ["new.example:443"])
    }
}

@Suite("AuditOCSF")
struct AuditOCSFTests {
    private func event(_ kind: AuditEventKind, _ decision: AuditDecision, _ subject: String, detail: [String: String] = [:]) -> AuditEvent {
        AuditEvent(
            time: Date(timeIntervalSince1970: 1_791_826_700.5), kind: kind, decision: decision, subject: subject,
            reason: "why", agent: "codex", source: "audit.jsonl", detail: detail)
    }

    @Test func mapsEachKindToAnOCSFClass() throws {
        let mcp = AuditOCSF.object(
            event(.mcpCall, .pending, "github/create_issue", detail: ["server": "github", "tool": "create_issue"]), hostName: "h1")
        #expect(mcp["class_uid"] as? Int == 6003)
        #expect(mcp["type_uid"] as? Int == 600_399)
        #expect(mcp["time"] as? Int64 == 1_791_826_700_500)
        #expect(mcp["disposition_id"] as? Int == 14)
        #expect((mcp["api"] as? [String: Any])?["operation"] as? String == "create_issue")
        #expect(((mcp["api"] as? [String: Any])?["service"] as? [String: Any])?["name"] as? String == "github")
        #expect((mcp["actor"] as? [String: Any])?["app_name"] as? String == "codex")
        #expect(((mcp["metadata"] as? [String: Any])?["product"] as? [String: Any])?["name"] as? String == "rv")

        let egress = AuditOCSF.object(event(.egressDenied, .denied, "evil.example:443"), hostName: "h1")
        #expect(egress["class_uid"] as? Int == 4001)
        #expect(egress["activity_id"] as? Int == 5)
        #expect(egress["disposition"] as? String == "Blocked")
        #expect((egress["dst_endpoint"] as? [String: Any])?["port"] as? Int == 443)

        #expect(AuditOCSF.object(event(.commandDenied, .denied, "core.git:reset-hard"), hostName: "h")["class_uid"] as? Int == 1007)
        #expect(AuditOCSF.object(event(.runtimeStarted, .info, "/repo"), hostName: "h")["activity_id"] as? Int == 3)
        let unmapped = AuditOCSF.object(event(.admission, .allowed, "x", detail: ["k": "v"]), hostName: "h")["unmapped"] as? [String: Any]
        #expect(unmapped?["rv_kind"] as? String == "admission")
        #expect((unmapped?["rv_detail"] as? [String: String])?["k"] == "v")
    }

    @Test func uidIsStablePerEvent() throws {
        let one = event(.mcpCall, .allowed, "a/b")
        #expect(AuditOCSF.uid(one) == AuditOCSF.uid(one))
        #expect(AuditOCSF.uid(one) != AuditOCSF.uid(event(.mcpCall, .allowed, "a/c")))
        let line = try #require(AuditOCSF.jsonLine(one, hostName: "h"))
        #expect(try JSONSerialization.jsonObject(with: Data(line.utf8)) is [String: Any])
    }
}
