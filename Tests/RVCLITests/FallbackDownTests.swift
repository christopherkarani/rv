import Testing
@testable import RVCLI

struct FallbackDownTests {
    @Test func missingListenerEvaluatesInProcessAndDeniesResetHard() async {
        let client = ServiceClient(transport: nil)
        let reply = await client.evaluate(command: "git reset --hard")
        #expect(reply.decision == "deny")
        #expect(reply.ruleID == "core.git:reset-hard")
        #expect(reply.via == "inProcess")
        #expect(reply.decision != "allow")
    }

    @Test func uncompilableResetHardIsIndeterminateNotAllow() async {
        let client = ServiceClient.uncompilableCore()
        let reply = await client.evaluate(command: "git reset --hard")
        #expect(reply.decision == "indeterminate")
        #expect(reply.indeterminateReason == "corePacksUnavailable")
        #expect(reply.decision != "allow")
    }

    @Test func missingCoreIsIndeterminateNotAllow() async {
        let client = ServiceClient.missingCore()
        let reply = await client.evaluate(command: "git reset --hard")
        #expect(reply.decision == "indeterminate")
        #expect(reply.indeterminateReason == "corePacksUnavailable")
        #expect(reply.decision != "allow")
    }

    @Test func midCallInterruptFallsBackAndStillDenies() async {
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", ok: true),
            sendError: .interrupted
        )
        let client = ServiceClient(transport: transport)
        let reply = await client.evaluate(command: "git reset --hard")
        #expect(reply.decision == "deny")
        #expect(reply.ruleID == "core.git:reset-hard")
        #expect(reply.via == "inProcess")
        #expect(transport.sendCount == 1)
    }
}
