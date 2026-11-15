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

/// Whether the temporary directory can hard-link a file, so two names
/// reach one inode.
private let hardLinksShareAnInode: Bool = {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rv-auditlink-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("a")
    let other = dir.appendingPathComponent("b")
    guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
        FileManager.default.createFile(atPath: file.path, contents: nil),
        link(file.path, other.path) == 0
    else { return false }
    var first = stat()
    var second = stat()
    guard stat(file.path, &first) == 0, stat(other.path, &second) == 0 else { return false }
    return first.st_dev == second.st_dev && first.st_ino == second.st_ino
}()

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

    /// Pauses taken on a fake clock: each one is 10 ms of fake time.
    private final class Ticks: Sendable {
        let count = Mutex(0)
        var value: Int { count.withLock { $0 } }
        func increment() -> Int { count.withLock { $0 += 1; return $0 } }
    }

    /// A1: one deadline, fixed when the append starts, covers the
    /// in-process lock and the file lock. Another append of this process
    /// holds the log until the whole 0.1 s budget (10 fake pauses) is
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

        // The log is busy in this process, as another thread's append
        // would make it, until the whole budget is spent.
        let log = try key(dir, .directory)
        try #require(AuditLog.AppendLock.mutex.withLock { $0.insert(log).inserted })
        defer { AuditLog.AppendLock.mutex.withLock { _ = $0.remove(log) } }

        let ticks = Ticks()
        let base = ContinuousClock.now
        let wait = AuditLog.LockWait(
            timeout: 0.1,
            now: { base.advanced(by: .milliseconds(10 * ticks.value)) },
            pause: {
                // The other append lets the log go.
                guard ticks.increment() == 10 else { return }
                AuditLog.AppendLock.mutex.withLock { _ = $0.remove(log) }
            }
        )
        #expect(AuditLog.append(event("late"), configDirectory: dir, wait: wait) == false)
        #expect(ticks.value == 10, "the file lock must not get a fresh budget")
        #expect(try Data(contentsOf: file).isEmpty)
        #expect(isBusy(log) == false, "the append gave the log up again")
    }

    /// A1: a thread queued behind a log another thread of this process
    /// holds gives up on its own deadline, without the holder ever letting
    /// go: nothing is written, no file is made, and the holder's entry stays.
    @Test func aHeldInProcessLockTimesOutWithoutBeingReleased() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ticks = Ticks()
        let base = ContinuousClock.now
        let wait = AuditLog.LockWait(
            timeout: 0.05,
            now: { base.advanced(by: .milliseconds(10 * ticks.value)) },
            pause: { _ = ticks.increment() }
        )
        let log = try key(dir, .directory)
        try whileBusy(log) {
            #expect(AuditLog.append(event("queued"), configDirectory: dir, wait: wait) == false)
            #expect(isBusy(log), "the waiter took the holder's entry away")
        }
        #expect(ticks.value == 5)
        #expect(FileManager.default.fileExists(atPath: AuditLog.fileURL(configDirectory: dir).path) == false)
    }

    /// One log busy in this process: an append to it gives up on its own
    /// deadline (5 pauses of 10 fake ms against 50 ms), leaving no file and
    /// the holder's entry in place, while an append to another log of this
    /// process, made from inside that wait, is written.
    @Test(.timeLimit(.minutes(1)))
    func aBusyLogTimesOutWhileAnotherLogIsWritten() throws {
        let busy = try scratch()
        let other = try scratch()
        defer {
            try? FileManager.default.removeItem(at: busy)
            try? FileManager.default.removeItem(at: other)
        }
        let otherEvent = event("other")
        let otherWritten = Outcome()
        let ticks = Ticks()
        let base = ContinuousClock.now
        let wait = AuditLog.LockWait(
            timeout: 0.05,
            now: { base.advanced(by: .milliseconds(10 * ticks.value)) },
            pause: {
                guard ticks.increment() == 2 else { return }
                otherWritten.set(AuditLog.append(otherEvent, configDirectory: other))
            }
        )
        let log = try key(busy, .directory)
        try whileBusy(log) {
            #expect(AuditLog.append(event("queued"), configDirectory: busy, wait: wait) == false)
            #expect(isBusy(log), "the waiter took the holder's entry away")
        }
        #expect(ticks.value == 5)
        #expect(FileManager.default.fileExists(atPath: AuditLog.fileURL(configDirectory: busy).path) == false)
        #expect(otherWritten.value == true, "the other log waited behind the busy one")
        #expect(try AuditChain.verify(fileURL: AuditLog.fileURL(configDirectory: other)).get().lines == 1)
    }

    /// The busy set's own mutex is held only to change the set: an append
    /// that meets another thread inside it waits for that thread, and does
    /// not take it for its log being busy. With its budget already spent (a
    /// zero timeout) it would otherwise fail with its log free. The holder
    /// lets go 50 ms after the append is about to start, not on a clock of
    /// its own: nothing outside the append can see it blocked on the mutex,
    /// so the hold cannot be handed off exactly.
    @Test(.timeLimit(.minutes(1)))
    func aThreadInsideTheBusySetIsNotTakenForABusyLog() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inside = DispatchSemaphore(value: 0)
        let starting = DispatchSemaphore(value: 0)
        let left = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            AuditLog.AppendLock.mutex.withLock { _ in
                inside.signal()
                _ = starting.wait(timeout: .now() + 10)
                usleep(50_000)
            }
            left.signal()
        }
        #expect(inside.wait(timeout: .now() + 10) == .success)
        let paused = Ticks()
        let wait = AuditLog.LockWait(timeout: 0, pause: { _ = paused.increment() })
        starting.signal()
        #expect(AuditLog.append(event("free"), configDirectory: dir, wait: wait), "a free log was taken for a busy one")
        #expect(paused.value == 0)
        #expect(left.wait(timeout: .now() + 10) == .success)
        #expect(try AuditChain.verify(fileURL: AuditLog.fileURL(configDirectory: dir)).get().lines == 1)
    }

    /// One `audit.jsonl` hard-linked into a second directory is still one
    /// log in this process: while an append holds the file (its entry is
    /// in the set), an append through either directory gives up on its own
    /// deadline with nothing written, without counting on `flock`, which a
    /// network filesystem may count per process. The holder's entry stays.
    /// Skipped where the temporary directory cannot hard-link a file.
    @Test(.enabled(if: hardLinksShareAnInode, "hard links are not supported in the temporary directory"))
    func oneFileThroughTwoDirectoriesIsOneLog() throws {
        let first = try scratch()
        let second = try scratch()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        #expect(AuditLog.append(event("first"), configDirectory: first))
        let file = AuditLog.fileURL(configDirectory: first)
        try FileManager.default.linkItem(at: file, to: AuditLog.fileURL(configDirectory: second))
        let log = try key(file, .file)
        try #require(try key(AuditLog.fileURL(configDirectory: second), .file) == log)
        let before = try Data(contentsOf: file)
        try whileBusy(log) {
            for directory in [second, first] {
                let ticks = Ticks()
                let base = ContinuousClock.now
                let wait = AuditLog.LockWait(
                    timeout: 0.05,
                    now: { base.advanced(by: .milliseconds(10 * ticks.value)) },
                    pause: { _ = ticks.increment() }
                )
                #expect(AuditLog.append(event("through"), configDirectory: directory, wait: wait) == false)
                #expect(ticks.value == 5)
                #expect(isBusy(log), "the waiter took the holder's entry away")
            }
        }
        #expect(try Data(contentsOf: file) == before)
        // Free again: an append through the second directory chains on.
        #expect(AuditLog.append(event("after"), configDirectory: second))
        #expect(try AuditChain.verify(fileURL: file).get().lines == 2)
    }

    /// A directory's entry and a file's with the same numbers are two
    /// entries: an append holding the one never waits for the other, so a
    /// filesystem that numbers a directory and its file alike cannot make
    /// an append wait on itself.
    @Test(.timeLimit(.minutes(1)))
    func aDirectoryAndAFileNumberedAlikeAreTwoEntries() throws {
        let directory = AuditLog.AppendLock.Log(device: .max, inode: .max - 7, kind: .directory)
        let file = AuditLog.AppendLock.Log(device: .max, inode: .max - 7, kind: .file)
        let ticks = Ticks()
        let base = ContinuousClock.now
        let wait = AuditLog.LockWait(
            timeout: 0.05,
            now: { base.advanced(by: .milliseconds(10 * ticks.value)) },
            pause: { _ = ticks.increment() }
        )
        var nested = false
        let entered = AuditLog.AppendLock.withLock(directory, wait) {
            AuditLog.AppendLock.withLock(file, wait) {
                nested = true
                return true
            }
        }
        #expect(entered)
        #expect(nested)
        #expect(ticks.value == 0, "the file's entry waited on the directory's")
        #expect(isBusy(directory) == false)
        #expect(isBusy(file) == false)
    }

    /// The key `AuditLog.append` takes in this process for `url`: a log's
    /// directory, or the log file itself.
    private func key(_ url: URL, _ kind: AuditLog.AppendLock.Log.Kind) throws -> AuditLog.AppendLock.Log {
        var info = stat()
        try #require(stat(url.path, &info) == 0)
        return AuditLog.AppendLock.Log(info, kind)
    }

    /// `body` with `log` marked busy in this process, as an append holding
    /// it marks it; the mark is taken out after.
    private func whileBusy(_ log: AuditLog.AppendLock.Log, _ body: () throws -> Void) throws {
        try #require(AuditLog.AppendLock.mutex.withLock { $0.insert(log).inserted })
        defer { AuditLog.AppendLock.mutex.withLock { _ = $0.remove(log) } }
        try body()
    }

    private func isBusy(_ log: AuditLog.AppendLock.Log) -> Bool {
        AuditLog.AppendLock.mutex.withLock { $0.contains(log) }
    }

    /// What an append made from inside a wait returned (nil: never made).
    private final class Outcome: Sendable {
        private let stored = Mutex<Bool?>(nil)
        var value: Bool? { stored.withLock { $0 } }
        func set(_ value: Bool) { stored.withLock { $0 = value } }
    }
}
