import Foundation
import Testing
import RVDomain
import RVHooks
import RVIPC
@testable import RVCLI

struct OneShotEvaluateClientTests {
    @Test func hookEvaluateIsOneSendWhenClientSemverIsSet_budgetIsConnect200PlusRequest500Equals700Ms() async throws {
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
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", ok: true),
            responseResult: .evaluate(EvaluateReply(result: denied))
        )
        let client = try isolatedClient(transport: transport)
        let reply = await client.evaluate(command: ShellCommand(rawValue: "git reset --hard"))
        #expect(reply.path == .xpc)
        try #require(denyPayload(from: reply.result.decision) != nil)
        #expect(transport.sendCount == 1)
        #expect(transport.helloCount == 0)
        #expect(transport.lastSendTimeoutMs == 700)

        let sent = try #require(transport.sends.first)
        let request = try IPCJSON.decode(IPCRequest.self, from: sent)
        guard case .evaluate(let params) = request.method else {
            Issue.record("one-shot body must be evaluate")
            return
        }
        #expect(params.clientSemver == ProtocolVersion.serviceSemver)

        let defaults = XPCServiceTransport()
        #expect(defaults.connectTimeoutMs == 200)
        #expect(defaults.requestTimeoutMs == 500)
        #expect(defaults.oneShotEvaluateTimeoutMs == 700)
    }

    @Test func skewedImplicitHelloFallsBackInProcessAndStillDeniesResetHard() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(
                protocolName: "rv.ipc.v1",
                serviceSemver: "1.0.0",
                ok: true
            ),
            responseResult: .error(.protocolSkew(.protocolSkew))
        )
        let client = try isolatedClient(transport: transport)
        let reply = await client.evaluate(command: ShellCommand(rawValue: "git reset --hard"))
        let deny = try #require(denyPayload(from: reply.result.decision))
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(reply.path == .inProcess)
        #expect(transport.sendCount == 1)
        #expect(transport.helloCount == 0)
        #expect(transport.invalidationCount == 1)
    }

    @Test func downListenerFallsBackInProcessAndStillDeniesResetHard() async throws {
        let client = try isolatedClient(transport: nil)
        let reply = await client.evaluate(command: ShellCommand(rawValue: "git reset --hard"))
        let deny = try #require(denyPayload(from: reply.result.decision))
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(reply.path == .inProcess)
    }

    @Test func oneShotXPCStashDrop_isEmptyAllowOnHookCodec() async throws {
        let allowed = EvaluationResult(
            outcome: .plain,
            matchingView: "git stash drop"
        )
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", ok: true),
            responseResult: .evaluate(EvaluateReply(result: allowed))
        )
        let client = try isolatedClient(transport: transport)
        let stdinURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("RVHooksTests/Fixtures/grok/allow-medium-stash-drop.json")
        let stdin = try String(contentsOf: stdinURL, encoding: .utf8)
        let wire = await hookWire(host: .grok, stdin: stdin) { command, cwd in
            await client.evaluateResult(command: command, cwd: cwd)
        }
        #expect(wire.stdout.isEmpty)
        #expect(wire.exitCode == 0)
        #expect(wire.stdout.contains("deny") == false)
        #expect(transport.sendCount == 1)
        #expect(transport.helloCount == 0)
    }

    @Test func statusAndDiagnosticsStillHelloFirst() async throws {
        let snapshot = DoctorSnapshotReply(
            state: .running,
            idleExitSeconds: 300,
            packsEnabled: [.coreGit, .coreFilesystem],
            checks: [DoctorCheck(id: .xpc, status: .ok, message: "listener")]
        )
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", ok: true),
            responseResult: .doctorSnapshot(snapshot)
        )
        let client = try isolatedClient(transport: transport)
        _ = await client.status()
        #expect(transport.helloCount == 1)
        #expect(transport.sendCount == 1)
    }
}
