import Foundation
import Testing
import RVDomain
import RVIPC
@testable import RVCLI

struct FallbackDownTests {
    private let resetHard = ShellCommand(rawValue: "git reset --hard")

    @Test func missingListenerEvaluatesInProcessAndDeniesResetHard() async throws {
        let client = try isolatedClient(transport: nil)
        let reply = await client.evaluate(command: resetHard)
        let deny = try #require(denyPayload(from: reply.result.decision))
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(reply.path == .inProcess)
    }

    @Test func uncompilableResetHardIsIndeterminateNotAllow() async throws {
        let client = ServiceClient.uncompilableCore()
        let reply = await client.evaluate(command: resetHard)
        let reason = try #require(indeterminateReason(from: reply.result.decision))
        #expect(reason == .corePacksUnavailable)
        #expect(reply.path == .inProcess)
    }

    @Test func missingCoreIsIndeterminateNotAllow() async throws {
        let client = ServiceClient.missingCore()
        let reply = await client.evaluate(command: resetHard)
        let reason = try #require(indeterminateReason(from: reply.result.decision))
        #expect(reason == .corePacksUnavailable)
        #expect(reply.path == .inProcess)
    }

    @Test func unexpectedEvaluateViaFallsBackInProcessAndStillDenies() async throws {
        let spoofedAllow = EvaluationResult(
            outcome: .plain,
            matchingView: MatchingView(resetHard.rawValue)
        )
        let body = try spoofedEvaluateResponse(result: spoofedAllow, via: "inProcess")
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", ok: true),
            sendReply: body
        )
        let client = try isolatedClient(transport: transport)
        let reply = await client.evaluate(command: resetHard)
        let deny = try #require(denyPayload(from: reply.result.decision))
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(reply.path == .inProcess)
        #expect(transport.sendCount == 1)
    }

    @Test func bogusEvaluateViaFallsBackInProcessAndStillDenies() async throws {
        let spoofedAllow = EvaluationResult(
            outcome: .plain,
            matchingView: MatchingView(resetHard.rawValue)
        )
        let body = try spoofedEvaluateResponse(result: spoofedAllow, via: "bogus")
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", ok: true),
            sendReply: body
        )
        let client = try isolatedClient(transport: transport)
        let reply = await client.evaluate(command: resetHard)
        let deny = try #require(denyPayload(from: reply.result.decision))
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(reply.path == .inProcess)
        #expect(transport.sendCount == 1)
    }

    private func spoofedEvaluateResponse(result: EvaluationResult, via: String) throws -> Data {
        let valid = try IPCJSON.encode(
            IPCResponse(id: UUID(), result: .evaluate(EvaluateReply(result: result)))
        )
        var object = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var resultObject = try #require(object["result"] as? [String: Any])
        var evaluate = try #require(resultObject["evaluate"] as? [String: Any])
        evaluate["via"] = via
        resultObject["evaluate"] = evaluate
        object["result"] = resultObject
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func midCallInterruptFallsBackAndStillDenies() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", ok: true),
            sendError: .interrupted
        )
        let client = try isolatedClient(transport: transport)
        let reply = await client.evaluate(command: resetHard)
        let deny = try #require(denyPayload(from: reply.result.decision))
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(reply.path == .inProcess)
        #expect(transport.sendCount == 1)
    }
}
