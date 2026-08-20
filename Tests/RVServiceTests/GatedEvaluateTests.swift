import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVService

struct GatedEvaluateTests {
    @Test func peekShowsGrantWithoutSpendingThenApplyHonorsOnce() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let session = EvaluateSession()
        let request = resetHardRequest()
        try await store.insertGranted(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)

        let engine = session.evaluate(request)
        guard case .deny = engine.decision else {
            Issue.record("Evaluate session must stay grant-free")
            return
        }

        let gated = GatedEvaluate(session)
        let peeked = await gated.peek(request, cwd: "/tmp/ws", store: store, now: now)
        #expect(peeked.override == .allowOnce)
        guard case .deny = peeked.engine.decision else {
            Issue.record("peek must keep the engine deny")
            return
        }
        #expect(peeked.effective.decision == .allow)

        let first = await gated.apply(request, cwd: "/tmp/ws", store: store, now: now)
        #expect(first.override == .allowOnce)
        #expect(first.effective.decision == .allow)
        let second = await gated.apply(request, cwd: "/tmp/ws", store: store, now: now)
        #expect(second.override == .none)
        guard case .deny(let deny) = second.effective.decision else {
            Issue.record("second apply must deny after the grant is spent")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }

    @Test func missingCwdSkipsHonor() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let gated = GatedEvaluate()
        let request = resetHardRequest()
        try await store.insertGranted(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)

        let peeked = await gated.peek(request, cwd: nil, store: store, now: now)
        #expect(peeked.override == .none)
        guard case .deny = peeked.effective.decision else {
            Issue.record("missing cwd must skip honor")
            return
        }
        let appliedEmpty = await gated.apply(request, cwd: "", store: store, now: now)
        #expect(appliedEmpty.override == .none)
        guard case .deny = appliedEmpty.effective.decision else {
            Issue.record("empty cwd must skip honor")
            return
        }
        let applied = await gated.apply(request, cwd: "/tmp/ws", store: store, now: now)
        #expect(applied.override == .allowOnce)
        #expect(applied.effective.decision == .allow)
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
