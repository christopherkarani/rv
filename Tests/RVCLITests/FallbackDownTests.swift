import Foundation
import Testing
import RVDomain
import RVIPC
@testable import RVCLI

struct FallbackDownTests {
    @Test func missingListenerEvaluatesInProcessAndDeniesResetHard() async throws {
        let client = try isolatedClient(transport: nil)
        let reply = await client.evaluate(command: "git reset --hard")
        guard case .deny(let deny) = reply.result.decision else {
            Issue.record("expected deny")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(reply.path == .inProcess)
    }

    @Test func uncompilableResetHardIsIndeterminateNotAllow() async {
        let client = ServiceClient.uncompilableCore()
        let reply = await client.evaluate(command: "git reset --hard")
        guard case .indeterminate(let reason) = reply.result.decision else {
            Issue.record("expected indeterminate")
            return
        }
        #expect(reason == .corePacksUnavailable)
        #expect(reply.path == .inProcess)
    }

    @Test func missingCoreIsIndeterminateNotAllow() async {
        let client = ServiceClient.missingCore()
        let reply = await client.evaluate(command: "git reset --hard")
        guard case .indeterminate(let reason) = reply.result.decision else {
            Issue.record("expected indeterminate")
            return
        }
        #expect(reason == .corePacksUnavailable)
        #expect(reply.path == .inProcess)
    }

    @Test func unexpectedEvaluateViaFallsBackInProcessAndStillDenies() async throws {
        let spoofedAllow = EvaluationResult(
            decision: .allow,
            matchingView: "git reset --hard"
        )
        let body = try IPCJSON.encode(
            IPCResponse(
                id: UUID(),
                result: .evaluate(EvaluateReply(result: spoofedAllow, via: "inProcess"))
            )
        )
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", ok: true),
            sendReply: body
        )
        let client = try isolatedClient(transport: transport)
        let reply = await client.evaluate(command: "git reset --hard")
        guard case .deny(let deny) = reply.result.decision else {
            Issue.record("expected in-process deny after unexpected via")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(reply.path == .inProcess)
        #expect(transport.sendCount == 1)
    }

    @Test func midCallInterruptFallsBackAndStillDenies() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", ok: true),
            sendError: .interrupted
        )
        let client = try isolatedClient(transport: transport)
        let reply = await client.evaluate(command: "git reset --hard")
        guard case .deny(let deny) = reply.result.decision else {
            Issue.record("expected deny")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(reply.path == .inProcess)
        #expect(transport.sendCount == 1)
    }
}
