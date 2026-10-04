#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
import RVDomain
@testable import RVPolicy

struct AllowOnceStoreTests {
    @Test func generateAllowOnceCode_returnsAllowOnceUnlockCode() throws {
        let code: AllowOnceUnlockCode = try generateAllowOnceCode()
        #expect(AllowOnceUnlockCode.isValid(code.rawValue))
        #expect(code.rawValue.count == 6)
        #expect(code.rawValue == code.rawValue.lowercased())
    }

    @Test func nonTTYMintRefusesAndDoesNotWrite() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: false, stdoutIsTTY: false, ci: false)
        await #expect(throws: AllowOnceError.ttyRequired) {
            try await store.mint(
                matchingView: "git reset --hard",
                cwd: wd("/tmp/a"),
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
                cwd: wd("/tmp/a"),
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
        let code: AllowOnceUnlockCode = try await store.mint(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/a"),
            ruleID: nil,
            tty: tty,
            now: now
        )
        #expect(code.rawValue.count == 6)
        let disk = try String(contentsOf: jsonl(store), encoding: .utf8)
        #expect(disk.contains(code.rawValue) == false)
        #expect(disk.contains("code_hash"))
        #expect(disk.contains("short_code") == false)
        _ = try await store.redeem(code: code.rawValue, tty: tty, now: now)
        // The file redeem flips projection only; spend lives in memory.
        #expect((await store.list(now: now)).contains { $0.kind == .granted })
        let grants = EphemeralAllowOnceTable()
        #expect(
            await grants.plant(
                matchingView: "git reset --hard", cwd: wd("/tmp/a"), codeHash: "store-redeem",
                now: now
            ) == .planted
        )
        #expect(await grants.consume(matchingView: "git reset --hard", cwd: wd("/tmp/a"), now: now))
        #expect(
            await grants.consume(matchingView: "git reset --hard", cwd: wd("/tmp/a"), now: now)
                == false
        )
        await #expect(throws: AllowOnceError.alreadySpent) {
            try await store.redeem(code: code.rawValue, tty: tty, now: now)
        }
    }

    @Test func peekPending_showsLiveRowOnly() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let code: AllowOnceUnlockCode = try await store.mint(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/a"),
            ruleID: nil,
            tty: tty,
            now: now
        )
        let peeked = await store.peekPending(code: code.rawValue, now: now)
        let row = try #require(peeked)
        #expect(row.kind == .pending)
        #expect(row.commandRedacted == "git …")
        #expect(row.cwd == wd("/tmp/a"))
        #expect(await store.peekPending(code: "ffffff", now: now) == nil)
        #expect(await store.peekPending(code: "not hex!", now: now) == nil)
        _ = try await store.redeem(code: code.rawValue, tty: tty, now: now)
        #expect(await store.peekPending(code: code.rawValue, now: now) == nil)
    }

    @Test func memoryGrantConsumesOnce() async throws {
        let grants = EphemeralAllowOnceTable()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            await grants.plant(
                matchingView: "git reset --hard", cwd: wd("/tmp/ws"), codeHash: "store-once",
                now: now
            ) == .planted
        )
        #expect(
            await grants.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now),
            "first consume should succeed"
        )
        #expect(
            await grants.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now)
                == false
        )
    }

    @Test func concurrentConsumeAcrossTasksWinsOnce() async throws {
        // Step 8B.1: cross-process file CAS is gone by design (only the
        // daemon's table spends). The race property is actor serialization.
        let grants = EphemeralAllowOnceTable()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            await grants.plant(
                matchingView: "git stash clear", cwd: wd("/tmp/ws"), codeHash: "store-race",
                now: now
            ) == .planted
        )
        async let first = grants.consume(matchingView: "git stash clear", cwd: wd("/tmp/ws"), now: now)
        async let second = grants.consume(matchingView: "git stash clear", cwd: wd("/tmp/ws"), now: now)
        let results = await [first, second]
        #expect(results.filter { $0 }.count == 1)
        #expect(results.contains(false))
    }

    @Test func wrongCwdDoesNotConsume() async throws {
        let grants = EphemeralAllowOnceTable()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            await grants.plant(
                matchingView: "git reset --hard", cwd: wd("/tmp/ws"), codeHash: "store-cwd",
                now: now
            ) == .planted
        )
        #expect(
            await grants.consume(matchingView: "git reset --hard", cwd: wd("/tmp/other"), now: now)
                == false
        )
        #expect(
            await grants.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now),
            "matching cwd should consume"
        )
    }

    @Test func emptyTableConsumeIsFalse() async throws {
        let grants = EphemeralAllowOnceTable()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            await grants.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now)
                == false
        )
    }

    @Test func saveFailureSurfacesAsEncodeFailed() async throws {
        let store = try isolatedStore()
        // Directory at the JSONL path: rename(2) onto a directory fails, so
        // save throws ioFailed and the store surfaces domain encodeFailed.
        try FileManager.default.createDirectory(
            at: jsonl(store),
            withIntermediateDirectories: false
        )
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        await #expect(throws: AllowOnceError.encodeFailed) {
            try await store.mint(
                matchingView: "git reset --hard",
                cwd: wd("/tmp/a"),
                ruleID: nil,
                tty: tty,
                now: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }
    }

    @Test func lockSetupFailureSurfacesAsEncodeFailed() async throws {
        // File blocking the config dir path: withLock prepareDirectory fails
        // with ioFailed before the body runs, and the store surfaces domain
        // encodeFailed.
        let occupied = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-allow-once-occupied-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: occupied.path, contents: Data())
        let store = AllowOnceStore(baseDirectory: occupied)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        await #expect(throws: AllowOnceError.encodeFailed) {
            try await store.mint(
                matchingView: "git reset --hard",
                cwd: wd("/tmp/a"),
                ruleID: nil,
                tty: tty,
                now: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }
    }

    @Test func lockFailureKeepsProjectionSilentAndSpendsNothing() async throws {
        // Step 8B.1: projection writes are best-effort. A sabotaged lock
        // swallows the projection and creates no authority anywhere.
        let store = try isolatedStore()
        let grants = EphemeralAllowOnceTable()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try sabotageLock(in: store.baseDirectory)
        await store.project(
            lifecycle: .granted,
            matchingView: "git reset --hard",
            cwd: wd("/tmp/ws"),
            codeHash: "sabotaged",
            now: now
        )
        #expect((await store.list(now: now)).isEmpty)
        #expect(
            await grants.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now)
                == false
        )
    }

    @Test func expiredMemoryGrantDoesNotConsume() async throws {
        let grants = EphemeralAllowOnceTable()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            await grants.plant(
                matchingView: "git reset --hard",
                cwd: wd("/tmp/ws"),
                codeHash: "store-expired",
                now: now,
                ttl: 1
            ) == .planted
        )
        let later = now.addingTimeInterval(2)
        #expect(
            await grants.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: later)
                == false
        )
    }

    @Test func corruptJSONLLineSkipped() async throws {
        let store = try isolatedStore()
        let grants = EphemeralAllowOnceTable()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        try FileManager.default.createDirectory(at: store.baseDirectory, withIntermediateDirectories: true)
        let junk = "{not-json}\n"
        try junk.write(to: jsonl(store), atomically: true, encoding: .utf8)
        let code = try await store.mint(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/ws"),
            ruleID: nil,
            tty: tty,
            now: now
        )
        _ = try await store.redeem(code: code.rawValue, tty: tty, now: now)
        #expect(
            await grants.plant(
                matchingView: "git reset --hard", cwd: wd("/tmp/ws"), codeHash: "store-junk",
                now: now
            ) == .planted
        )
        #expect(
            await grants.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now),
            "valid ceremony after corrupt line must still spend"
        )
    }

    @Test func storeFilesAreOwnerOnly() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        _ = try await store.mint(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/ws"),
            ruleID: nil,
            tty: tty,
            now: now
        )
        let lock = RVPolicyPaths.allowOnceLockFile(inConfigDir: store.baseDirectory)
        #expect(try posixMode(store.baseDirectory) == 0o700)
        #expect(try posixMode(jsonl(store)) == 0o600)
        #expect(try posixMode(lock) == 0o600)
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
            RVPolicyPaths.configDirectory(home: try #require(HomeDirectory(validating: home.path))).path
                == home.appendingPathComponent(".config/rv").path
        )
    }

    @Test func uninstallArtifactsIncludeLocks() {
        let root = URL(fileURLWithPath: "/tmp/rv-config", isDirectory: true)
        let names = RVPolicyPaths.uninstallArtifacts(inConfigDir: root).map(\.lastPathComponent)
        #expect(names.contains("allowlist.toml"))
        #expect(names.contains("allow-once.jsonl"))
        #expect(names.contains(".allow-once.lock"))
        #expect(names.contains(".allowlist.lock"))
        #expect(names.contains("denylist.toml"))
        #expect(names.contains(".denylist.lock"))
        #expect(names.contains("typed-rules.json"))
        #expect(names.contains(".typed-rules.lock"))
        #expect(names.contains("policy.toml"))
        #expect(names.contains(".policy.lock"))
    }

    @Test func live_usesConfigDirectoryUnderHome() throws {
        let home = try #require(HomeDirectory(validating: "/tmp/rv-home-\(UUID().uuidString)"))
        let store = AllowOnceStore.makeLive(home: home)
        #expect(store.baseDirectory == RVPolicyPaths.configDirectory(home: home))
        #expect(store.baseDirectory.path.contains("rv-allow-once-nohome") == false)
    }

    @Test func memoryConsumeLeavesFileProjectionUntouched() async throws {
        // Step 8B.1: spend touches no file. No consumed rows are ever
        // written; the projection file need not even exist.
        let store = try isolatedStore()
        let grants = EphemeralAllowOnceTable()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            await grants.plant(
                matchingView: "git reset --hard", cwd: wd("/tmp/ws"), codeHash: "store-untouched",
                now: now
            ) == .planted
        )
        #expect(
            await grants.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now),
            "planted grant should consume"
        )
        #expect(
            await grants.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now)
                == false
        )
        #expect((await store.list(now: now)).isEmpty)
        #expect(FileManager.default.fileExists(atPath: jsonl(store).path) == false)
    }

    @Test func mintFromDeny_nonTTYStillWritesPending() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let code = await store.mintFromDeny(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/ws"),
            ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
            now: now
        )
        let minted = try #require(code?.code)
        #expect(AllowOnceUnlockCode.isValid(minted.rawValue))
        #expect(minted.rawValue == minted.rawValue.lowercased())
        let rows = await store.list(now: now)
        #expect(rows.count == 1)
        #expect(rows[0].kind == .pending)
        #expect(rows[0].cwd == wd("/tmp/ws"))
        let disk = try String(contentsOf: jsonl(store), encoding: .utf8)
        #expect(disk.contains(minted.rawValue) == false)
        #expect(disk.contains("\"kind\":\"pending\""))
        #expect(disk.contains("consumed_at") == false)
    }

    @Test func mintFromDeny_sameCommandReusesCodeInSameStore() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try #require(
            await store.mintFromDeny(
                matchingView: "git reset --hard",
                cwd: wd("/tmp/ws"),
                ruleID: nil,
                now: now
            )?.code
        )
        let second = await store.mintFromDeny(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/ws"),
            ruleID: nil,
            now: now
        )
        #expect(second == .code(first))
        #expect((await store.list(now: now)).count == 1)
        let disk = try String(contentsOf: jsonl(store), encoding: .utf8)
        #expect(disk.contains(first.rawValue) == false)
    }

    @Test func mintFromDeny_sameCommandNewStoreDoesNotMintAnotherPending() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try #require(
            await store.mintFromDeny(
                matchingView: "git reset --hard",
                cwd: wd("/tmp/ws"),
                ruleID: nil,
                now: now
            )?.code
        )
        let other = AllowOnceStore(baseDirectory: store.baseDirectory)
        let second = await other.mintFromDeny(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/ws"),
            ruleID: nil,
            now: now
        )
        #expect(second == .earlierPending)
        #expect((await other.list(now: now)).count == 1)
        let disk = try String(contentsOf: jsonl(store), encoding: .utf8)
        #expect(disk.contains(first.rawValue) == false)
    }

    @Test func mintFromDeny_differentCwdStillMints() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try #require(
            await store.mintFromDeny(
                matchingView: "git reset --hard",
                cwd: wd("/tmp/a"),
                ruleID: nil,
                now: now
            )?.code
        )
        let second = try #require(
            await store.mintFromDeny(
                matchingView: "git reset --hard",
                cwd: wd("/tmp/b"),
                ruleID: nil,
                now: now
            )?.code
        )
        #expect(first != second)
        #expect((await store.list(now: now)).count == 2)
    }

    @Test func mintFromDeny_emptyMatchingViewIsNil() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let code = await store.mintFromDeny(
            matchingView: "   ",
            cwd: wd("/tmp/ws"),
            ruleID: nil,
            now: now
        )
        #expect(code == nil)
        #expect(FileManager.default.fileExists(atPath: jsonl(store).path) == false)
    }

    @Test func mintFromDeny_lockFailureIsNil() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try sabotageLock(in: store.baseDirectory)
        let code = await store.mintFromDeny(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/ws"),
            ruleID: nil,
            now: now
        )
        #expect(code == nil)
        #expect(FileManager.default.fileExists(atPath: jsonl(store).path) == false)
    }

    @Test func mintFromDeny_redeemThenConsumeAllowsOnce() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let minted = try #require(
            await store.mintFromDeny(
                matchingView: "git reset --hard",
                cwd: wd("/tmp/ws"),
                ruleID: nil,
                now: now
            )?.code
        )
        await #expect(throws: AllowOnceError.ttyRequired) {
            try await store.redeem(
                code: minted.rawValue,
                tty: TTYCapability(stdinIsTTY: false, stdoutIsTTY: false, ci: false),
                now: now
            )
        }
        await #expect(throws: AllowOnceError.robotRefused) {
            try await store.redeem(code: minted.rawValue, tty: tty, now: now, robot: true)
        }
        #expect((await store.list(now: now)).contains { $0.kind == .pending })
        _ = try await store.redeem(code: minted.rawValue, tty: tty, now: now)
        let grants = EphemeralAllowOnceTable()
        #expect(
            await grants.plant(
                matchingView: "git reset --hard", cwd: wd("/tmp/ws"), codeHash: "store-deny",
                now: now
            ) == .planted
        )
        #expect(
            await grants.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now),
            "first consume should succeed after TTY redeem"
        )
        #expect(
            await grants.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now)
                == false
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

private func sabotageLock(in directory: URL) throws {
    let lock = RVPolicyPaths.allowOnceLockFile(inConfigDir: directory)
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
