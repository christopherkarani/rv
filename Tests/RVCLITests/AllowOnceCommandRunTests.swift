import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVIPC
import RVPolicy
import Synchronization
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
        let out = CLIOutputCapture()
        try await withCLIProcess(home: home, stdinIsTTY: false, stdoutIsTTY: false, output: out) {
            var command = try AllowOnceRedeem.parse(["abcdef"])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
        #expect(out.stderr == "rv allow-once: requires an interactive TTY (stdin and stdout)\n")
    }

    @Test func redeem_robotRefused() async throws {
        let home = try isolatedHome()
        let out = CLIOutputCapture()
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true, output: out) {
            var command = try AllowOnceRedeem.parse(["--json", "abcdef"])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
            var robot = try AllowOnceRedeem.parse(["--robot", "abcdef"])
            await #expect(throws: ExitCode(2)) {
                try await robot.run()
            }
        }
        #expect(out.stderr == String(repeating: "rv allow-once: --json/--robot refused\n", count: 2))
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
                AttestTTYRedemptionReply(
                    planted: true, epoch: "test-epoch", presence: OwnerConfirmation.expectedPresence))
        )
        let client = ServiceClient(transport: transport, allowOnceDirectory: store.baseDirectory)
        let redeemed = try await withCLIProcess(ownerAuthOutcome: .authenticated) {
            try await AllowOnceCLI.redeem(
                code: code.rawValue,
                tty: tty,
                robot: false,
                store: store,
                now: now,
                client: client
            )
        }
        #expect(redeemed.row.kind == AllowOnceRecord.Kind.granted)
        #expect(transport.sendCount == 1)
        let sent = try #require(transport.sends.first)
        let request = try IPCJSON.decode(IPCRequest.self, from: sent)
        guard case .attestTTYRedemption(let params) = request.method else {
            Issue.record("redeem must attest exactly once")
            return
        }
        #expect(params.fingerprint.rawValue == expected.fingerprint)
        #expect(params.cwd == wd("/tmp/a"))
        #expect(params.codeHash.rawValue == sha256Hex(code.rawValue.lowercased()))

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

    @Test func redeem_reportsDaemonRestartAcrossEpochs() async throws {
        // m2: the second redeem attests a new daemon epoch and reports
        // the restart; earlier memory approvals died with the old table.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory())
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        func client(epoch: String, planted: Bool) -> ServiceClient {
            let transport = ScriptedTransport(
                ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", status: .ok),
                responseResult: .attestTTYRedemption(
                    AttestTTYRedemptionReply(
                        planted: planted, epoch: epoch,
                        presence: planted ? OwnerConfirmation.expectedPresence : nil))
            )
            return ServiceClient(transport: transport, allowOnceDirectory: store.baseDirectory)
        }
        let first = try await store.mint(
            matchingView: "git reset --hard", cwd: wd("/tmp/a"), ruleID: nil, tty: tty, now: now
        )
        let one = try await withCLIProcess(ownerAuthOutcome: .authenticated) {
            try await AllowOnceCLI.redeem(
                code: first.rawValue, tty: tty, robot: false, store: store, now: now,
                client: client(epoch: "epoch-a", planted: true)
            )
        }
        #expect(one.row.kind == AllowOnceRecord.Kind.granted)
        #expect(one.epochChanged == false)
        let second = try await store.mint(
            matchingView: "git status", cwd: wd("/tmp/a"), ruleID: nil, tty: tty, now: now
        )
        let two = try await withCLIProcess(ownerAuthOutcome: .authenticated) {
            try await AllowOnceCLI.redeem(
                code: second.rawValue, tty: tty, robot: false, store: store, now: now,
                client: client(epoch: "epoch-b", planted: true)
            )
        }
        #expect(two.row.kind == AllowOnceRecord.Kind.granted)
        #expect(two.epochChanged == true)
    }

    @Test func redeem_doubleAttestReconcilesProjection() async throws {
        // m1: planted:false means the code already planted this epoch
        // (concurrent genuine redeem). The CLI reconciles the pending
        // projection to granted and reports success instead of erroring.
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
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", status: .ok),
            responseResult: .attestTTYRedemption(
                AttestTTYRedemptionReply(planted: false, epoch: "test-epoch"))
        )
        let client = ServiceClient(transport: transport, allowOnceDirectory: store.baseDirectory)
        let redeemed = try await withCLIProcess(ownerAuthOutcome: .authenticated) {
            try await AllowOnceCLI.redeem(
                code: code.rawValue,
                tty: tty,
                robot: false,
                store: store,
                now: now,
                client: client
            )
        }
        #expect(redeemed.row.kind == AllowOnceRecord.Kind.granted)
        #expect(transport.sendCount == 1)
        #expect((await store.list(now: now)).contains { $0.kind == .granted })
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
        let out = CLIOutputCapture()
        try await withCLIProcess(
            home: home, stdinIsTTY: true, stdoutIsTTY: true,
            ownerAuthOutcome: .authenticated, output: out
        ) {
            var command = try AllowOnceRedeem.parse(["abcdef"])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
        #expect(out.stderr == "rv allow-once: store unavailable\n")
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
        let ttyOut = CLIOutputCapture()
        try await withCLIProcess(home: home, stdinIsTTY: false, stdoutIsTTY: false, output: ttyOut) {
            var tty = try AllowOnceMint.parse(["git", "status"])
            await #expect(throws: ExitCode(2)) {
                try await tty.run()
            }
        }
        #expect(ttyOut.stderr == "rv allow-once mint: requires an interactive TTY (stdin and stdout)\n")
        let robotOut = CLIOutputCapture()
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true, output: robotOut) {
            var robot = try AllowOnceMint.parse(["--robot", "git", "status"])
            await #expect(throws: ExitCode(2)) {
                try await robot.run()
            }
        }
        #expect(robotOut.stderr == "rv allow-once mint: --json/--robot refused\n")
    }

    @Test func mint_withoutRvdFailsOnTTYAndWritesNoCode() async throws {
        // Only rvd mints: with no rvd reachable there is no local code.
        let home = try isolatedHome()
        try await withCLIProcess(
            home: home, stdinIsTTY: true, stdoutIsTTY: true,
            ownerAuthOutcome: .authenticated
        ) {
            var command = try AllowOnceMint.parse(["git", "status"])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
        #expect(await AllowOnceCLI.store(home: home).list(now: Date()).isEmpty)
    }

    @Test func mint_tooLongToShowRefusesThroughTheGateTable() async throws {
        // #566's notShowable refusal, worded by OwnerGateRefusal for mint.
        let home = try isolatedHome()
        let out = CLIOutputCapture()
        let long = "echo " + String(repeating: "a", count: AllowOncePromptText.maxCommandScalars + 1)
        try await withCLIProcess(
            home: home, stdinIsTTY: true, stdoutIsTTY: true,
            ownerAuthOutcome: .authenticated, output: out
        ) {
            var command = try AllowOnceMint.parse(long.split(separator: " ").map(String.init))
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
        #expect(out.stderr == "rv allow-once mint: \(AllowOnceCLI.notShowableMessage)\n")
        #expect(out.stdout.isEmpty)
    }

    @Test func mint_storeUnavailable() async throws {
        let home = try isolatedHome()
        let lock = allowOnceLockURL(home: home)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        let out = CLIOutputCapture()
        try await withCLIProcess(
            home: home, stdinIsTTY: true, stdoutIsTTY: true,
            ownerAuthOutcome: .authenticated, output: out
        ) {
            var command = try AllowOnceMint.parse(["git", "status"])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
        // The LA-prompt reservation runs before the mint write and fails
        // closed on the broken lock, so the refusal reads as throttled.
        #expect(out.stderr == "rv allow-once mint: too many authentication prompts; wait and retry\n")
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
        let out = CLIOutputCapture()
        try await withCLIProcess(home: home, stdinIsTTY: false, stdoutIsTTY: false, output: out) {
            var tty = try AllowOnceClear.parse([])
            await #expect(throws: ExitCode(2)) {
                try await tty.run()
            }
        }
        #expect(out.stderr == "rv allow-once clear: requires an interactive TTY (stdin and stdout)\n")
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var ok = try AllowOnceClear.parse([])
            try await ok.run()
        }
    }

    @Test func clear_storeUnavailable() async throws {
        let home = try isolatedHome()
        let lock = allowOnceLockURL(home: home)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        let out = CLIOutputCapture()
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true, output: out) {
            var command = try AllowOnceClear.parse([])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
        #expect(out.stderr == "rv allow-once clear: store unavailable\n")
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
        let out = CLIOutputCapture()
        try await withCLIProcess(
            home: home, stdinIsTTY: true, stdoutIsTTY: true,
            ownerAuthOutcome: .cancelled, output: out
        ) {
            var command = try AllowOnceRedeem.parse([code.rawValue])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
        #expect(out.stderr == "rv allow-once: device-owner authentication required\n")
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
        let out = CLIOutputCapture()
        try await withCLIProcess(
            home: home, stdinIsTTY: true, stdoutIsTTY: true,
            ownerAuthOutcome: .failed, output: out
        ) {
            var command = try AllowOnceMint.parse(["git", "status"])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
        #expect(out.stderr == "rv allow-once mint: device-owner authentication required\n")
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

    @Test func listEscapesCwd() async throws {
        let sentence = "ok: every MCP server is governed by rv, allowed direct, or disabled"
        let raw = "/tmp/p\u{1B}[2J\u{1B}[H" + sentence + "\u{2028}" + sentence + "\u{2029}" + sentence + "\u{202E}" + sentence
        let home = try isolatedHome()
        let store = AllowOnceCLI.store(home: home)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        _ = try await store.mint(
            matchingView: MatchingView("git status"), cwd: wd(raw), ruleID: nil, tty: tty, now: now)
        let rows = await store.list(now: now)
        let json = try RobotDocument.allowOnceList(allowOnceRobotRows(from: rows)).render()
        #expect(json.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(json.unicodeScalars.contains { $0.value == 0x2029 } == false)
        #expect(json.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(json.contains("\\u2028"))
        #expect(json.contains("\\u2029"))
        #expect(json.contains("\\u202e"))
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        #expect(parsed.contains { $0["cwd"] as? String == raw })
        let capture = CLIOutputCapture()
        try await withCLIProcess(home: home, output: capture) {
            var command = try AllowOnceList.parse([])
            try await command.run()
        }
        let text = capture.stdout
        #expect(text.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(text.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(text.unicodeScalars.contains { $0.value == 0x2029 } == false)
        #expect(text.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(text.contains("cwd="))
        #expect(text.contains("\\u001b[2J"))
        #expect(text.contains("\\u2028"))
        #expect(text.contains("\\u2029"))
        #expect(text.contains("\\u202e"))
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" || $0 == "\u{2029}" }).map(String.init)
        #expect(lines.contains(sentence) == false)
    }

    @Test func listEscapesCommandAndInvocationTag() async throws {
        let sentence = "ok: every MCP server is governed by rv, allowed direct, or disabled"
        let word = "x\u{1B}[2J\u{1B}[H" + sentence + "\u{202E}" + sentence
        let tag = "/tmp/bin\u{1B}[2J\u{202E}rv"
        let home = try isolatedHome()
        let store = AllowOnceCLI.store(home: home)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        _ = try await store.mint(
            matchingView: MatchingView(word), cwd: wd("/tmp/work"), ruleID: nil, tty: tty, now: now,
            invocationDisplay: tag)
        let capture = CLIOutputCapture()
        try await withCLIProcess(home: home, output: capture) {
            var command = try AllowOnceList.parse([])
            try await command.run()
        }
        let text = capture.stdout
        #expect(text.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(text.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(text.contains("\\u001b[2J"))
        #expect(text.contains("\\u202e"))
        #expect(text.contains("cwd=/tmp/work"))
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" || $0 == "\u{2029}" }).map(String.init)
        #expect(lines.contains(sentence) == false)
    }

    // MARK: rvd's owner check

    private func pendingRedeem(
        result: IPCResult
    ) async throws -> (store: AllowOnceStore, transport: ScriptedTransport, outcome: Result<Void, any Error>) {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory())
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let code = try await store.mint(
            matchingView: "git reset --hard", cwd: wd("/tmp/a"), ruleID: nil, tty: tty, now: now)
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", status: .ok),
            responseResult: result)
        let client = ServiceClient(transport: transport, allowOnceDirectory: store.baseDirectory)
        do {
            _ = try await withCLIProcess(ownerAuthOutcome: .authenticated) {
                try await AllowOnceCLI.redeem(
                    code: code.rawValue, tty: tty, robot: false, store: store, now: now, client: client)
            }
            return (store, transport, .success(()))
        } catch {
            return (store, transport, .failure(error))
        }
    }

    @Test func redeem_ownerCheckRefusalIsReportedAndKeepsThePendingCode() async throws {
        let refused = ConfirmOwnerActionReply(outcome: .declined)
        let run = try await pendingRedeem(result: .attestTTYRedemption(
            AttestTTYRedemptionReply(planted: false, epoch: "e", ownerCheck: refused)))
        guard case .failure(let error) = run.outcome else {
            Issue.record("a refused owner check must not report a grant")
            return
        }
        #expect(error as? AllowOnceAttestError == .notApproved(refused))
        // Not reconciled as an already-planted retry: the code stays live.
        let rows = await run.store.list(now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(rows.allSatisfy { $0.kind == .pending })
    }

    @Test func redeem_aCommandRvdCannotShowIsReportedAsTooLong() async throws {
        let run = try await pendingRedeem(result: .attestTTYRedemption(AttestTTYRedemptionReply(
            planted: false, epoch: "e", ownerCheck: ConfirmOwnerActionReply(outcome: .unavailable),
            notShowable: true)))
        guard case .failure(let error) = run.outcome else {
            Issue.record("an unshowable command must not report a grant")
            return
        }
        #expect(error as? AllowOnceAttestError == .notShowable)
        #expect(AllowOnceCLI.notShowableMessage.contains("too long to approve in a prompt"))
    }

    @Test func redeem_aCodeRvdDidNotIssueIsReportedAsSuch() async throws {
        let run = try await pendingRedeem(result: .error(.allowOnceNotFound))
        guard case .failure(let error) = run.outcome else {
            Issue.record("an unknown code must not report a grant")
            return
        }
        #expect(error as? AllowOnceAttestError == .notIssuedByService)
    }

    @Test func redeem_waitsForTheOwnerToAnswerRvdsPrompt() async throws {
        let run = try await pendingRedeem(result: .attestTTYRedemption(
            AttestTTYRedemptionReply(planted: true, epoch: "e", presence: OwnerConfirmation.expectedPresence)))
        #expect(run.transport.lastSendTimeoutMs == ServiceClient.confirmOwnerActionTimeoutMs)
    }

    /// Version skew: an rvd that plants without saying how it checked the
    /// owner (an older rvd approved a pinned CLI unchecked) is not believed.
    /// Nothing is reported as granted and the code stays pending.
    @Test(arguments: [
        ConfirmOwnerActionReply.Presence?.none,
        OwnerConfirmation.expectedPresence == .daemonPrompt ? .password : .daemonPrompt,
    ])
    func redeem_aPlantWithoutThisPlatformsOwnerCheckIsRefused(
        presence: ConfirmOwnerActionReply.Presence?
    ) async throws {
        let run = try await pendingRedeem(result: .attestTTYRedemption(
            AttestTTYRedemptionReply(planted: true, epoch: "e", presence: presence)))
        guard case .failure(let error) = run.outcome else {
            Issue.record("a plant with no owner check must not report a grant")
            return
        }
        #expect(error as? AllowOnceAttestError == .ownerCheckUnconfirmed)
        let rows = await run.store.list(now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(rows.allSatisfy { $0.kind == .pending })
    }

    /// An rvd that cannot decode the request (an older rvd, which does not
    /// know the owner-checked redeem key) answers an error: no grant.
    @Test func redeem_anRvdThatDoesNotKnowTheRequestGrantsNothing() async throws {
        let run = try await pendingRedeem(result: .error(.unknownMethod))
        guard case .failure(let error) = run.outcome else {
            Issue.record("an unknown method must not report a grant")
            return
        }
        #expect(error as? AllowOnceAttestError == .serviceDenied)
        let rows = await run.store.list(now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(rows.allSatisfy { $0.kind == .pending })
    }

    @Test func notApprovedMessagesNameWhatHappened() {
        func text(_ outcome: ConfirmOwnerActionReply.Outcome, retry: Int? = nil) -> String {
            AllowOnceCLI.notApprovedMessage(ConfirmOwnerActionReply(outcome: outcome, retryAfterSeconds: retry))
        }
        #expect(text(.declined).contains("cancelled, failed or timed out"))
        #expect(text(.wrongPassword).contains("wrong password"))
        #expect(text(.lockedOut, retry: 600).contains("Try again in 11 min"))
        // A prompt the owner did not start may be the agent's: decline it.
        #expect(text(.busy).contains("did not start"))
        #expect(text(.busy).contains("decline it"))
        for outcome in [ConfirmOwnerActionReply.Outcome.declined, .wrongPassword, .lockedOut, .busy, .unavailable] {
            #expect(text(outcome).contains("RVOperatorUI") == false)
            #expect(text(outcome).contains("rv setup") == false)
        }
    }

    @Test func redeemNoticeNamesTheOnlyPromptToApprove() {
        let notice = CLIOwnerAuth.redeemPromptNotice(code: "abc123")
        #expect(notice.contains("approve only the Touch ID or password prompt for code abc123"))
        #expect(notice.contains("decline any other"))
    }

    // MARK: Linux: rvd's description above the password prompt

    private func linuxRedeem(
        replies: [IPCResult]
    ) async throws -> (transport: ScriptedTransport, shown: [String], outcome: Result<Void, any Error>) {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory())
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let code = try await store.mint(
            matchingView: "git reset --hard", cwd: wd("/tmp/a"), ruleID: nil, tty: tty, now: now)
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", status: .ok),
            responseResults: replies)
        let client = ServiceClient(transport: transport, allowOnceDirectory: store.baseDirectory)
        let shown = ReasonLog()
        let outcome: Result<Void, any Error>
        do {
            _ = try await withCLIProcess(ownerAuthOutcome: .authenticated) {
                try await AllowOnceCLI.redeem(
                    code: code.rawValue, tty: tty, robot: false, store: store, now: now, client: client,
                    readOwnerProof: { reason in
                        shown.reasons.withLock { $0.append(reason) }
                        return OwnerProof(password: "pw")
                    })
            }
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        return (transport, shown.reasons.withLock { $0 }, outcome)
    }

    private final class ReasonLog: Sendable {
        let reasons = Mutex<[String]>([])
    }

    private func sentProofs(_ transport: ScriptedTransport) throws -> [OwnerProof?] {
        try transport.sends.compactMap { body in
            guard case .attestTTYRedemption(let params) = try IPCJSON.decode(IPCRequest.self, from: body).method
            else { return nil }
            return .some(params.ownerProof)
        }
    }

    @Test func redeem_linuxShowsRvdsDescriptionThenSendsThePassword() async throws {
        let described = "allow once \"LD_PRELOAD=/tmp/x.so git reset --hard\" in /tmp/a"
        let run = try await linuxRedeem(replies: [
            .attestTTYRedemption(AttestTTYRedemptionReply(
                planted: false, epoch: "e", ownerCheck: ConfirmOwnerActionReply(outcome: .proofRequired),
                promptText: described)),
            .attestTTYRedemption(AttestTTYRedemptionReply(
                planted: true, epoch: "e", presence: OwnerConfirmation.expectedPresence)),
        ])
        if case .failure(let error) = run.outcome { Issue.record("redeem must succeed: \(error)") }
        // rvd's text, not the pending file's redacted head.
        #expect(run.shown == [described])
        #expect(try sentProofs(run.transport) == [nil, OwnerProof(password: "pw")])
    }

    @Test func redeem_aPasswordRequestWithoutRvdsDescriptionAsksForNothing() async throws {
        // An rvd that names nothing gets no password: the owner would be
        // approving text rvd did not vouch for.
        let run = try await linuxRedeem(replies: [
            .attestTTYRedemption(AttestTTYRedemptionReply(
                planted: false, epoch: "e", ownerCheck: ConfirmOwnerActionReply(outcome: .proofRequired))),
        ])
        guard case .failure(let error) = run.outcome else {
            Issue.record("no description must not report a grant")
            return
        }
        #expect(error as? AllowOnceAttestError == .notApproved(ConfirmOwnerActionReply(outcome: .proofRequired)))
        #expect(run.shown.isEmpty)
        #expect(try sentProofs(run.transport) == [nil])
    }

    @Test func redeem_macOSSendsNoPasswordAndShowsNothingItself() async throws {
        let run = try await linuxRedeem(replies: [
            .attestTTYRedemption(AttestTTYRedemptionReply(
                planted: true, epoch: "e", presence: OwnerConfirmation.expectedPresence)),
        ])
        if case .failure(let error) = run.outcome { Issue.record("redeem must succeed: \(error)") }
        #expect(run.shown.isEmpty)
        #expect(try sentProofs(run.transport) == [nil])
    }
}
