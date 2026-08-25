import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVService

struct EvaluateDoorTests {
    @Test func runPeekDoesNotSpendGrantThenApplyDoes() async throws {
        let store = try isolatedDoorStore()
        let home = try isolatedHome()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let door = GatedEvaluate(EvaluateSession(enabledPacks: dayOnePackIDs))
        let command = ShellCommand(rawValue: "git reset --hard")
        try await store.insertGranted(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)

        let peeked = await door.run(
            .peek,
            command: command,
            cwd: "/tmp/ws",
            home: home,
            store: store,
            now: now,
            allowlist: { .empty }
        )
        #expect(peeked.decision == .allow)
        let peekedAgain = await door.run(
            .peek,
            command: command,
            cwd: "/tmp/ws",
            home: home,
            store: store,
            now: now,
            allowlist: { .empty }
        )
        #expect(peekedAgain.decision == .allow)

        let first = await door.run(
            .apply,
            command: command,
            cwd: "/tmp/ws",
            home: home,
            store: store,
            now: now,
            allowlist: { .empty }
        )
        #expect(first.decision == .allow)
        let second = await door.run(
            .apply,
            command: command,
            cwd: "/tmp/ws",
            home: home,
            store: store,
            now: now,
            allowlist: { .empty }
        )
        let deny = try #require(denyPayload(from: second.decision))
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }

    @Test func freshHomeRequestUsesDayOnePackIDs() throws {
        let request = GatedEvaluate.makeRequest(
            command: ShellCommand(rawValue: "git status"),
            home: try isolatedHome()
        )
        #expect(request.enabledPacks == dayOnePackIDs)
    }

    @Test func nilHomeRequestUsesDayOneWalk() {
        let request = GatedEvaluate.makeRequest(
            command: ShellCommand(rawValue: "git status"),
            home: nil
        )
        #expect(request.enabledPacks == dayOnePackIDs)
    }
}

private func isolatedHome() throws -> HomeDirectory {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-door-home-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return try #require(HomeDirectory(validating: url.path))
}

private func isolatedDoorStore() throws -> AllowOnceStore {
    AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory())
}

private func denyPayload(from decision: Decision) -> Deny? {
    if case .deny(let deny) = decision { return deny }
    return nil
}
