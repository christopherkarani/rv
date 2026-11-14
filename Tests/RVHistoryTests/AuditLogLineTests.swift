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
        #expect(AuditLog.append(event("blocked"), configDirectory: dir, lockTimeout: 0.2) == false)
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(try Data(contentsOf: file).isEmpty)
        _ = flock(holder, LOCK_UN)
        #expect(AuditLog.append(event("after"), configDirectory: dir, lockTimeout: 0.2))
        #expect(try AuditChain.verify(fileURL: file).get().lines == 1)
    }

    /// Pauses taken on a fake clock: each one is 10 ms of fake time.
    private final class Ticks: Sendable {
        let count = Mutex(0)
        var value: Int { count.withLock { $0 } }
        func increment() -> Int { count.withLock { $0 += 1; return $0 } }
    }

    /// A1: one deadline, fixed when the append starts, covers the
    /// in-process lock and the file lock. Another thread holds the
    /// in-process lock until the whole 0.1 s budget (10 fake pauses) is
    /// spent; the file lock is held throughout. The append then gives up at
    /// once instead of starting a fresh 0.1 s wait for the file lock (which
    /// would take 20 pauses). No wall-clock timing is asserted.
    @Test func oneDeadlineCoversTheInProcessLockAndTheFileLock() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = AuditLog.fileURL(configDirectory: dir)
        let holder = open(file.path, O_CREAT | O_RDWR, 0o600)
        #expect(holder >= 0)
        defer { close(holder) }
        #expect(flock(holder, LOCK_EX) == 0)
        defer { _ = flock(holder, LOCK_UN) }

        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            AuditLog.AppendLock.mutex.withLock { _ in
                held.signal()
                _ = release.wait(timeout: .now() + 10)
            }
            released.signal()
        }
        #expect(held.wait(timeout: .now() + 10) == .success)
        defer { release.signal() }

        let ticks = Ticks()
        let base = ContinuousClock.now
        let wait = AuditLog.LockWait(
            timeout: 0.1,
            now: { base.advanced(by: .milliseconds(10 * ticks.value)) },
            pause: {
                guard ticks.increment() == 10 else { return }
                release.signal()
                _ = released.wait(timeout: .now() + 10)
            }
        )
        #expect(AuditLog.append(event("late"), configDirectory: dir, wait: wait) == false)
        #expect(ticks.value == 10, "the file lock must not get a fresh budget")
        #expect(try Data(contentsOf: file).isEmpty)
    }

    /// A1: a thread queued behind a stuck in-process lock gives up on its
    /// own deadline, without the holder ever letting go.
    @Test func aHeldInProcessLockTimesOutWithoutBeingReleased() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            AuditLog.AppendLock.mutex.withLock { _ in
                held.signal()
                _ = release.wait(timeout: .now() + 10)
            }
        }
        #expect(held.wait(timeout: .now() + 10) == .success)
        defer { release.signal() }
        let ticks = Ticks()
        let base = ContinuousClock.now
        let wait = AuditLog.LockWait(
            timeout: 0.05,
            now: { base.advanced(by: .milliseconds(10 * ticks.value)) },
            pause: { _ = ticks.increment() }
        )
        #expect(AuditLog.append(event("queued"), configDirectory: dir, wait: wait) == false)
        #expect(ticks.value == 5)
        #expect(FileManager.default.fileExists(atPath: AuditLog.fileURL(configDirectory: dir).path) == false)
    }
}
