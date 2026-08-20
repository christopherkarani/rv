import Testing
import RVDomain
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
        #expect(reply.result.decision != .allow)
    }

    @Test func uncompilableResetHardIsIndeterminateNotAllow() async {
        let client = ServiceClient.uncompilableCore()
        let reply = await client.evaluate(command: "git reset --hard")
        guard case .indeterminate(let reason) = reply.result.decision else {
            Issue.record("expected indeterminate")
            return
        }
        #expect(reason == .corePacksUnavailable)
        #expect(reply.result.decision != .allow)
    }

    @Test func missingCoreIsIndeterminateNotAllow() async {
        let client = ServiceClient.missingCore()
        let reply = await client.evaluate(command: "git reset --hard")
        guard case .indeterminate(let reason) = reply.result.decision else {
            Issue.record("expected indeterminate")
            return
        }
        #expect(reason == .corePacksUnavailable)
        #expect(reply.result.decision != .allow)
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
