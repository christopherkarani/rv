#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization
import Testing
import RVFileStore

struct ExclusiveFileLockTests {
    @Test func concurrentBodiesSerializeOnSameLock() async throws {
        let root = try makeDirectory("concurrent")
        let lockURL = root.appendingPathComponent(".probe.lock")
        let tickets = TicketLog()
        let iterations = 16
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    try ExclusiveFileLock.withLock(at: lockURL) {
                        let ticket = tickets.count()
                        usleep(10_000)
                        tickets.append(ticket)
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(tickets.snapshot() == Array(0..<iterations))
    }

    @Test func lockFileModeIsOwnerOnlyAfterCreation() throws {
        let root = try makeDirectory("fresh")
        let lockURL = root.appendingPathComponent(".probe.lock")
        try ExclusiveFileLock.withLock(at: lockURL) {}
        #expect(try posixMode(lockURL) == 0o600)
    }

    @Test func preExistingWrongPermissionsReAssertedOwnerOnly() throws {
        let root = try makeDirectory("wrong-perms")
        let lockURL = root.appendingPathComponent(".probe.lock")
        FileManager.default.createFile(
            atPath: lockURL.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o644]
        )
        try ExclusiveFileLock.withLock(at: lockURL) {}
        #expect(try posixMode(lockURL) == 0o600)
    }

    @Test(arguments: [0o000, 0o444, 0o200])
    func preExistingOwnerUnwritableModeRecoveredToOwnerOnly(unwritableMode: Int) throws {
        let root = try makeDirectory("owner-unwritable-\(unwritableMode)")
        let lockURL = root.appendingPathComponent(".probe.lock")
        FileManager.default.createFile(
            atPath: lockURL.path,
            contents: Data(),
            attributes: [.posixPermissions: unwritableMode]
        )
        let acquired = try ExclusiveFileLock.withLock(at: lockURL) { true }
        #expect(acquired)
        #expect(try posixMode(lockURL) == 0o600)
    }

    @Test func bodyErrorRethrowsAndReleasesLock() throws {
        struct ProbeFailure: Error {}
        let root = try makeDirectory("rethrow")
        let lockURL = root.appendingPathComponent(".probe.lock")
        #expect(throws: ProbeFailure.self) {
            try ExclusiveFileLock.withLock(at: lockURL) {
                throw ProbeFailure()
            }
        }
        let reacquired = try ExclusiveFileLock.withLock(at: lockURL) { true }
        #expect(reacquired)
    }

    @Test func directoryAtLockPathThrowsLockFailed() throws {
        let root = try makeDirectory("directory")
        let lockURL = root.appendingPathComponent(".probe.lock")
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)
        #expect(throws: ExclusiveFileLock.LockError.lockFailed) {
            try ExclusiveFileLock.withLock(at: lockURL) {}
        }
    }

    @Test func missingParentDirectoryThrowsLockFailedWithoutCreatingIt() throws {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-flock-missing-\(UUID().uuidString)", isDirectory: true)
        let lockURL = missingRoot.appendingPathComponent(".probe.lock")
        #expect(throws: ExclusiveFileLock.LockError.lockFailed) {
            try ExclusiveFileLock.withLock(at: lockURL) {}
        }
        #expect(FileManager.default.fileExists(atPath: missingRoot.path) == false)
    }

    // MARK: - withExistingLock

    @Test func existingLockMissingFileRunsUnlockedAndCreatesNothing() throws {
        let root = try makeDirectory("existing-missing")
        let lockURL = root.appendingPathComponent(".probe.lock")
        let ran = try ExclusiveFileLock.withExistingLock(at: lockURL) { true }
        #expect(ran)
        #expect(FileManager.default.fileExists(atPath: lockURL.path) == false)
    }

    @Test func existingLockKeepsAnExistingFileMode() throws {
        let root = try makeDirectory("existing-mode")
        let lockURL = root.appendingPathComponent(".probe.lock")
        FileManager.default.createFile(
            atPath: lockURL.path, contents: Data(), attributes: [.posixPermissions: 0o644]
        )
        let ran = try ExclusiveFileLock.withExistingLock(at: lockURL) { true }
        #expect(ran)
        #expect(try posixMode(lockURL) == 0o644)
    }

    @Test func existingLockRefusesASymlink() throws {
        let root = try makeDirectory("existing-symlink")
        let target = root.appendingPathComponent("target.lock")
        FileManager.default.createFile(atPath: target.path, contents: Data())
        let lockURL = root.appendingPathComponent(".probe.lock")
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: target)
        #expect(throws: ExclusiveFileLock.LockError.lockFailed) {
            try ExclusiveFileLock.withExistingLock(at: lockURL) {}
        }
    }

    @Test func existingLockRefusesADirectory() throws {
        let root = try makeDirectory("existing-directory")
        let lockURL = root.appendingPathComponent(".probe.lock")
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)
        #expect(throws: ExclusiveFileLock.LockError.lockFailed) {
            try ExclusiveFileLock.withExistingLock(at: lockURL) {}
        }
    }

    @Test func existingLockRefusesAFIFOWithoutHanging() throws {
        let root = try makeDirectory("existing-fifo")
        let lockURL = root.appendingPathComponent(".probe.lock")
        #expect(mkfifo(lockURL.path, 0o600) == 0)
        let done = DispatchSemaphore(value: 0)
        let outcome = OutcomeBox()
        Thread.detachNewThread {
            do {
                try ExclusiveFileLock.withExistingLock(at: lockURL) {}
                outcome.set("ran")
            } catch ExclusiveFileLock.LockError.lockFailed {
                outcome.set("lockFailed")
            } catch {
                outcome.set("other")
            }
            done.signal()
        }
        let finished = done.wait(timeout: .now() + 5) == .success
        if finished == false {
            // Unblock a reader stuck in open(2) so the thread can exit.
            let writer = open(lockURL.path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
        }
        #expect(finished, "open(2) on a FIFO must not block")
        #expect(outcome.get() == "lockFailed")
    }

    @Test func existingLockWaitsForAHeldLock() throws {
        let root = try makeDirectory("existing-held")
        let lockURL = root.appendingPathComponent(".probe.lock")
        let holding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            try? ExclusiveFileLock.withLock(at: lockURL) {
                holding.signal()
                release.wait()
            }
        }
        holding.wait()
        Thread.detachNewThread {
            try? ExclusiveFileLock.withExistingLock(at: lockURL) { entered.signal() }
        }
        #expect(entered.wait(timeout: .now() + 0.3) == .timedOut, "body ran while the lock was held")
        release.signal()
        #expect(entered.wait(timeout: .now() + 10) == .success)
    }
}

/// `Mutex` is `~Copyable` and cannot be captured into a sending task body.
/// A tiny `Sendable` box keeps Synchronization as the lock (not `os`).
private final class TicketLog: Sendable {
    private let tickets = Mutex<[Int]>([])

    func count() -> Int {
        tickets.withLock { $0.count }
    }

    func append(_ ticket: Int) {
        tickets.withLock { $0.append(ticket) }
    }

    func snapshot() -> [Int] {
        tickets.withLock { $0 }
    }
}

private final class OutcomeBox: Sendable {
    private let value = Mutex<String?>(nil)

    func set(_ outcome: String) {
        value.withLock { $0 = outcome }
    }

    func get() -> String? {
        value.withLock { $0 }
    }
}

private func makeDirectory(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-flock-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func posixMode(_ url: URL) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let raw = attrs[.posixPermissions] as? NSNumber
    return (raw?.intValue ?? 0) & 0o777
}
