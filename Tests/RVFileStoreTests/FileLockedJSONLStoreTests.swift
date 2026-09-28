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

private struct FailingEncodeRecord: Codable, Sendable {
    var name: String

    init(name: String) {
        self.name = name
    }

    init(from decoder: Decoder) throws {
        name = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        throw ProbeEncodeError()
    }
}

private struct ProbeEncodeError: Error {}

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
        let goodLine = try #require(String(data: try encoder.encode(good), encoding: .utf8))
        let body = goodLine + "\n"
            + "{not json}\n" // bad middle line
            + "   \n" // whitespace-only
            + goodLine + "\r\n" // CRLF tolerated
            + "{\"name\":\"torn" // partial trailing line, no newline
        try body.write(to: store.fileURL, atomically: true, encoding: .utf8)
        #expect(store.load() == [good, good])
    }

    @Test func loadSkipsInvalidUTF8LineKeepsGoodLines() throws {
        let store = try makeStore("badline")
        try FileManager.default.createDirectory(
            at: store.directoryURL,
            withIntermediateDirectories: true
        )
        let good = ProbeRecord(name: "a", stamp: Date(timeIntervalSince1970: 1_700_000_000), count: 1)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let goodLine = try #require(String(data: try encoder.encode(good), encoding: .utf8))
        var bytes = Data((goodLine + "\n").utf8)
        bytes.append(contentsOf: [0xFF, 0xFE, 0x0A]) // invalid-UTF8 line
        bytes.append(contentsOf: Data((goodLine + "\n").utf8))
        try bytes.write(to: store.fileURL)
        #expect(store.load() == [good, good])
    }

    @Test func loadAllInvalidUTF8ReturnsEmpty() throws {
        let store = try makeStore("badfile")
        try FileManager.default.createDirectory(
            at: store.directoryURL,
            withIntermediateDirectories: true
        )
        try Data([0xFF, 0xFE, 0x0A, 0xFF]).write(to: store.fileURL)
        #expect(store.load() == [])
    }

    @Test func loadStripsRepeatedTrailingCRs() throws {
        let store = try makeStore("crcr")
        try FileManager.default.createDirectory(
            at: store.directoryURL,
            withIntermediateDirectories: true
        )
        let good = ProbeRecord(name: "a", stamp: Date(timeIntervalSince1970: 1_700_000_000), count: 1)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let goodLine = try #require(String(data: try encoder.encode(good), encoding: .utf8))
        try (goodLine + "\r\r\n").write(to: store.fileURL, atomically: true, encoding: .utf8)
        #expect(store.load() == [good])
    }

    @Test func loadKeepsRowsContainingUnicodeLineSeparators() throws {
        let store = try makeStore("u2028")
        // JSONEncoder never escapes these, so they must not split rows.
        let record = ProbeRecord(
            name: "a\u{2028}\u{2029}b\u{000B}\u{000C}c\u{0085}d",
            stamp: Date(timeIntervalSince1970: 1_700_000_000),
            count: 1
        )
        try store.save([record])
        #expect(store.load() == [record])
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

    @Test func saveReassertsOwnerOnlyPermissionsOnPreExistingPaths() throws {
        let store = try makeStore("perms-reassert")
        try FileManager.default.createDirectory(
            at: store.directoryURL,
            withIntermediateDirectories: true
        )
        let seeded = FileManager.default.createFile(atPath: store.fileURL.path, contents: Data())
        #expect(seeded)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: store.directoryURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: store.fileURL.path
        )
        try store.save([ProbeRecord(name: "a", stamp: Date(timeIntervalSince1970: 0), count: 0)])
        #expect(try storeMode(store.directoryURL) == 0o700)
        #expect(try storeMode(store.fileURL) == 0o600)
    }

    @Test func baseDirectoryInitDerivesURLsAndRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-store-basedir-\(UUID().uuidString)", isDirectory: true)
        let store = FileLockedJSONLStore<ProbeRecord>(baseDirectory: root, fileName: "rows.jsonl")
        #expect(store.fileURL == root.appendingPathComponent("rows.jsonl"))
        #expect(store.lockURL == root.appendingPathComponent("rows.jsonl.lock"))
        #expect(store.directoryURL == root)
        let records = [ProbeRecord(name: "a", stamp: Date(timeIntervalSince1970: 0), count: 1)]
        try store.withLock {
            try store.save(records)
        }
        #expect(store.load() == records)
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

    @Test func withLockBodyThrownLockErrorRethrowsUntouched() throws {
        let store = try makeStore("rethrow-lock")
        #expect(throws: ExclusiveFileLock.LockError.lockFailed) {
            try store.withLock { throw ExclusiveFileLock.LockError.lockFailed }
        }
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
        #expect(throws: FileLockedJSONLStoreError.lockFailed) {
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
        #expect(throws: FileLockedJSONLStoreError.lockFailed) {
            try store.withLock {}
        }
    }

    @Test func saveEncodeFailureThrowsEncodeFailedWithoutWriting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-store-encode-fail-\(UUID().uuidString)", isDirectory: true)
        let store = FileLockedJSONLStore<FailingEncodeRecord>(
            fileURL: root.appendingPathComponent("rows.jsonl"),
            lockURL: root.appendingPathComponent("rows.lock"),
            directoryURL: root
        )
        #expect(throws: FileLockedJSONLStoreError.encodeFailed) {
            try store.save([FailingEncodeRecord(name: "x")])
        }
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path) == false)
    }

    @Test func saveEncodeFailureLeavesPreExistingBytesUntouched() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-store-encode-atomic-\(UUID().uuidString)", isDirectory: true)
        let seedStore = FileLockedJSONLStore<ProbeRecord>(
            fileURL: root.appendingPathComponent("rows.jsonl"),
            lockURL: root.appendingPathComponent("rows.lock"),
            directoryURL: root
        )
        let failingStore = FileLockedJSONLStore<FailingEncodeRecord>(
            fileURL: seedStore.fileURL,
            lockURL: seedStore.lockURL,
            directoryURL: seedStore.directoryURL
        )
        try seedStore.save([ProbeRecord(name: "seed", stamp: Date(timeIntervalSince1970: 0), count: 7)])
        let before = try Data(contentsOf: seedStore.fileURL)
        #expect(throws: FileLockedJSONLStoreError.encodeFailed) {
            try failingStore.save([FailingEncodeRecord(name: "x")])
        }
        #expect(try Data(contentsOf: seedStore.fileURL) == before)
        let temp = seedStore.fileURL.appendingPathExtension("tmp")
        #expect(FileManager.default.fileExists(atPath: temp.path) == false)
    }

    @Test func directoryPreparationFailureThrowsIoFailed() throws {
        let occupied = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-store-occupied-\(UUID().uuidString)")
        let occupiedCreated = FileManager.default.createFile(atPath: occupied.path, contents: Data())
        #expect(occupiedCreated)
        let store = FileLockedJSONLStore<ProbeRecord>(
            fileURL: occupied.appendingPathComponent("rows.jsonl"),
            lockURL: occupied.appendingPathComponent("rows.lock"),
            directoryURL: occupied
        )
        #expect(throws: FileLockedJSONLStoreError.ioFailed) {
            try store.withLock {}
        }
        #expect(throws: FileLockedJSONLStoreError.ioFailed) {
            try store.save([])
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
        #expect(throws: FileLockedJSONLStoreError.ioFailed) {
            try store.save([ProbeRecord(name: "a", stamp: Date(timeIntervalSince1970: 0), count: 0)])
        }
        let temp = store.fileURL.appendingPathExtension("tmp")
        #expect(FileManager.default.fileExists(atPath: temp.path) == false)
    }

    @Test func saveTempPathOccupiedThrowsIoFailedWithoutStrayTemp() throws {
        let store = try makeStore("save-tmp-dir")
        try FileManager.default.createDirectory(
            at: store.directoryURL,
            withIntermediateDirectories: true
        )
        let temp = store.fileURL.appendingPathExtension("tmp")
        try FileManager.default.createDirectory(
            at: temp,
            withIntermediateDirectories: false
        )
        #expect(throws: FileLockedJSONLStoreError.ioFailed) {
            try store.save([ProbeRecord(name: "a", stamp: Date(timeIntervalSince1970: 0), count: 0)])
        }
        #expect(FileManager.default.fileExists(atPath: temp.path) == false)
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
        let loaded = store.load()
        #expect(loaded.count == tasks * perTask)
        #expect(Set(loaded.map(\.name)).count == tasks * perTask)
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
