import Foundation
import Testing
import RVDomain
import RVIPC
import RVPresentation
@testable import RVCLI

struct FallbackSkewTests {
    @Test func skewedHelloDoesNotSendEvaluateAndStillDenies() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(
                protocolName: "rv.ipc.v0",
                serviceSemver: "1.0.0",
                ok: false,
                skewReason: .protocolSkew
            )
        )
        let client = try isolatedClient(transport: transport)
        let reply = await client.evaluate(command: ShellCommand(rawValue: "git reset --hard"))
        let deny = try #require(denyPayload(from: reply.result.decision))
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(reply.path == .inProcess)
        #expect(transport.sendCount == 1)
        #expect(transport.helloCount == 0)

        let health = ServiceHealth.inspect(await client.diagnostics())
        #expect(
            health == .skew(
                reason: .protocolMismatch,
                source: .local(
                    .init(
                        corePacksReady: true,
                        serviceSemver: "1.0.0",
                        launchAgent: .missing
                    )
                )
            )
        )

        let status = await client.status()
        #expect(status.state == "skew")
        #expect(status.fallback == "skew")
        #expect(status.keepAlive == false)
    }

    @Test func unprovableServiceSemverReplyFallsBackInProcessAndInvalidates() async throws {
        let allowed = EvaluationResult(outcome: .plain, matchingView: "git reset --hard")
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", ok: true),
            responseResult: .evaluate(EvaluateReply(result: allowed, serviceSemver: nil))
        )
        let client = try isolatedClient(transport: transport)
        let reply = await client.evaluate(command: ShellCommand(rawValue: "git reset --hard"))
        try #require(denyPayload(from: reply.result.decision) != nil)
        #expect(reply.path == .inProcess)
        #expect(transport.sendCount == 1)
        #expect(transport.helloCount == 0)
        #expect(transport.invalidationCount == 1)
    }

    @Test func majorSemverMismatchIsSkew() async throws {
        let allowed = EvaluationResult(outcome: .plain, matchingView: "git reset --hard")
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "2.0.0", ok: true),
            responseResult: .evaluate(EvaluateReply(result: allowed, serviceSemver: "2.0.0"))
        )
        let client = try isolatedClient(transport: transport)
        let reply = await client.evaluate(command: ShellCommand(rawValue: "git reset --hard"))
        #expect(reply.path == .inProcess)
        try #require(denyPayload(from: reply.result.decision) != nil)
        #expect(transport.sendCount == 1)
        #expect(transport.helloCount == 0)
        let status = await client.status()
        #expect(status.state == "skew")
    }

    @Test func mismatchedEvaluateResponseIDFallsBackInProcess() async throws {
        let allowed = EvaluationResult(outcome: .plain, matchingView: "git status")
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", ok: true),
            responseResult: .evaluate(EvaluateReply(result: allowed)),
            responseID: UUID()
        )
        let client = try isolatedClient(transport: transport)

        let reply = await client.evaluate(command: ShellCommand(rawValue: "git status"))

        #expect(reply.path == .inProcess)
        #expect(transport.invalidationCount == 1)
    }

    @Test func mismatchedEvaluateResponseProtocolFallsBackInProcess() async throws {
        let allowed = EvaluationResult(outcome: .plain, matchingView: "git status")
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", ok: true),
            responseResult: .evaluate(EvaluateReply(result: allowed)),
            responseProtocolName: "rv.ipc.v0"
        )
        let client = try isolatedClient(transport: transport)

        let reply = await client.evaluate(command: ShellCommand(rawValue: "git status"))

        #expect(reply.path == .inProcess)
        #expect(transport.invalidationCount == 1)
    }
}
