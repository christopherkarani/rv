import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVService

struct EvaluateDoorTests {
    @Test func runPeekDoesNotSpendGrantThenApplyDoes() async throws {
        let store = try isolatedDoorStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let door = GatedEvaluate()
        let command = ShellCommand(rawValue: "git reset --hard")
        try await store.insertGranted(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)

        let peeked = await door.run(
            .peek,
            command: command,
            cwd: "/tmp/ws",
            home: "",
            store: store,
            now: now
        )
        #expect(peeked.decision == .allow)
        let peekedAgain = await door.run(
            .peek,
            command: command,
            cwd: "/tmp/ws",
            home: "",
            store: store,
            now: now
        )
        #expect(peekedAgain.decision == .allow)

        let first = await door.run(
            .apply,
            command: command,
            cwd: "/tmp/ws",
            home: "",
            store: store,
            now: now
        )
        #expect(first.decision == .allow)
        let second = await door.run(
            .apply,
            command: command,
            cwd: "/tmp/ws",
            home: "",
            store: store,
            now: now
        )
        let deny = try #require(denyPayload(from: second.decision))
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }

    @Test func emptyHomeRequestUsesDayOnePackIDs() {
        let request = GatedEvaluate.makeRequest(
            command: ShellCommand(rawValue: "git status"),
            home: ""
        )
        #expect(request.enabledPacks == dayOnePackIDs)
    }
}

private func isolatedDoorStore() throws -> AllowOnceStore {
    AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory())
}

private func denyPayload(from decision: Decision) -> Deny? {
    if case .deny(let deny) = decision { return deny }
    return nil
}
