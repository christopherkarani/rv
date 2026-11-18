#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import Synchronization
import Testing
@testable import RVHistory

/// What `AuditLog.append` writes: one bounded line, readable on a terminal.
@Suite("AuditLog line")
struct AuditLogLineTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rv-auditline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func event(_ subject: String, reason: String? = nil, detail: [String: String] = [:]) -> AuditEvent {
        AuditEvent(
            time: Date(timeIntervalSince1970: 1_791_900_000), kind: .mcpCall, decision: .allowed, subject: subject,
            reason: reason, source: "mcp-gateway", detail: detail)
    }

    /// An append waiting on one log's file lock must not hold up an append
    /// to another log: this process's own lock is per log. (One lock
    /// covered them all and was held through the wait, so one stuck log
    /// stalled every other log in the process.)
    @Test(.timeLimit(.minutes(1)))
    func anAppendWaitingOnOneLogDoesNotHoldUpAnother() throws {
        let stuck = try scratch()
        let free = try scratch()
        defer {
            try? FileManager.default.removeItem(at: stuck)
            try? FileManager.default.removeItem(at: free)
        }
        #expect(AuditLog.append(event("first"), configDirectory: stuck))
        let holder = open(AuditLog.fileURL(configDirectory: stuck).path, O_RDWR | O_CLOEXEC)
        try #require(holder >= 0)
        defer { close(holder) }
        try #require(flock(holder, LOCK_EX | LOCK_NB) == 0)
        // A thread of its own waits for the stuck log, far longer than the
        // other append is given.
        let waiting = Mutex(false)
        let waited = DispatchSemaphore(value: 0)
        let stuckEvent = event("stuck")
        Thread.detachNewThread {
            waiting.withLock { $0 = true }
            _ = AuditLog.append(stuckEvent, configDirectory: stuck, lockTimeout: .seconds(30))
            waited.signal()
        }
        while waiting.withLock({ $0 }) == false { usleep(1_000) }
        // Long enough for the waiter to be inside its wait.
        usleep(300_000)
        #expect(AuditLog.append(event("other"), configDirectory: free, lockTimeout: .seconds(2)))
        // The waiter was waiting all the while.
        #expect(waited.wait(timeout: .now()) == .timedOut)
        // Free the stuck log so the waiter ends at once, and with its line written.
        _ = flock(holder, LOCK_UN)
        #expect(waited.wait(timeout: .now() + 20) == .success)
        #expect(try AuditChain.verify(fileURL: AuditLog.fileURL(configDirectory: stuck)).get().lines == 2)
    }

    /// Threads appending to one log, half of them through another spelling
    /// of its path, each get the line before theirs: the chain is whole
    /// and no line is lost. (On a local filesystem the file's own lock
    /// would keep the two spellings apart too; this is the result both
    /// locks owe, whichever one gives it.)
    @Test(.timeLimit(.minutes(1)))
    func concurrentAppendsThroughTwoPathsKeepTheChainWhole() throws {
        let dir = try scratch()
        let alias = dir.deletingLastPathComponent().appendingPathComponent("rv-auditline-alias-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: alias)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: dir)
        let threads = 8
        let each = 12
        let done = DispatchSemaphore(value: 0)
        let written = Mutex(0)
        // Every thread starts appending together, not one after another.
        let go = Mutex(false)
        for thread in 0..<threads {
            let directory = thread % 2 == 0 ? dir : alias
            let events = (0..<each).map { event("t\(thread)-\($0)") }
            Thread.detachNewThread {
                while go.withLock({ $0 }) == false { usleep(500) }
                for event in events where AuditLog.append(event, configDirectory: directory, lockTimeout: .seconds(30)) {
                    written.withLock { $0 += 1 }
                }
                done.signal()
            }
        }
        usleep(50_000)
        go.withLock { $0 = true }
        for _ in 0..<threads { #expect(done.wait(timeout: .now() + 50) == .success) }
        #expect(written.withLock { $0 } == threads * each)
        let report = try AuditChain.verify(fileURL: AuditLog.fileURL(configDirectory: dir)).get()
        #expect(report.lines == threads * each)
        #expect(report.isIntact)
    }

    /// M4: a line the verifier would reject is never written.
    @Test func anOversizedEventIsRefusedAndTheNextOneAppends() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = AuditLog.fileURL(configDirectory: dir)
        #expect(AuditLog.append(event("first"), configDirectory: dir))
        let before = try Data(contentsOf: file)
        let huge = String(repeating: "k", count: AuditChain.maximumLineBytes)
        #expect(AuditLog.append(event("huge", reason: huge), configDirectory: dir) == false)
        #expect(try Data(contentsOf: file) == before)
        #expect(AuditLog.append(event("next"), configDirectory: dir))
        let report = try AuditChain.verify(fileURL: file).get()
        #expect(report.lines == 2)
        #expect(report.firstBreak == nil)
    }

    /// M2 (a): ESC, a bidi override, and a tag character in any field are
    /// written as JSON escapes, so `cat audit.jsonl` cannot be spoofed;
    /// the decoded event keeps the original text.
    @Test func hidingScalarsAreEscapedInTheWrittenLine() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostile = "a\u{1B}[2Jb\u{202E}c\u{E0041}d"
        #expect(AuditLog.append(
            event("github/\(hostile)", reason: hostile, detail: ["argumentKeys": hostile, hostile: "v"]),
            configDirectory: dir))
        let bytes = try Data(contentsOf: AuditLog.fileURL(configDirectory: dir))
        let line = try #require(String(data: bytes, encoding: .utf8))
        #expect(line.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x202E || $0.value == 0xE0041 } == false)
        #expect(line.contains(#"\u202e"#) || line.contains(#"\u202E"#))
        let decoded = try #require(AuditLedger.event(fromLine: Substring(line.trimmingCharacters(in: .newlines)), source: .audit))
        #expect(decoded.subject == "github/\(hostile)")
        #expect(decoded.reason == hostile)
        #expect(decoded.detail["argumentKeys"] == hostile)
        #expect(decoded.detail[hostile] == "v")
        #expect(try AuditChain.verify(fileURL: AuditLog.fileURL(configDirectory: dir)).get().firstBreak == nil)
    }

    /// The length of the first line `event("edge", reason:)` writes.
    private func firstLineBytes(reason: String) throws -> Int {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(AuditLog.append(event("edge", reason: reason), configDirectory: dir))
        return try Data(contentsOf: AuditLog.fileURL(configDirectory: dir)).count - 1
    }

    /// M4: a line exactly `maximumLineBytes` long is refused; one byte
    /// shorter is written and verifies.
    @Test func aLineAtTheLimitIsRefusedAndOneByteUnderIsWritten() throws {
        let probe = try firstLineBytes(reason: "k")
        let atLimit = String(repeating: "k", count: AuditChain.maximumLineBytes - probe + 1)
        let refused = try scratch()
        defer { try? FileManager.default.removeItem(at: refused) }
        #expect(AuditLog.append(event("edge", reason: atLimit), configDirectory: refused) == false)
        #expect(try Data(contentsOf: AuditLog.fileURL(configDirectory: refused)).isEmpty)

        let accepted = try scratch()
        defer { try? FileManager.default.removeItem(at: accepted) }
        #expect(AuditLog.append(event("edge", reason: String(atLimit.dropLast())), configDirectory: accepted))
        let file = AuditLog.fileURL(configDirectory: accepted)
        #expect(try Data(contentsOf: file).count == AuditChain.maximumLineBytes)
        #expect(AuditLog.append(event("next"), configDirectory: accepted))
        let report = try AuditChain.verify(fileURL: file).get()
        #expect(report.lines == 2)
        #expect(report.firstBreak == nil)
    }

    /// N13: another process holding the file lock makes `append` give up
    /// after its timeout, writing nothing, instead of blocking forever.
    @Test func aHeldFileLockTimesOutAndWritesNothing() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = AuditLog.fileURL(configDirectory: dir)
        let holder = open(file.path, O_CREAT | O_RDWR, 0o600)
        #expect(holder >= 0)
        defer { close(holder) }
        #expect(flock(holder, LOCK_EX) == 0)
        let started = Date()
        #expect(AuditLog.append(event("blocked"), configDirectory: dir, lockTimeout: .milliseconds(200)) == false)
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(try Data(contentsOf: file).isEmpty)
        _ = flock(holder, LOCK_UN)
        #expect(AuditLog.append(event("after"), configDirectory: dir, lockTimeout: .milliseconds(200)))
        #expect(try AuditChain.verify(fileURL: file).get().lines == 1)
    }
}
