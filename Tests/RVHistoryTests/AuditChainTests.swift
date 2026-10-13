import Foundation
import RVDomain
import Testing
@testable import RVHistory

@Suite("AuditChain")
struct AuditChainTests {
    private func event(_ subject: String) -> AuditEvent {
        AuditEvent(
            time: Date(timeIntervalSince1970: 1_791_900_000), kind: .mcpCall, decision: .allowed, subject: subject,
            source: AuditLedger.Source.audit.rawValue)
    }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rv-chain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func lines(_ dir: URL) throws -> [String] {
        try String(contentsOf: AuditLog.fileURL(configDirectory: dir), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    private func hash(_ line: String) -> String { RVDigest.sha256Hex(Array(line.utf8)) }

    @Test func eachLineCarriesTheHashOfThePreviousLine() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a", "b", "c"] { #expect(AuditLog.append(event(name), configDirectory: dir)) }
        let written = try lines(dir)
        let prevs = try written.map { try #require(AuditLedger.event(fromLine: Substring($0), source: .audit)?.prev) }
        #expect(prevs == [AuditChain.genesis, hash(written[0]), hash(written[1])])

        let report = try AuditChain.verify(fileURL: AuditLog.fileURL(configDirectory: dir)).get()
        #expect(report == AuditChainReport(lines: 3, unchained: 0, head: hash(written[2]), firstBreak: nil))
        #expect(AuditChain.head(fileURL: AuditLog.fileURL(configDirectory: dir)) == hash(written[2]))
    }

    @Test func theChainStartsAfterLinesWrittenBeforeIt() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = #"{"decision":"info","detail":{},"kind":"admission","schema":"rv.audit.v1","source":"audit.jsonl","subject":"old","time":"2026-01-01T00:00:00Z"}"#
        try Data((legacy + "\n").utf8).write(to: AuditLog.fileURL(configDirectory: dir))
        #expect(AuditLog.append(event("new"), configDirectory: dir))
        let written = try lines(dir)
        #expect(AuditLedger.event(fromLine: Substring(written[1]), source: .audit)?.prev == hash(legacy))
        let report = try AuditChain.verify(fileURL: AuditLog.fileURL(configDirectory: dir)).get()
        #expect(report == AuditChainReport(lines: 2, unchained: 1, head: hash(written[1]), firstBreak: nil))
    }

    @Test func aTornLastLineIsIsolatedAndReported() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(AuditLog.append(event("a"), configDirectory: dir))
        let handle = try FileHandle(forWritingTo: AuditLog.fileURL(configDirectory: dir))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"torn":"#.utf8))
        try handle.close()
        #expect(AuditLog.append(event("b"), configDirectory: dir))
        let written = try lines(dir)
        #expect(written.count == 3)
        #expect(written[1] == #"{"torn":"#)
        #expect(AuditLedger.event(fromLine: Substring(written[2]), source: .audit)?.prev == hash(written[1]))
        let report = try AuditChain.verify(fileURL: AuditLog.fileURL(configDirectory: dir)).get()
        #expect(report.firstBreak == AuditChainReport.Break(line: 2, reason: "not a JSON object"))
    }

    @Test(arguments: [
        ("edit", 2, "prev does not match line 1"),
        ("delete", 2, "prev does not match line 1"),
        ("insert", 2, "no prev after the chain started"),
        ("reorder", 1, "prev is not the start of the chain"),
    ])
    func tamperingIsFound(_ change: String, _ line: Int, _ reason: String) throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a", "b", "c", "d"] { #expect(AuditLog.append(event(name), configDirectory: dir)) }
        var written = try lines(dir)
        switch change {
        case "edit": written[0] = written[0].replacingOccurrences(of: #""subject":"a""#, with: #""subject":"z""#)
        case "delete": written.remove(at: 1)
        case "insert":
            written.insert(#"{"decision":"allowed","detail":{},"kind":"mcp.call","schema":"rv.audit.v1","source":"audit.jsonl","subject":"x","time":"2026-10-13T00:00:00Z"}"#, at: 1)
        default: written.swapAt(0, 1)
        }
        let data = Data((written.joined(separator: "\n") + "\n").utf8)
        let report = AuditChain.verify(data)
        #expect(report.firstBreak == AuditChainReport.Break(line: line, reason: reason))
        #expect(report.isIntact == false)
    }

    @Test func emptyOrMissingFileIsIntact() throws {
        #expect(AuditChain.verify(Data()) == AuditChainReport(lines: 0, unchained: 0, head: AuditChain.genesis, firstBreak: nil))
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("rv-none-\(UUID().uuidString).jsonl")
        #expect(try AuditChain.verify(fileURL: missing).get().lines == 0)
        #expect(AuditChain.head(fileURL: missing) == nil)
    }

    @Test func forwardedEventsCarryTheirLinkAndHead() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(AuditLog.append(event("a"), configDirectory: dir))
        #expect(AuditLog.append(event("b"), configDirectory: dir))
        let written = try lines(dir)
        let (events, _) = AuditLedger(configDirectory: dir).events(after: AuditCursor(), limit: 10)
        #expect(events.map(\.chainHead) == [hash(written[0]), hash(written[1])])
        let unmapped = try #require(AuditOCSF.object(events[1], hostName: "h")["unmapped"] as? [String: Any])
        #expect(unmapped["rv_prev"] as? String == hash(written[0]))
        #expect(unmapped["rv_chain_head"] as? String == hash(written[1]))
    }
}
