import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVCLI

struct AllowOnceTTYTests {
    @Test func nonTTYMintRefuses() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: false, stdoutIsTTY: false, ci: false)
        await #expect(throws: AllowOnceError.ttyRequired) {
            try await AllowOnceCLI.mint(
                command: "git reset --hard",
                cwd: "/tmp/a",
                tty: tty,
                robot: false,
                store: store,
                now: now
            )
        }
        #expect(
            FileManager.default.fileExists(
                atPath: RVPolicyPaths.allowOnceFile(inConfigDir: store.baseDirectory).path
            ) == false
        )
    }

    @Test func ciRedeemRefuses() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ok = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let code = try await store.mint(
            matchingView: "git reset --hard",
            cwd: "/tmp/a",
            ruleID: nil,
            tty: ok,
            now: now
        )
        let ci = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: true)
        await #expect(throws: AllowOnceError.ttyRequired) {
            try await AllowOnceCLI.redeem(
                code: code,
                tty: ci,
                robot: false,
                store: store,
                now: now
            )
        }
    }

    @Test func happyPathMintRedeemAgainstTempDir() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let code = try await AllowOnceCLI.mint(
            command: "git reset --hard",
            cwd: "/tmp/a",
            tty: tty,
            robot: false,
            store: store,
            now: now
        )
        let row = try await AllowOnceCLI.redeem(
            code: code,
            tty: tty,
            robot: false,
            store: store,
            now: now
        )
        #expect(row.kind == .granted)
        #expect(row.cwd == "/tmp/a")
        let denied = EvaluationResult(
            outcome: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                    reason: "git reset --hard destroys uncommitted changes"
                ),
                matched: nil
            ),
            matchingView: "git reset --hard"
        )
        let first = await PolicyGate.apply(denied, cwd: "/tmp/a", store: store, now: now)
        #expect(first.override == .allowOnce)
        let second = await PolicyGate.apply(denied, cwd: "/tmp/a", store: store, now: now)
        guard case .deny = second.result.decision else {
            Issue.record("second must deny")
            return
        }
    }

    @Test func robotMintRefused() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        await #expect(throws: AllowOnceError.robotRefused) {
            try await AllowOnceCLI.mint(
                command: "git reset --hard",
                cwd: "/tmp/a",
                tty: tty,
                robot: true,
                store: store,
                now: now
            )
        }
    }
}

struct AllowlistCommandTests {
    @Test func mutationRefusesWithoutTTY() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-allowlist-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AllowlistStore(baseDirectory: root)
        let tty = TTYCapability(stdinIsTTY: false, stdoutIsTTY: true, ci: false)
        let ruleID = try #require(RuleID(rawValue: "core.git:reset-hard"))
        #expect(throws: AllowOnceError.ttyRequired) {
            try store.add(
                AllowlistEntry(selector: .rule(ruleID), reason: "ci", addedAt: Date()),
                tty: tty
            )
        }
        #expect(
            FileManager.default.fileExists(
                atPath: RVPolicyPaths.allowlistFile(inConfigDir: root).path
            ) == false
        )
    }

    @Test func listValidateAllowedWithoutTTY() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-allowlist-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AllowlistStore(baseDirectory: root)
        #expect(store.loadForValidate(workspacePath: nil) == .missing)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let ruleID = try #require(RuleID(rawValue: "core.git:reset-hard"))
        try store.add(
            AllowlistEntry(selector: .rule(ruleID), reason: "ci", addedAt: Date()),
            tty: tty
        )
        guard case .ok(let entries) = store.loadForValidate(workspacePath: nil) else {
            Issue.record("validate should succeed")
            return
        }
        #expect(entries.count == 1)
    }

    @Test func removeMatchesNormalizedExactCommandAlias() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-allowlist-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AllowlistStore(baseDirectory: root)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let normalized = MatchingView("rm -rf ./build")
        try store.add(
            AllowlistEntry(selector: .exactCommand(normalized), reason: "build", addedAt: Date()),
            tty: tty
        )
        let removed = try store.remove(
            matching: "sudo rm -rf ./build",
            tty: tty,
            exactCommandAliases: [normalized.rawValue]
        )
        #expect(removed == 1)
        #expect(store.loadForValidate(workspacePath: nil) == .ok([]))
    }
}

struct CommandRunAllowlistTests {
    @Test func evaluateCommandHonorsAllowlistFromStoreDirectory() async throws {
        let root = try isolatedAllowOnceDirectory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ruleID = try #require(RuleID(rawValue: "core.git:reset-hard"))
        try AllowlistStore(baseDirectory: root).add(
            AllowlistEntry(selector: .rule(ruleID), reason: "ci", addedAt: now),
            tty: TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        )
        let result = await CommandRun.evaluateCommand(
            "git reset --hard",
            cwd: "/tmp/ws",
            store: AllowOnceStore(baseDirectory: root),
            now: now,
            home: try isolatedHome()
        )
        #expect(result.decision == .allow)
    }

    @Test func inProcessServiceClientHonorsAllowlistFromStoreDirectory() async throws {
        let root = try isolatedAllowOnceDirectory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ruleID = try #require(RuleID(rawValue: "core.git:reset-hard"))
        try AllowlistStore(baseDirectory: root).add(
            AllowlistEntry(selector: .rule(ruleID), reason: "ci", addedAt: now),
            tty: TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        )
        let client = ServiceClient(
            transport: nil,
            allowOnceDirectory: root,
            home: try isolatedHome(),
            clock: { now }
        )
        let reply = await client.evaluate(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: "/tmp/ws"
        )
        #expect(reply.result.decision == .allow)
    }
}

private func isolatedStore() throws -> AllowOnceStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-allow-once-cli-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return AllowOnceStore(baseDirectory: root)
}
