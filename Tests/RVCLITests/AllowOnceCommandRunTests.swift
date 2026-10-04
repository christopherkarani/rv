import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVIPC
import RVPolicy
@testable import RVCLI

struct AllowOnceCommandRunTests {
    @Test func redeem_missingCodePrintsUsage() async throws {
        try await withCLIProcess(environment: [:]) {
            var command = try AllowOnceRedeem.parse([])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test func redeem_missingHome() async throws {
        try await withCLIProcess(environment: [:], stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowOnceRedeem.parse(["abcdef"])
            await #expect(throws: ExitCode(1)) {
                try await command.run()
            }
        }
    }

    @Test func redeem_requiresTTY() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home, stdinIsTTY: false, stdoutIsTTY: false) {
            var command = try AllowOnceRedeem.parse(["abcdef"])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test func redeem_robotRefused() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowOnceRedeem.parse(["--json", "abcdef"])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
            var robot = try AllowOnceRedeem.parse(["--robot", "abcdef"])
            await #expect(throws: ExitCode(2)) {
                try await robot.run()
            }
        }
    }

    @Test func redeem_unknownCode() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(
            home: home, stdinIsTTY: true, stdoutIsTTY: true,
            ownerAuthOutcome: .authenticated
        ) {
            var command = try AllowOnceRedeem.parse(["ffffff"])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test func redeem_expiredCode() async throws {
        let home = try isolatedHome()
        let store = AllowOnceCLI.store(home: home)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let code = try await store.mint(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/a"),
            ruleID: nil,
            tty: tty,
            now: now
        )
        try await withCLIProcess(
            home: home, stdinIsTTY: true, stdoutIsTTY: true,
            ownerAuthOutcome: .authenticated
        ) {
            var command = try AllowOnceRedeem.parse([code.rawValue])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test func redeem_runWithoutDaemonFailsClosedAndKeepsPending() async throws {
        // Step 8B.1: `rv allow-once <code>` without a reachable daemon
        // fails closed at run() level. The pending row stays live for a
        // later retry; nothing flips and nothing spends.
        let home = try isolatedHome()
        let store = AllowOnceCLI.store(home: home)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let code = try await store.mint(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/a"),
            ruleID: nil,
            tty: tty,
            now: Date()
        )
        try await withCLIProcess(
            home: home, stdinIsTTY: true, stdoutIsTTY: true,
            ownerAuthOutcome: .authenticated
        ) {
            var first = try AllowOnceRedeem.parse([code.rawValue])
            await #expect(throws: ExitCode(2)) {
                try await first.run()
            }
            var second = try AllowOnceRedeem.parse([code.rawValue])
            await #expect(throws: ExitCode(2)) {
                try await second.run()
            }
        }
        #expect(await store.list(now: Date()).contains { $0.kind == .pending })
    }

    @Test func redeem_scriptedAttestGrantsOnceThenAlreadySpent() async throws {
        // CLI ceremony happy path against a scripted daemon: validate →
        // LA → re-validate → attest (exact fingerprint + cwd + codeHash)
        // → flip. The second redeem reports alreadySpent and attests
        // nothing further.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory())
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let code = try await store.mint(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/a"),
            ruleID: nil,
            tty: tty,
            now: now
        )
        let expected = try #require(await store.validatePending(code: code.rawValue, now: now))
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", status: .ok),
            responseResult: .attestTTYRedemption(
                AttestTTYRedemptionReply(planted: true, epoch: "test-epoch"))
        )
        let client = ServiceClient(transport: transport, allowOnceDirectory: store.baseDirectory)
        let row = try await withCLIProcess(ownerAuthOutcome: .authenticated) {
            try await AllowOnceCLI.redeem(
                code: code.rawValue,
                tty: tty,
                robot: false,
                store: store,
                now: now,
                client: client
            )
        }
        #expect(row.kind == AllowOnceRecord.Kind.granted)
        #expect(transport.sendCount == 1)
        let sent = try #require(transport.sends.first)
        let request = try IPCJSON.decode(IPCRequest.self, from: sent)
        guard case .attestTTYRedemption(let params) = request.method else {
            Issue.record("redeem must attest exactly once")
            return
        }
        #expect(params.fingerprint == expected.fingerprint)
        #expect(params.cwd == wd("/tmp/a"))
        #expect(params.codeHash == sha256Hex(code.rawValue.lowercased()))

        await #expect(throws: AllowOnceError.alreadySpent) {
            try await withCLIProcess(ownerAuthOutcome: .authenticated) {
                try await AllowOnceCLI.redeem(
                    code: code.rawValue,
                    tty: tty,
                    robot: false,
                    store: store,
                    now: now,
                    client: client
                )
            }
        }
        #expect(transport.sendCount == 1)
    }

    @Test func redeem_whitespaceCodeIsNotRedeemable() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowOnceRedeem.parse(["   "])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test func mintAndClear_missingHome() async throws {
        try await withCLIProcess(environment: [:], stdinIsTTY: true, stdoutIsTTY: true) {
            var mint = try AllowOnceMint.parse(["git", "status"])
            await #expect(throws: ExitCode(1)) {
                try await mint.run()
            }
            var clear = try AllowOnceClear.parse([])
            await #expect(throws: ExitCode(1)) {
                try await clear.run()
            }
        }
    }

    @Test func redeem_storeUnavailable() async throws {
        let home = try isolatedHome()
        let lock = allowOnceLockURL(home: home)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        try await withCLIProcess(
            home: home, stdinIsTTY: true, stdoutIsTTY: true,
            ownerAuthOutcome: .authenticated
        ) {
            var command = try AllowOnceRedeem.parse(["abcdef"])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test func mint_missingCommand() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowOnceMint.parse([])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test func mint_requiresTTYAndRefusesRobot() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home, stdinIsTTY: false, stdoutIsTTY: false) {
            var tty = try AllowOnceMint.parse(["git", "status"])
            await #expect(throws: ExitCode(2)) {
                try await tty.run()
            }
        }
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var robot = try AllowOnceMint.parse(["--robot", "git", "status"])
            await #expect(throws: ExitCode(2)) {
                try await robot.run()
            }
        }
    }

    @Test func mint_succeedsOnTTY() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(
            home: home, stdinIsTTY: true, stdoutIsTTY: true,
            ownerAuthOutcome: .authenticated
        ) {
            var command = try AllowOnceMint.parse(["git", "status"])
            try await command.run()
        }
    }

    @Test func mint_storeUnavailable() async throws {
        let home = try isolatedHome()
        let lock = allowOnceLockURL(home: home)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        try await withCLIProcess(
            home: home, stdinIsTTY: true, stdoutIsTTY: true,
            ownerAuthOutcome: .authenticated
        ) {
            var command = try AllowOnceMint.parse(["git", "status"])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test func list_emptyPrettyAndRobot() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home) {
            var pretty = try AllowOnceList.parse([])
            try await pretty.run()
            var robot = try AllowOnceList.parse(["--json"])
            try await robot.run()
        }
    }

    @Test func list_rowsPrettyAndRobot() async throws {
        let home = try isolatedHome()
        let store = AllowOnceCLI.store(home: home)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        _ = try await store.mint(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/a"),
            ruleID: nil,
            tty: tty,
            now: Date()
        )
        try await withCLIProcess(home: home) {
            var pretty = try AllowOnceList.parse([])
            try await pretty.run()
            var robot = try AllowOnceList.parse(["--robot"])
            try await robot.run()
        }
    }

    @Test func list_missingHome() async throws {
        try await withCLIProcess(environment: [:]) {
            var command = try AllowOnceList.parse([])
            await #expect(throws: ExitCode(1)) {
                try await command.run()
            }
        }
    }

    @Test func clear_requiresTTYThenSucceeds() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home, stdinIsTTY: false, stdoutIsTTY: false) {
            var tty = try AllowOnceClear.parse([])
            await #expect(throws: ExitCode(2)) {
                try await tty.run()
            }
        }
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var ok = try AllowOnceClear.parse([])
            try await ok.run()
        }
    }

    @Test func clear_storeUnavailable() async throws {
        let home = try isolatedHome()
        let lock = allowOnceLockURL(home: home)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowOnceClear.parse([])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test func redeem_authenticationCancelledRefusesWithoutGrant() async throws {
        let home = try isolatedHome()
        let store = AllowOnceCLI.store(home: home)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let code = try await store.mint(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/a"),
            ruleID: nil,
            tty: tty,
            now: Date()
        )
        try await withCLIProcess(
            home: home, stdinIsTTY: true, stdoutIsTTY: true,
            ownerAuthOutcome: .cancelled
        ) {
            var command = try AllowOnceRedeem.parse([code.rawValue])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
        let rows = await store.list(now: Date())
        #expect(rows.allSatisfy { $0.kind != .granted })
    }

    @Test func redeem_noAuthOverrideFailsClosed() async throws {
        // A seamed process without an explicit outcome never reaches live
        // LocalAuthentication: it fails closed deterministically.
        let home = try isolatedHome()
        let store = AllowOnceCLI.store(home: home)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let code = try await store.mint(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/a"),
            ruleID: nil,
            tty: tty,
            now: Date()
        )
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowOnceRedeem.parse([code.rawValue])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
        let rows = await store.list(now: Date())
        #expect(rows.allSatisfy { $0.kind != .granted })
    }

    @Test func mint_authenticationFailedWritesNoRow() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(
            home: home, stdinIsTTY: true, stdoutIsTTY: true,
            ownerAuthOutcome: .failed
        ) {
            var command = try AllowOnceMint.parse(["git", "status"])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
        let rows = await AllowOnceCLI.store(home: home).list(now: Date())
        #expect(rows.isEmpty)
    }

    @Test func interactiveTTY_ciIsForbid() throws {
        let live = try withCLIProcess(environment: ["CI": "1"], stdinIsTTY: true, stdoutIsTTY: true) {
            AllowOnceCLI.interactiveTTY(json: false, robot: false, plain: false, noColor: false)
        }
        #expect(live.tty.ci)
        #expect(live.robot == false)
        let robot = try withCLIProcess(stdinIsTTY: true, stdoutIsTTY: true) {
            AllowOnceCLI.interactiveTTY(json: true, robot: false, plain: false, noColor: false)
        }
        #expect(robot.robot)
    }

    @Test func subcommands_routeWithoutPositionalShadow() throws {
        // B-F6: the parent holds no code positional, so list/clear/mint
        // route to their subcommands; bare `rv allow-once <code>` rides
        // the redeem default.
        let names = AllowOnceCommand.configuration.subcommands.map {
            $0.configuration.commandName
        }
        #expect(names.contains("redeem"))
        #expect(names.contains("mint"))
        #expect(names.contains("list"))
        #expect(names.contains("clear"))
        #expect(
            AllowOnceCommand.configuration.defaultSubcommand?.configuration.commandName
                == "redeem"
        )
        let redeem = try AllowOnceRedeem.parse(["a1b2c3"])
        #expect(redeem.code == "a1b2c3")
        _ = try AllowOnceList.parse([])
        _ = try AllowOnceClear.parse([])
        _ = try AllowOnceMint.parse(["git", "status"])
    }
}
