import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVIPC
import RVPolicy
@testable import RVCLI

struct AllowOnceTTYTests {
    @Test func nonTTYMintRefuses() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: false, stdoutIsTTY: false, ci: false)
        await #expect(throws: AllowOnceError.ttyRequired) {
            try await AllowOnceCLI.mint(
                command: ShellCommand(rawValue: "git reset --hard"),
                cwd: wd("/tmp/a"),
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
            cwd: wd("/tmp/a"),
            ruleID: nil,
            tty: ok,
            now: now
        )
        let ci = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: true)
        await #expect(throws: AllowOnceError.ttyRequired) {
            try await AllowOnceCLI.redeem(
                code: code.rawValue,
                tty: ci,
                robot: false,
                store: store,
                now: now
            )
        }
    }

    @Test func redeemWithoutDaemonFailsClosedAndKeepsPending() async throws {
        // Step 8B.1: no daemon reachable means no attestation, no flip,
        // no grant. The pending row stays live so the human can retry
        // once rvd is up; the gate denies throughout.
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let code = try await withCLIProcess(ownerAuthOutcome: .authenticated) {
            try await AllowOnceCLI.mint(
                command: ShellCommand(rawValue: "git reset --hard"),
                cwd: wd("/tmp/a"),
                tty: tty,
                robot: false,
                store: store,
                now: now
            )
        }
        await #expect(throws: AllowOnceAttestError.serviceUnavailable) {
            try await withCLIProcess(ownerAuthOutcome: .authenticated) {
                try await AllowOnceCLI.redeem(
                    code: code.rawValue,
                    tty: tty,
                    robot: false,
                    store: store,
                    now: now
                )
            }
        }
        #expect((await store.list(now: now)).contains { $0.kind == .pending })
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
        let gated = await PolicyGate.consumingGrant(
            for: denied,
            cwd: wd("/tmp/a"),
            grants: EphemeralAllowOnceTable(),
            now: now
        )
        #expect(gated.override == .none)
        guard case .deny = gated.result.decision else {
            Issue.record("gate must deny with no daemon attestation")
            return
        }
    }

    @Test func mintWithoutAuthenticationRefuses() async throws {
        // No seamed outcome: the tripwire fails closed before the store.
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        await #expect(throws: AllowOnceAuthError.required) {
            try await withCLIProcess {
                try await AllowOnceCLI.mint(
                    command: ShellCommand(rawValue: "git reset --hard"),
                    cwd: wd("/tmp/a"),
                    tty: tty,
                    robot: false,
                    store: store,
                    now: now
                )
            }
        }
        #expect(await store.list(now: now).isEmpty)
    }

    @Test func redeemDeniedAuthenticationThrowsBeforeAttest() async throws {
        // Failed/cancelled LA throws at the tripwire: no attestation is
        // attempted, no flip happens, the pending row stays live.
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let code = try await withCLIProcess(ownerAuthOutcome: .authenticated) {
            try await AllowOnceCLI.mint(
                command: ShellCommand(rawValue: "git reset --hard"),
                cwd: wd("/tmp/a"),
                tty: tty,
                robot: false,
                store: store,
                now: now
            )
        }
        for outcome in [UIAuthenticationOutcome.failed, .cancelled, .timedOut] {
            await #expect(throws: AllowOnceAuthError.required) {
                try await withCLIProcess(ownerAuthOutcome: outcome) {
                    try await AllowOnceCLI.redeem(
                        code: code.rawValue,
                        tty: tty,
                        robot: false,
                        store: store,
                        now: now
                    )
                }
            }
        }
        #expect((await store.list(now: now)).contains { $0.kind == .pending })
    }

    @Test func robotMintRefused() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        await #expect(throws: AllowOnceError.robotRefused) {
            try await AllowOnceCLI.mint(
                command: ShellCommand(rawValue: "git reset --hard"),
                cwd: wd("/tmp/a"),
                tty: tty,
                robot: true,
                store: store,
                now: now
            )
        }
    }

    @Test func redemptionGateRejectsCwdSwapUnderIdenticalFingerprint() async throws {
        // 8B.1 review H2: the post-LA recheck must compare the full row,
        // not just the fingerprint. A same-user file swap that preserves
        // the action hash but redirects cwd must read as changed.
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
        let reviewed = try #require(await store.validatePending(code: code.rawValue, now: now))
        #expect(AllowOnceCLI.redemptionUnchanged(before: reviewed, after: reviewed))

        var cwdSwapped = reviewed
        cwdSwapped.row.cwd = wd("/tmp/victim")
        #expect(AllowOnceCLI.redemptionUnchanged(before: reviewed, after: cwdSwapped) == false)

        let actionSwapped = (row: reviewed.row, fingerprint: String(repeating: "0", count: 64))
        #expect(AllowOnceCLI.redemptionUnchanged(before: reviewed, after: actionSwapped) == false)
    }

    @Test func redeemUnknownCodeFailsWithoutAuthentication() async throws {
        // 8B.1 review finding 8: no seamed auth outcome means any LA
        // attempt throws .required. Unknown codes must report unknownCode
        // instead, proving LA never fired for garbage.
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        await #expect(throws: AllowOnceError.unknownCode) {
            try await withCLIProcess(stdinIsTTY: true, stdoutIsTTY: true) {
                try await AllowOnceCLI.redeem(
                    code: "abc123",
                    tty: tty,
                    robot: false,
                    store: store,
                    now: now
                )
            }
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
            cwd: wd("/tmp/ws"),
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
            cwd: wd("/tmp/ws")
        )
        #expect(reply.result.decision == .allow)
    }
}

struct OperatorHomeStoreTests {
    @Test func allowOnceCLI_emptyHOME_isAbsence() {
        #expect(AllowOnceCLI.home(from: [:]) == nil)
        #expect(AllowOnceCLI.home(from: ["HOME": ""]) == nil)
        #expect(throws: ExitCode(1)) {
            try AllowOnceCLI.requireHome(from: [:])
        }
        #expect(throws: ExitCode(1)) {
            try AllowOnceCLI.requireHome(from: ["HOME": ""])
        }
    }

    @Test func allowOnceCLI_store_usesConfigDirNotSharedFallback() throws {
        let home = try #require(HomeDirectory(validating: "/tmp/rv-allow-once-home-\(UUID().uuidString)"))
        let store = AllowOnceCLI.store(home: home)
        #expect(store.baseDirectory == RVPolicyPaths.configDirectory(home: home))
        #expect(store.baseDirectory.path.contains("rv-allow-once-nohome") == false)
    }

    @Test func allowlistCLI_emptyHOME_isAbsence() {
        #expect(AllowlistCLI.home(from: [:]) == nil)
        #expect(AllowlistCLI.home(from: ["HOME": ""]) == nil)
        #expect(throws: ExitCode(1)) {
            try AllowlistCLI.requireHome(from: [:])
        }
        #expect(throws: ExitCode(1)) {
            try AllowlistCLI.requireHome(from: ["HOME": ""])
        }
    }

    @Test func allowlistCLI_store_usesConfigDirNotSharedFallback() throws {
        let home = try #require(HomeDirectory(validating: "/tmp/rv-allowlist-home-\(UUID().uuidString)"))
        let store = AllowlistCLI.store(home: home)
        #expect(store.baseDirectory == RVPolicyPaths.configDirectory(home: home))
        #expect(store.baseDirectory.path.contains("rv-allowlist-nohome") == false)
    }

    @Test func commandInvocation_nilHome_usesUniqueEphemeralNotSharedFallback() {
        let first = CommandInvocation.allowOnceStore(home: nil)
        let second = CommandInvocation.allowOnceStore(home: nil)
        #expect(first.baseDirectory.path.contains("rv-allow-once-nohome") == false)
        #expect(second.baseDirectory.path.contains("rv-allow-once-nohome") == false)
        #expect(first.baseDirectory != second.baseDirectory)
    }
}

private func isolatedStore() throws -> AllowOnceStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-allow-once-cli-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return AllowOnceStore(baseDirectory: root)
}
