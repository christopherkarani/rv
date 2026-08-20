import Foundation
import Testing
import RVDomain
import RVHooks
import RVIPC
@testable import RVCLI

struct AllowOnceGrantHonorTests {
    @Test func peekDoesNotSpendGrantAndHookMissConsumesOnce() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let client = try isolatedClient(transport: nil, allowOnceDirectory: directory)
        try await client.insertGranted(matchingView: "git reset --hard", cwd: "/tmp/ws")

        let peeked = try await cliEvaluate("git reset --hard", allowOnceDirectory: directory)
        #expect(peeked.decision == .allow)
        let first = await client.evaluateResult(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: "/tmp/ws"
        )
        #expect(first.decision == .allow)

        let second = await client.evaluateResult(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: "/tmp/ws"
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
        try await client.insertGranted(matchingView: "git reset --hard", cwd: processCwd)

        let stdin = """
        {"hookEventName":"pre_tool_use","toolName":"run_terminal_command","toolInput":{"command":"git reset --hard"}}
        """
        let wire = await HookRun.run(
            stdin: stdin,
            codec: GrokHostCodec()
        ) { command, cwd in
            await client.evaluateResult(command: command, cwd: cwd)
        }
        #expect(wire.stdout.isEmpty == false)
        let object = try JSONSerialization.jsonObject(with: Data(wire.stdout.utf8))
        let json = try #require(object as? [String: Any])
        #expect(json["decision"] as? String == "deny")

        let honored = await client.evaluateResult(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: processCwd
        )
        #expect(honored.decision == .allow)
    }

    @Test func xpcEvaluateSuccessDoesNotApplyLocalGrant() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let storeClient = try isolatedClient(transport: nil, allowOnceDirectory: directory)
        try await storeClient.insertGranted(matchingView: "git reset --hard", cwd: "/tmp/ws")

        let denied = EvaluationResult(
            decision: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                    reason: "git reset --hard destroys uncommitted changes"
                )
            ),
            matchingView: "git reset --hard"
        )
        let body = try IPCJSON.encode(
            IPCResponse(
                id: UUID(),
                result: .evaluate(EvaluateReply(result: denied, via: "xpc"))
            )
        )
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", ok: true),
            sendReply: body
        )
        let client = try isolatedClient(transport: transport, allowOnceDirectory: directory)
        let reply = await client.evaluate(command: "git reset --hard", cwd: "/tmp/ws")
        #expect(reply.via == "xpc")
        #expect(reply.decision == "deny")
        #expect(transport.sendCount == 1)

        let honored = await storeClient.evaluateResult(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: "/tmp/ws"
        )
        #expect(honored.decision == .allow)
    }
}
