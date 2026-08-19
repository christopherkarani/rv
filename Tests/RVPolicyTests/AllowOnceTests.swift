import Foundation
import Testing
@testable import RVPolicy

struct AllowOnceTests {
    @Test func fileStoreConsumesOnce() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.insertGranted(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)
        let first = await store.consume(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)
        let second = await store.consume(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)
        guard case .consumed = first else {
            Issue.record("first consume should succeed")
            return
        }
        #expect(second == .alreadyConsumed)
    }

    @Test func concurrentConsumeAcrossStoresWinsOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-allow-once-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let writer = AllowOnceStore(baseDirectory: root)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await writer.insertGranted(matchingView: "git stash clear", cwd: "/tmp/ws", now: now)
        let a = AllowOnceStore(baseDirectory: root)
        let b = AllowOnceStore(baseDirectory: root)
        async let first = a.consume(matchingView: "git stash clear", cwd: "/tmp/ws", now: now)
        async let second = b.consume(matchingView: "git stash clear", cwd: "/tmp/ws", now: now)
        let results = await [first, second]
        let consumed = results.filter {
            if case .consumed = $0 { return true }
            return false
        }
        #expect(consumed.count == 1)
        #expect(results.contains(.alreadyConsumed))
    }

    @Test func wrongCwdDoesNotConsume() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.insertGranted(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)
        let miss = await store.consume(matchingView: "git reset --hard", cwd: "/tmp/other", now: now)
        #expect(miss == .notFound)
        let hit = await store.consume(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)
        guard case .consumed = hit else {
            Issue.record("matching cwd should consume")
            return
        }
    }

    @Test func newerGrantSurvivesExpiredSibling() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.insertGranted(
            matchingView: "git reset --hard",
            cwd: "/tmp/ws",
            now: now.addingTimeInterval(-100),
            ttl: 1
        )
        try await store.insertGranted(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)
        let hit = await store.consume(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)
        guard case .consumed = hit else {
            Issue.record("fresh grant must win over an expired sibling")
            return
        }
    }

    @Test func missingFileIsNotFoundNotUnavailable() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            await store.consume(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)
                == .notFound
        )
    }

    @Test func lockFailureIsUnavailable() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.insertGranted(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)
        try sabotageLock(in: store.baseDirectory)
        #expect(
            await store.consume(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)
                == .unavailable
        )
    }

    @Test func storeFilesAreOwnerOnly() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.insertGranted(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)
        let jsonl = store.baseDirectory.appendingPathComponent("allow-once.jsonl", isDirectory: false)
        let lock = store.baseDirectory.appendingPathComponent(".allow-once.lock", isDirectory: false)
        let tmp = jsonl.appendingPathExtension("tmp")
        #expect(try posixMode(store.baseDirectory) == 0o700)
        #expect(try posixMode(jsonl) == 0o600)
        #expect(try posixMode(lock) == 0o600)
        if FileManager.default.fileExists(atPath: tmp.path) {
            #expect(try posixMode(tmp) == 0o600)
        }
    }

    @Test func expiredGrantIsExpired() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.insertGranted(
            matchingView: "git reset --hard",
            cwd: "/tmp/ws",
            now: now,
            ttl: 1
        )
        let later = now.addingTimeInterval(2)
        #expect(
            await store.consume(matchingView: "git reset --hard", cwd: "/tmp/ws", now: later) == .expired
        )
    }
}

private func isolatedStore() throws -> AllowOnceStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-allow-once-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return AllowOnceStore(baseDirectory: root)
}

private func sabotageLock(in directory: URL) throws {
    let lock = directory.appendingPathComponent(".allow-once.lock", isDirectory: false)
    if FileManager.default.fileExists(atPath: lock.path) {
        try FileManager.default.removeItem(at: lock)
    }
    try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
}

private func posixMode(_ url: URL) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let raw = attrs[.posixPermissions] as? NSNumber
    return (raw?.intValue ?? 0) & 0o777
}
