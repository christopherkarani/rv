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
        let code = try await store.mint(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/a"),
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
        let first = await store.consume(matchingView: "git reset --hard", cwd: wd("/tmp/a"), now: now)
        let second = await store.consume(matchingView: "git reset --hard", cwd: wd("/tmp/a"), now: now)
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
        try await store.insertGranted(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now)
        let first = await store.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now)
        let second = await store.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now)
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
        try await writer.insertGranted(matchingView: "git stash clear", cwd: wd("/tmp/ws"), now: now)
        let a = AllowOnceStore(baseDirectory: root)
        let b = AllowOnceStore(baseDirectory: root)
        async let first = a.consume(matchingView: "git stash clear", cwd: wd("/tmp/ws"), now: now)
        async let second = b.consume(matchingView: "git stash clear", cwd: wd("/tmp/ws"), now: now)
        let results = await [first, second]
        let consumed = results.filter {
            if case .consumed = $0 { return true }
            return false
        }
        #expect(consumed.count == 1)
        #expect(results.contains(.alreadyConsumed))
        #expect(results.allSatisfy { status in
            switch status {
            case .consumed, .alreadyConsumed:
                return true
            case .notFound, .expired, .unavailable:
                return false
            }
        })
    }

    /// Two processes, one grant. `rv test` peeks; `rv hook` prefers XPC and will not
    /// spend an isolated-HOME grant while rvd is up. No consume CLI (T8: no new module).
    /// Children re-exec this test host and call `AllowOnceStore.consume` on the same dir.
    @Test func concurrentConsumeAcrossProcessesWinsOnce() async throws {
        if try await AllowOnceConsumeProbe.runIfRequested() {
            exit(0)
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-allow-once-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let writer = AllowOnceStore(baseDirectory: root)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await writer.insertGranted(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now)
        let runner = try #require(testHostExecutableURL())
        let processA = try startConsumeProbe(executable: runner, directory: root, outputName: "a.status")
        let processB = try startConsumeProbe(executable: runner, directory: root, outputName: "b.status")
        processA.waitUntilExit()
        processB.waitUntilExit()
        let statusA = try readProbeStatus(directory: root, outputName: "a.status", process: processA)
        let statusB = try readProbeStatus(directory: root, outputName: "b.status", process: processB)
        let lines = [statusA, statusB]
        #expect(lines.filter { $0 == "consumed" }.count == 1)
        #expect(lines.filter { $0 == "alreadyConsumed" }.count == 1)
        #expect(lines.allSatisfy { $0 == "consumed" || $0 == "alreadyConsumed" })
    }

    @Test func wrongCwdDoesNotConsume() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.insertGranted(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now)
        let miss = await store.consume(matchingView: "git reset --hard", cwd: wd("/tmp/other"), now: now)
        #expect(miss == .notFound)
        let hit = await store.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now)
        guard case .consumed = hit else {
            Issue.record("matching cwd should consume")
            return
        }
    }

    @Test func missingFileIsNotFoundNotUnavailable() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            await store.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now)
                == .notFound
        )
    }

    @Test func lockFailureIsUnavailable() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.insertGranted(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now)
        try sabotageLock(in: store.baseDirectory)
        #expect(
            await store.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now)
                == .unavailable
        )
    }

    @Test func expiredGrantIsExpired() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.insertGranted(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/ws"),
            now: now,
            ttl: 1
        )
        let later = now.addingTimeInterval(2)
        #expect(
            await store.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: later) == .expired
        )
    }

    @Test func corruptJSONLLineSkipped() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.createDirectory(at: store.baseDirectory, withIntermediateDirectories: true)
        let junk = "{not-json}\n"
        try junk.write(to: jsonl(store), atomically: true, encoding: .utf8)
        try await store.insertGranted(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now)
        let hit = await store.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now)
        guard case .consumed = hit else {
            Issue.record("valid grant after corrupt line must consume")
            return
        }
    }

    @Test func storeFilesAreOwnerOnly() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.insertGranted(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now)
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
    }

    @Test func live_usesConfigDirectoryUnderHome() throws {
        let home = try #require(HomeDirectory(validating: "/tmp/rv-home-\(UUID().uuidString)"))
        let store = AllowOnceStore.live(home: home)
        #expect(store.baseDirectory == RVPolicyPaths.configDirectory(home: home))
        #expect(store.baseDirectory.path.contains("rv-allow-once-nohome") == false)
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
        let minted = try #require(code)
        #expect(minted.count == 6)
        #expect(isAllowOnceStoreHex(minted))
        #expect(minted == minted.lowercased())
        let rows = await store.list(now: now)
        #expect(rows.count == 1)
        #expect(rows[0].kind == .pending)
        #expect(rows[0].cwd == wd("/tmp/ws"))
        let disk = try String(contentsOf: jsonl(store), encoding: .utf8)
        #expect(disk.contains(minted) == false)
        #expect(disk.contains("\"kind\":\"pending\""))
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
            )
        )
        await #expect(throws: AllowOnceError.ttyRequired) {
            try await store.redeem(
                code: minted,
                tty: TTYCapability(stdinIsTTY: false, stdoutIsTTY: false, ci: false),
                now: now
            )
        }
        await #expect(throws: AllowOnceError.robotRefused) {
            try await store.redeem(code: minted, tty: tty, now: now, robot: true)
        }
        #expect((await store.list(now: now)).contains { $0.kind == .pending })
        _ = try await store.redeem(code: minted, tty: tty, now: now)
        let first = await store.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now)
        let second = await store.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now)
        guard case .consumed = first else {
            Issue.record("first consume should succeed after TTY redeem")
            return
        }
        #expect(second == .alreadyConsumed)
    }
}

private enum AllowOnceConsumeProbe {
    static let storeDirEnv = "RV_ALLOW_ONCE_CONSUME_PROBE"
    static let outputEnv = "RV_ALLOW_ONCE_CONSUME_OUT"

    static func runIfRequested() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let storeDir = env[storeDirEnv], storeDir.isEmpty == false,
              let outputName = env[outputEnv], outputName.isEmpty == false
        else {
            return false
        }
        let root = URL(fileURLWithPath: storeDir, isDirectory: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = AllowOnceStore(baseDirectory: root)
        let status = await store.consume(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/ws"),
            now: now
        )
        let line: String
        switch status {
        case .consumed:
            line = "consumed"
        case .alreadyConsumed:
            line = "alreadyConsumed"
        case .notFound:
            line = "notFound"
        case .expired:
            line = "expired"
        case .unavailable:
            line = "unavailable"
        }
        try line.write(
            to: root.appendingPathComponent(outputName),
            atomically: true,
            encoding: .utf8
        )
        return true
    }
}

private func testHostExecutableURL() -> URL? {
    let argv0 = URL(fileURLWithPath: CommandLine.arguments[0])
    if FileManager.default.isExecutableFile(atPath: argv0.path) {
        return argv0
    }
    if let url = Bundle.main.executableURL,
       FileManager.default.isExecutableFile(atPath: url.path)
    {
        return url
    }
    return nil
}

private func consumeProbeChildArguments() -> [String] {
    let original = Array(CommandLine.arguments.dropFirst())
    let usesSwiftTestingCLI = original.contains { arg in
        arg == "--filter"
            || arg.hasPrefix("--filter=")
            || arg == "--testing-library"
            || arg.hasPrefix("--testing-library=")
    }
    guard usesSwiftTestingCLI else {
        return original
    }
    var args: [String] = []
    var index = original.startIndex
    while index < original.endIndex {
        let arg = original[index]
        if arg == "--filter" || arg == "--skip" {
            index = original.index(after: index)
            if index < original.endIndex {
                index = original.index(after: index)
            }
            continue
        }
        if arg.hasPrefix("--filter=") || arg.hasPrefix("--skip=") {
            index = original.index(after: index)
            continue
        }
        args.append(arg)
        index = original.index(after: index)
    }
    args.append(contentsOf: ["--filter", "concurrentConsumeAcrossProcessesWinsOnce"])
    return args
}

private func startConsumeProbe(
    executable: URL,
    directory: URL,
    outputName: String
) throws -> Process {
    let errURL = directory.appendingPathComponent("\(outputName).err")
    FileManager.default.createFile(atPath: errURL.path, contents: Data())
    let process = Process()
    process.executableURL = executable
    process.arguments = consumeProbeChildArguments()
    var environment = ProcessInfo.processInfo.environment
    environment[AllowOnceConsumeProbe.storeDirEnv] = directory.path
    environment[AllowOnceConsumeProbe.outputEnv] = outputName
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = try FileHandle(forWritingTo: errURL)
    try process.run()
    return process
}

private func readProbeStatus(directory: URL, outputName: String, process: Process) throws -> String {
    let url = directory.appendingPathComponent(outputName)
    if FileManager.default.fileExists(atPath: url.path) == false {
        let errURL = directory.appendingPathComponent("\(outputName).err")
        let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        Issue.record(
            "consume probe \(outputName) missing after exit \(process.terminationStatus). stderr: \(err)"
        )
    }
    try #require(FileManager.default.fileExists(atPath: url.path))
    return try String(contentsOf: url, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func isAllowOnceStoreHex(_ code: String) -> Bool {
    code.count == 6 && code.unicodeScalars.allSatisfy { scalar in
        (scalar >= "0" && scalar <= "9") || (scalar >= "a" && scalar <= "f")
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
