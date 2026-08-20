import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVService

struct GatedEvaluateTests {
    @Test func peekShowsGrantWithoutSpendingThenApplyHonorsOnce() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let door = GatedEvaluate()
        let request = resetHardRequest()
        try await store.insertGranted(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)

        let engine = door.session.evaluate(request)
        guard case .deny = engine.decision else {
            Issue.record("Evaluate session must stay grant-free")
            return
        }

        let peeked = await door.peek(request, cwd: "/tmp/ws", store: store, now: now)
        #expect(peeked.decision == .allow)

        let first = await door.apply(request, cwd: "/tmp/ws", store: store, now: now)
        #expect(first.decision == .allow)
        let second = await door.apply(request, cwd: "/tmp/ws", store: store, now: now)
        guard case .deny(let deny) = second.decision else {
            Issue.record("second apply must deny after the grant is spent")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }

    @Test func missingCwdSkipsHonor() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let door = GatedEvaluate()
        let request = resetHardRequest()
        try await store.insertGranted(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)

        let peeked = await door.peek(request, cwd: nil, store: store, now: now)
        guard case .deny = peeked.decision else {
            Issue.record("missing cwd must skip honor")
            return
        }
        let appliedEmpty = await door.apply(request, cwd: "", store: store, now: now)
        guard case .deny = appliedEmpty.decision else {
            Issue.record("empty cwd must skip honor")
            return
        }
        let applied = await door.apply(request, cwd: "/tmp/ws", store: store, now: now)
        #expect(applied.decision == .allow)
    }
}

private func resetHardRequest() -> EvaluationRequest {
    EvaluationRequest(
        command: ShellCommand(rawValue: "git reset --hard"),
        enabledPacks: dayOnePackIDs
    )
}

private func isolatedStore() throws -> AllowOnceStore {
    AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory())
}
