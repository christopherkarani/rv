import Testing
import RVDomain
@testable import RVCLI

struct FallbackSkewTests {
    @Test func skewedHelloDoesNotSendEvaluateAndStillDenies() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(
                protocolName: "rv.ipc.v0",
                serviceSemver: "1.0.0",
                ok: false,
                skewReason: "protocol"
            )
        )
        let client = try isolatedClient(transport: transport)
        let reply = await client.evaluate(command: "git reset --hard")
        guard case .deny(let deny) = reply.result.decision else {
            Issue.record("expected deny")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(reply.path == .inProcess)
        #expect(transport.sendCount == 0)

        let status = await client.status()
        #expect(status.state == "skew")
        #expect(status.fallback == "skew")
        #expect(status.keepAlive == false)
    }

    @Test func majorSemverMismatchIsSkew() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "2.0.0", ok: true)
        )
        let client = try isolatedClient(transport: transport)
        let reply = await client.evaluate(command: "git reset --hard")
        #expect(reply.path == .inProcess)
        guard case .deny = reply.result.decision else {
            Issue.record("expected deny")
            return
        }
        #expect(transport.sendCount == 0)
        let status = await client.status()
        #expect(status.state == "skew")
    }
}
