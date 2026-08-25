import Foundation
import Synchronization
import Testing
import RVDomain
import RVIPC
import RVService
@testable import RVCLI

struct LazyFallbackTests {
    private let resetHard = ShellCommand(rawValue: "git reset --hard")

    @Test func answeringTransportNeverBuildsInProcessSession() async throws {
        let allowed = EvaluationResult(outcome: .plain, matchingView: MatchingView(resetHard.rawValue))
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", ok: true),
            responseResult: .evaluate(EvaluateReply(result: allowed))
        )
        let sessions = Mutex(0)
        let client = try isolatedClient(transport: transport) {
            sessions.withLock { $0 += 1 }
            return EvaluateSession()
        }
        let reply = await client.evaluate(command: resetHard)
        #expect(reply.path == .xpc)
        #expect(sessions.withLock { $0 } == 0)
        #expect(transport.sendCount == 1)
    }

    @Test func missingListenerBuildsSessionExactlyOncePerInProcessRoute() async throws {
        let sessions = Mutex(0)
        let client = try isolatedClient(transport: nil) {
            sessions.withLock { $0 += 1 }
            return EvaluateSession()
        }
        let reply = await client.evaluate(command: resetHard)
        let deny = try #require(denyPayload(from: reply.result.decision))
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(reply.path == .inProcess)
        #expect(sessions.withLock { $0 } == 1)
    }

    @Test func sendFailureBuildsSessionExactlyOnceOnFallback() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", ok: true),
            sendError: .interrupted
        )
        let sessions = Mutex(0)
        let client = try isolatedClient(transport: transport) {
            sessions.withLock { $0 += 1 }
            return EvaluateSession()
        }
        let reply = await client.evaluate(command: resetHard)
        let deny = try #require(denyPayload(from: reply.result.decision))
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(reply.path == .inProcess)
        #expect(transport.sendCount == 1)
        #expect(sessions.withLock { $0 } == 1)
    }
}
