import Darwin
import Foundation
import Testing
import os
@testable import RVPolicy

struct ExclusiveFileLockTests {
    @Test func concurrentBodiesSerializeOnSameLock() async throws {
        let root = try makeDirectory("concurrent")
        let lockURL = root.appendingPathComponent(".probe.lock")
        let tickets = OSAllocatedUnfairLock(initialState: [Int]())
        let iterations = 16
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                try group.addTask {
                    try ExclusiveFileLock.withLock(at: lockURL) {
                        let ticket = tickets.withLock { $0.count }
                        usleep(10_000)
                        tickets.withLock { $0.append(ticket) }
                    }
                }
            }
            try await group.waitForAll()
        }
        let observed = tickets.withLock { $0 }
        #expect(observed == Array(0..<iterations))
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

    @Test func preExistingOwnerUnwritableModeRecoveredToOwnerOnly() throws {
        let root = try makeDirectory("owner-unwritable")
        let lockURL = root.appendingPathComponent(".probe.lock")
        FileManager.default.createFile(
            atPath: lockURL.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o444]
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
