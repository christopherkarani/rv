import Foundation
import Testing
import RVDomain
import RVHooks
import RVIPC
import RVPolicy
@testable import RVCLI

struct AllowOnceGrantHonorTests {
    @Test func peekDoesNotSpendGrantAndHookMissConsumesOnce() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let client = try isolatedClient(transport: nil, allowOnceDirectory: directory)
        try await client.insertGranted(matchingView: "git reset --hard", cwd: wd("/tmp/ws"))

        let peeked = try await cliEvaluate("git reset --hard", allowOnceDirectory: directory)
        #expect(peeked.decision == .allow)
        let first = await client.evaluateResult(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd("/tmp/ws")
        )
        #expect(first.decision == .allow)

        let second = await client.evaluateResult(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd("/tmp/ws")
        )
        guard case .deny(let deny) = second.decision else {
            Issue.record("second hook-miss evaluate must deny after the grant is spent")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }

    @Test func hookMissingCwdDoesNotHonorProcessDirectoryGrant() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let processCwd = FileManager.default.currentDirectoryPath
        let client = try isolatedClient(transport: nil, allowOnceDirectory: directory)
        try await client.insertGranted(matchingView: "git reset --hard", cwd: wd(processCwd))

        let stdin = """
        {"hookEventName":"pre_tool_use","toolName":"run_terminal_command","toolInput":{"command":"git reset --hard"}}
        """
        let wire = await hookWire(
            host: .grok,
            stdin: stdin
        ) { command, cwd in
            await client.evaluateResult(command: command, cwd: cwd)
        }
        #expect(wire.stdout.isEmpty == false)
        let object = try JSONSerialization.jsonObject(with: Data(wire.stdout.utf8))
        let json = try #require(object as? [String: Any])
        #expect(json["decision"] as? String == "deny")

        let honored = await client.evaluateResult(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd(processCwd)
        )
        #expect(honored.decision == .allow)
    }

    @Test func hookPresentCwdHonorsGrantOnce() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let client = try isolatedClient(transport: nil, allowOnceDirectory: directory)
        try await client.insertGranted(matchingView: "git reset --hard", cwd: wd("/tmp/ws"))

        let stdin = """
        {"hookEventName":"pre_tool_use","cwd":"/tmp/ws","toolName":"run_terminal_command","toolInput":{"command":"git reset --hard"}}
        """
        let wire = await hookWire(
            host: .grok,
            stdin: stdin
        ) { command, cwd in
            await client.evaluateResult(command: command, cwd: cwd)
        }
        #expect(wire.stdout.isEmpty)
        #expect(wire.exitCode == 0)
        #expect(wire.stdout.contains("\"decision\":\"deny\"") == false)

        let second = await client.evaluateResult(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd("/tmp/ws")
        )
        guard case .deny(let deny) = second.decision else {
            Issue.record("second evaluate must deny after the grant is spent")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }

    @Test func xpcEvaluateSuccessDoesNotApplyLocalGrant() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let storeClient = try isolatedClient(transport: nil, allowOnceDirectory: directory)
        try await storeClient.insertGranted(matchingView: "git reset --hard", cwd: wd("/tmp/ws"))

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
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", status: .ok),
            responseResult: .evaluate(EvaluateReply(result: denied))
        )
        let client = try isolatedClient(transport: transport, allowOnceDirectory: directory)
        let reply = await client.evaluate(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd("/tmp/ws")
        )
        #expect(reply.path == .xpc)
        try #require(denyPayload(from: reply.result.decision) != nil)
        #expect(transport.sendCount == 1)

        let honored = await storeClient.evaluateResult(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd("/tmp/ws")
        )
        #expect(honored.decision == .allow)
    }

    @Test func grokHookEvaluateMintsPendingThenTTYRedeemSpendsOnce() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let client = ServiceClient(
            transport: nil,
            allowOnceDirectory: directory,
            home: try isolatedHome(),
            clock: { now }
        )
        let stdin = """
        {"hookEventName":"pre_tool_use","cwd":"/tmp/ws","toolName":"run_terminal_command","toolInput":{"command":"git reset --hard"}}
        """
        let wire = await client.hookEvaluate(host: .grok, stdin: stdin)
        let json = try #require(JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any])
        #expect(json["decision"] as? String == "deny")
        let reason = try #require(json["reason"] as? String)
        let code = try #require(allowOnceUnlockCode(in: reason))
        #expect(json["next"] as? String == "Run it in Terminal, or rv allow-once \(code).")
        let store = AllowOnceStore(baseDirectory: directory)
        #expect((await store.list(now: now)).contains { $0.kind == .pending })

        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        _ = try await store.redeem(code: code, tty: tty, now: now)
        let first = await client.evaluateResult(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd("/tmp/ws")
        )
        #expect(first.decision == .allow)
        let second = await client.evaluateResult(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd("/tmp/ws")
        )
        guard case .deny = second.decision else {
            Issue.record("second apply after consume must deny")
            return
        }
    }

    @Test func grokHookEvaluateMissingCwdDoesNotMint() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let client = ServiceClient(
            transport: nil,
            allowOnceDirectory: directory,
            home: try isolatedHome(),
            clock: { now }
        )
        let stdin = """
        {"hookEventName":"pre_tool_use","toolName":"run_terminal_command","toolInput":{"command":"git reset --hard"}}
        """
        let wire = await client.hookEvaluate(host: .grok, stdin: stdin)
        let json = try #require(JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any])
        #expect(json["decision"] as? String == "deny")
        #expect(allowOnceUnlockCode(in: wire.stdout) == nil)
        #expect(json["next"] == nil)
        #expect((await AllowOnceStore(baseDirectory: directory).list(now: now)).isEmpty)
    }

    @Test func grokHookEvaluateWithoutHomeDoesNotMint() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let client = ServiceClient(
            transport: nil,
            allowOnceDirectory: directory,
            home: nil,
            clock: { now }
        )
        let stdin = """
        {"hookEventName":"pre_tool_use","cwd":"/tmp/ws","toolName":"run_terminal_command","toolInput":{"command":"git reset --hard"}}
        """
        let wire = await client.hookEvaluate(host: .grok, stdin: stdin)
        let json = try #require(JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any])
        #expect(json["decision"] as? String == "deny")
        #expect(allowOnceUnlockCode(in: wire.stdout) == nil)
        #expect(json["next"] == nil)
        #expect((await AllowOnceStore(baseDirectory: directory).list(now: now)).isEmpty)
    }

    @Test func peekDoesNotMintPending() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let peeked = try await cliEvaluate("git reset --hard", allowOnceDirectory: directory)
        guard case .deny = peeked.decision else {
            Issue.record("peek without grant must deny")
            return
        }
        #expect((await AllowOnceStore(baseDirectory: directory).list(now: Date())).isEmpty)
    }
}
