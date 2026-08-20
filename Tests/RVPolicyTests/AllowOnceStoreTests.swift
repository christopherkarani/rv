import Foundation
import Testing
@testable import RVPolicy

struct AllowOnceStoreTests {
    @Test func nonTTYMintRefusesAndDoesNotWrite() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: false, stdoutIsTTY: false, ci: false)
        await #expect(throws: AllowOnceError.ttyRequired) {
            try await store.mint(
                matchingView: "git reset --hard",
                cwd: "/tmp/a",
                ruleID: nil,
                tty: tty,
                now: now
            )
        }
        #expect(FileManager.default.fileExists(atPath: jsonl(store).path) == false)
    }

    @Test func ciMintRefuses() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: true)
        await #expect(throws: AllowOnceError.ttyRequired) {
            try await store.mint(
                matchingView: "git reset --hard",
                cwd: "/tmp/a",
                ruleID: nil,
                tty: tty,
                now: now
            )
        }
    }

    @Test func redeemThenConsumeAllowsOnce() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let code = try await store.mint(
            matchingView: "git reset --hard",
            cwd: "/tmp/a",
            ruleID: nil,
            tty: tty,
            now: now
        )
        #expect(code.count == 6)
        let disk = try String(contentsOf: jsonl(store), encoding: .utf8)
        #expect(disk.contains(code) == false)
        #expect(disk.contains("code_hash"))
        #expect(disk.contains("short_code") == false)
        _ = try await store.redeem(code: code, tty: tty, now: now)
        let first = await store.consume(matchingView: "git reset --hard", cwd: "/tmp/a", now: now)
        let second = await store.consume(matchingView: "git reset --hard", cwd: "/tmp/a", now: now)
        guard case .consumed = first else {
            Issue.record("first consume should succeed")
            return
        }
        #expect(second == .alreadyConsumed)
        await #expect(throws: AllowOnceError.alreadySpent) {
            try await store.redeem(code: code, tty: tty, now: now)
        }
    }

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

    @Test func corruptJSONLLineSkipped() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.createDirectory(at: store.baseDirectory, withIntermediateDirectories: true)
        let junk = "{not-json}\n"
        try junk.write(to: jsonl(store), atomically: true, encoding: .utf8)
        try await store.insertGranted(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)
        let hit = await store.consume(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)
        guard case .consumed = hit else {
            Issue.record("valid grant after corrupt line must consume")
            return
        }
    }

    @Test func storeFilesAreOwnerOnly() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.insertGranted(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)
        #expect(try posixMode(store.baseDirectory) == 0o700)
        #expect(try posixMode(jsonl(store)) == 0o600)
    }

    @Test func configDirIgnoresXDG() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let previousHome = ProcessInfo.processInfo.environment["HOME"]
        let previousXDG = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        setenv("HOME", home.path, 1)
        setenv("XDG_CONFIG_HOME", "/tmp/should-not-use-xdg", 1)
        defer {
            if let previousHome { setenv("HOME", previousHome, 1) }
            else { unsetenv("HOME") }
            if let previousXDG { setenv("XDG_CONFIG_HOME", previousXDG, 1) }
            else { unsetenv("XDG_CONFIG_HOME") }
        }
        let dir = try #require(AllowOnceStore.processHomeConfigDirectory())
        #expect(dir.path == home.appendingPathComponent(".config/rv").path)
        #expect(dir.path.contains("should-not-use-xdg") == false)
        #expect(
            RVPolicyPaths.configDirectory(home: home.path).path
                == home.appendingPathComponent(".config/rv").path
        )
    }
}

private func isolatedStore() throws -> AllowOnceStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-allow-once-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return AllowOnceStore(baseDirectory: root)
}

private func jsonl(_ store: AllowOnceStore) -> URL {
    RVPolicyPaths.allowOnceFile(inConfigDir: store.baseDirectory)
}

private func posixMode(_ url: URL) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let raw = attrs[.posixPermissions] as? NSNumber
    return (raw?.intValue ?? 0) & 0o777
}
