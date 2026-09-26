#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
import RVFileStore

private struct ProbeRecord: Codable, Sendable, Equatable {
    var name: String
    var stamp: Date
    var count: Int
}

struct FileLockedJSONLStoreTests {
    @Test func loadMissingFileReturnsEmpty() throws {
        let store = try makeStore("missing")
        #expect(store.load() == [])
    }

    @Test func loadEmptyFileReturnsEmpty() throws {
        let store = try makeStore("empty")
        try FileManager.default.createDirectory(
            at: store.directoryURL,
            withIntermediateDirectories: true
        )
        let created = FileManager.default.createFile(atPath: store.fileURL.path, contents: Data())
        #expect(created)
        #expect(store.load() == [])
    }

    @Test func loadSkipsTornAndBlankLines() throws {
        let store = try makeStore("torn")
        try FileManager.default.createDirectory(
            at: store.directoryURL,
            withIntermediateDirectories: true
        )
        let good = ProbeRecord(name: "a", stamp: Date(timeIntervalSince1970: 1_700_000_000), count: 1)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let goodLine = String(data: try encoder.encode(good), encoding: .utf8)!
        let body = goodLine + "\n"
            + "{not json}\n" // bad middle line
            + "   \n" // whitespace-only
            + goodLine + "\r\n" // CRLF tolerated
            + "{\"name\":\"torn" // partial trailing line, no newline
        try body.write(to: store.fileURL, atomically: true, encoding: .utf8)
        #expect(store.load() == [good, good])
    }

    @Test func saveRoundTripsRecords() throws {
        let store = try makeStore("roundtrip")
        let records = [
            ProbeRecord(name: "a", stamp: Date(timeIntervalSince1970: 1_700_000_000), count: 1),
            ProbeRecord(name: "b", stamp: Date(timeIntervalSince1970: 1_700_000_100), count: 2),
        ]
        try store.save(records)
        #expect(store.load() == records)
    }

    @Test func saveWritesSortedKeysIso8601WithTrailingNewline() throws {
        let store = try makeStore("bytes")
        let record = ProbeRecord(name: "a", stamp: Date(timeIntervalSince1970: 1_700_000_000), count: 1)
        try store.save([record])
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(text.hasSuffix("\n"))
        #expect(text == "{\"count\":1,\"name\":\"a\",\"stamp\":\"2023-11-14T22:13:20Z\"}\n")
    }

    @Test func saveEmptyWritesEmptyFile() throws {
        let store = try makeStore("save-empty")
        try store.save([])
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(text == "")
        #expect(store.load() == [])
    }

    @Test func saveSetsOwnerOnlyPermissions() throws {
        let store = try makeStore("perms")
        try store.save([ProbeRecord(name: "a", stamp: Date(timeIntervalSince1970: 0), count: 0)])
        #expect(try storeMode(store.directoryURL) == 0o700)
        #expect(try storeMode(store.fileURL) == 0o600)
    }

    @Test func saveFromFreshDirectoryCreatesItOwnerOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-store-fresh-\(UUID().uuidString)", isDirectory: true)
        let store = FileLockedJSONLStore<ProbeRecord>(
            fileURL: root.appendingPathComponent("rows.jsonl"),
            lockURL: root.appendingPathComponent("rows.lock"),
            directoryURL: root
        )
        #expect(FileManager.default.fileExists(atPath: root.path) == false)
        try store.save([])
        #expect(try storeMode(root) == 0o700)
    }

    @Test func withLockCreatesLockFileOwnerOnly() throws {
        let store = try makeStore("lock-perms")
        try store.withLock {}
        #expect(try storeMode(store.lockURL) == 0o600)
    }

    @Test func withLockBodyErrorRethrowsUnmapped() throws {
        struct ProbeFailure: Error, Equatable {}
        let store = try makeStore("rethrow")
        #expect(throws: ProbeFailure.self) {
            try store.withLock { throw ProbeFailure() }
        }
        #expect(try store.withLock { true })
    }

    @Test func nonBlockingFailsClosedWhileLockHeld() throws {
        let store = try makeStore("nonblocking")
        try FileManager.default.createDirectory(
            at: store.directoryURL,
            withIntermediateDirectories: true
        )
        let fd = store.lockURL.path.withCString { open($0, O_RDWR | O_CREAT, 0o600) }
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        defer { _ = flock(fd, LOCK_UN) }
        #expect(throws: FileLockedStoreError.lockFailed) {
            try store.withLock(nonBlocking: true) {}
        }
    }

    @Test func directoryAtLockPathMapsToLockFailed() throws {
        let store = try makeStore("lock-dir")
        try FileManager.default.createDirectory(
            at: store.directoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: store.lockURL,
            withIntermediateDirectories: false
        )
        #expect(throws: FileLockedStoreError.lockFailed) {
            try store.withLock {}
        }
    }

    @Test func saveOntoDirectoryThrowsIoFailed() throws {
        let store = try makeStore("save-dir")
        try FileManager.default.createDirectory(
            at: store.directoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: store.fileURL,
            withIntermediateDirectories: false
        )
        #expect(throws: FileLockedStoreError.ioFailed) {
            try store.save([ProbeRecord(name: "a", stamp: Date(timeIntervalSince1970: 0), count: 0)])
        }
    }

    @Test func concurrentLockedAppendsLoseNoUpdates() async throws {
        let store = try makeStore("concurrent")
        let perTask = 8
        let tasks = 8
        try await withThrowingTaskGroup(of: Void.self) { group in
            for task in 0..<tasks {
                group.addTask {
                    for row in 0..<perTask {
                        try store.withLock {
                            var records = store.load()
                            records.append(ProbeRecord(
                                name: "t\(task)-r\(row)",
                                stamp: Date(timeIntervalSince1970: TimeInterval(task * perTask + row)),
                                count: task * perTask + row
                            ))
                            try store.save(records)
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(store.load().count == tasks * perTask)
    }
}

private func makeStore(_ label: String) throws -> FileLockedJSONLStore<ProbeRecord> {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-store-\(label)-\(UUID().uuidString)", isDirectory: true)
    return FileLockedJSONLStore<ProbeRecord>(
        fileURL: root.appendingPathComponent("rows.jsonl"),
        lockURL: root.appendingPathComponent("rows.lock"),
        directoryURL: root
    )
}

private func storeMode(_ url: URL) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let raw = attrs[.posixPermissions] as? NSNumber
    return (raw?.intValue ?? 0) & 0o777
}
