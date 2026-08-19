import Foundation
import Testing
import RVDomain
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
}
