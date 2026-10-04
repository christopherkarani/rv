import Foundation
import Testing
import RVDomain
import RVHooks
import RVIPC
import RVPolicy
@testable import RVCLI

struct AllowOnceGrantHonorTests {
    @Test func peekAndHookMissDenyDespiteFileGrant() async throws {
        // Step 8B.1: a granted projection row on disk is not authority.
        // CLI peeks and diagnostic evaluates deny throughout.
        let directory = try isolatedAllowOnceDirectory()
        let client = try isolatedClient(transport: nil, allowOnceDirectory: directory)
        try await plantGrantedProjection(directory: directory)

        let peeked = try await cliEvaluate("git reset --hard", allowOnceDirectory: directory)
        guard case .deny = peeked.decision else {
            Issue.record("CLI peek must deny despite the file row")
            return
        }
        let first = await client.evaluateResult(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd("/tmp/ws")
        )
        guard case .deny(let deny) = first.decision else {
            Issue.record("hook-miss evaluate must deny despite the file row")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")

        let second = await client.evaluateResult(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd("/tmp/ws")
        )
        guard case .deny = second.decision else {
            Issue.record("repeat evaluate must deny")
            return
        }
    }

    @Test func hookMissingCwdDeniesAndProcessDirectoryGrantNeverHonors() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let processCwd = FileManager.default.currentDirectoryPath
        let client = try isolatedClient(transport: nil, allowOnceDirectory: directory)
        try await plantGrantedProjection(directory: directory, cwd: processCwd)

        let stdin = """
        {"hookEventName":"pre_tool_use","toolName":"run_terminal_command","toolInput":{"command":"git reset --hard"}}
        """
        let wire = await hookWire(
            host: .grok,
            stdin: stdin,
            world: hookWorld { command, cwd in
                await client.evaluateResult(command: command, cwd: cwd)
            }
        )
        #expect(wire.stdout.isEmpty == false)
        let object = try JSONSerialization.jsonObject(with: Data(wire.stdout.utf8))
        let json = try #require(object as? [String: Any])
        #expect(json["decision"] as? String == "deny")

        let honored = await client.evaluateResult(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd(processCwd)
        )
        guard case .deny = honored.decision else {
            Issue.record("process-cwd file row must never honor")
            return
        }
    }

    @Test func hookPresentCwdDeniesWithoutDaemonGrant() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let client = try isolatedClient(transport: nil, allowOnceDirectory: directory)
        try await plantGrantedProjection(directory: directory)

        let stdin = """
        {"hookEventName":"pre_tool_use","cwd":"/tmp/ws","toolName":"run_terminal_command","toolInput":{"command":"git reset --hard"}}
        """
        let wire = await hookWire(
            host: .grok,
            stdin: stdin,
            world: hookWorld { command, cwd in
                await client.evaluateResult(command: command, cwd: cwd)
            }
        )
        #expect(wire.stdout.isEmpty == false)
        #expect(wire.stdout.contains("\"decision\":\"deny\""))

        let second = await client.evaluateResult(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd("/tmp/ws")
        )
        guard case .deny(let deny) = second.decision else {
            Issue.record("second evaluate must deny")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }

    @Test func xpcEvaluateSuccessDoesNotApplyLocalGrant() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let storeClient = try isolatedClient(transport: nil, allowOnceDirectory: directory)
        try await plantGrantedProjection(directory: directory)

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
        #expect(reply.path == .service)
        try #require(denyPayload(from: reply.result.decision) != nil)
        #expect(transport.sendCount == 1)

        let honored = await storeClient.evaluateResult(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd("/tmp/ws")
        )
        guard case .deny = honored.decision else {
            Issue.record("local file row must not honor after service deny")
            return
        }
    }

    @Test func grokHookEvaluateMintsPendingThenTTYRedeemWithoutDaemonSpendsNothing() async throws {
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
        #expect(json["next"] as? String == unlockLine(for: code))
        let store = AllowOnceStore(baseDirectory: directory)
        #expect((await store.list(now: now)).contains { $0.kind == .pending })

        // No daemon: the file redeem flips projection only and spends
        // nothing. The pending code path still fails closed.
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        _ = try await store.redeem(code: code.rawValue, tty: tty, now: now)
        let first = await client.evaluateResult(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd("/tmp/ws")
        )
        guard case .deny = first.decision else {
            Issue.record("file redeem without daemon must not spend")
            return
        }
        let second = await client.evaluateResult(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd("/tmp/ws")
        )
        guard case .deny = second.decision else {
            Issue.record("second apply after consume must deny")
            return
        }
    }

    @Test func grokHookEvaluate_sameCommandReusesUnlockCode() async throws {
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
        let first = await client.hookEvaluate(host: .grok, stdin: stdin)
        let firstJSON = try #require(JSONSerialization.jsonObject(with: Data(first.stdout.utf8)) as? [String: Any])
        let firstReason = try #require(firstJSON["reason"] as? String)
        let code = try #require(allowOnceUnlockCode(in: firstReason))
        #expect(firstJSON["next"] as? String == unlockLine(for: code))

        let second = await client.hookEvaluate(host: .grok, stdin: stdin)
        let secondJSON = try #require(JSONSerialization.jsonObject(with: Data(second.stdout.utf8)) as? [String: Any])
        let secondReason = try #require(secondJSON["reason"] as? String)
        #expect(allowOnceUnlockCode(in: secondReason) == code)
        #expect(secondJSON["next"] as? String == unlockLine(for: code))
        #expect((await AllowOnceStore(baseDirectory: directory).list(now: now)).count == 1)
    }

    @Test func cursorHookEvaluate_agentMessageTellsAgentNotToRetry() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let client = ServiceClient(
            transport: nil,
            allowOnceDirectory: directory,
            home: try isolatedHome(),
            clock: { now }
        )
        let stdin = """
        {"hook_event_name":"beforeShellExecution","cwd":"/tmp/ws","command":"git reset --hard"}
        """
        let wire = await client.hookEvaluate(host: .cursor, stdin: stdin)
        let json = try #require(JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any])
        #expect(json["permission"] as? String == "deny")
        let user = try #require(json["user_message"] as? String)
        #expect(allowOnceUnlockCode(in: user) != nil)
        #expect(user.contains("This unlocks the reviewed command once, including its sudo, env, and path spellings."))
        #expect(json["agent_message"] as? String == cursorAgentStopLine)
        #expect(allowOnceUnlockCode(in: json["agent_message"] as? String ?? "") == nil)
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

/// Step 8B.1: writes a granted *projection* row (mint + file redeem).
/// Display-only: no ceremony ran, so no memory grant exists and nothing
/// may spend.
private func plantGrantedProjection(directory: URL, cwd: String = "/tmp/ws") async throws {
    let store = AllowOnceStore(baseDirectory: directory)
    let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
    let code = try await store.mint(
        matchingView: "git reset --hard",
        cwd: wd(cwd),
        ruleID: nil,
        tty: tty,
        now: Date()
    )
    _ = try await store.redeem(code: code.rawValue, tty: tty, now: Date())
}
