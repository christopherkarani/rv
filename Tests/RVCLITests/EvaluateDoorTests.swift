import Foundation
import Testing
import RVDomain
@testable import RVCLI

struct EvaluateDoorTests {
    @Test func ttyPeekLeavesGrantUnspentThenInProcessApplyConsumesOnce() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let client = try isolatedClient(transport: nil, allowOnceDirectory: directory)
        try await client.insertGranted(matchingView: "git reset --hard", cwd: wd("/tmp/ws"))

        let firstPeek = try await cliEvaluate("git reset --hard", allowOnceDirectory: directory)
        #expect(firstPeek.decision == .allow)
        let secondPeek = try await cliEvaluate("git reset --hard", allowOnceDirectory: directory)
        #expect(secondPeek.decision == .allow)

        let applied = await client.evaluate(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd("/tmp/ws")
        )
        #expect(applied.result.decision == .allow)
        #expect(applied.path == .inProcess)
        let spent = await client.evaluateResult(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd("/tmp/ws")
        )
        let deny = try #require(denyPayload(from: spent.decision))
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }

    @Test func downFallbackAppliesInProcessAndStillDenies() async throws {
        let client = try isolatedClient(transport: nil)
        let reply = await client.evaluate(command: ShellCommand(rawValue: "git reset --hard"))
        let deny = try #require(denyPayload(from: reply.result.decision))
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(reply.path == .inProcess)
    }
}
