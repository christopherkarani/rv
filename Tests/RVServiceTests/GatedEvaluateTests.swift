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
        #expect(peeked.decision == .allow)

        let first = await gated.apply(request, cwd: "/tmp/ws", store: store, now: now)
        #expect(first.decision == .allow)
        let second = await gated.apply(request, cwd: "/tmp/ws", store: store, now: now)
        guard case .deny(let deny) = second.decision else {
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
        guard case .deny = peeked.decision else {
            Issue.record("missing cwd must skip honor")
            return
        }
        let appliedEmpty = await gated.apply(request, cwd: "", store: store, now: now)
        guard case .deny = appliedEmpty.decision else {
            Issue.record("empty cwd must skip honor")
            return
        }
        let applied = await gated.apply(request, cwd: "/tmp/ws", store: store, now: now)
        #expect(applied.decision == .allow)
    }

    @Test func allowPathDoesNotCreateAllowlistFile() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let gated = GatedEvaluate()
        let request = stashDropRequest()

        let peeked = await gated.peek(request, cwd: "/tmp/ws", store: store, now: now)
        #expect(peeked.decision == .allow)
        let applied = await gated.apply(request, cwd: "/tmp/ws", store: store, now: now)
        #expect(applied.decision == .allow)

        let allowlist = AllowlistStore(baseDirectory: store.baseDirectory).fileURL
        #expect(FileManager.default.fileExists(atPath: allowlist.path) == false)
    }

    @Test func indeterminateIsNotAllowAndDoesNotHonor() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.insertGranted(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)
        let gated = GatedEvaluate(.missingCore)
        let request = resetHardRequest()

        let peeked = await gated.peek(request, cwd: "/tmp/ws", store: store, now: now)
        #expect(peeked.decision == .indeterminate(.corePacksUnavailable))
        let applied = await gated.apply(request, cwd: "/tmp/ws", store: store, now: now)
        #expect(applied.decision == .indeterminate(.corePacksUnavailable))
        let still = await store.consume(
            matchingView: "git reset --hard",
            cwd: "/tmp/ws",
            now: now
        )
        guard case .consumed = still else {
            Issue.record("indeterminate must not spend the grant")
            return
        }
    }

    @Test func nilHomeMakeRequestWalksDayOne() {
        let request = GatedEvaluate.makeRequest(
            command: ShellCommand(rawValue: "git status"),
            home: nil
        )
        #expect(request.enabledPacks == dayOnePackIDs)
    }
}

private func resetHardRequest() -> EvaluationRequest {
    EvaluationRequest(
        command: ShellCommand(rawValue: "git reset --hard"),
        enabledPacks: dayOnePackIDs
    )
}

private func stashDropRequest() -> EvaluationRequest {
    EvaluationRequest(
        command: ShellCommand(rawValue: "git stash drop"),
        enabledPacks: dayOnePackIDs
    )
}

private func isolatedStore() throws -> AllowOnceStore {
    AllowOnceStore(baseDirectory: try isolatedAllowOnceDirectory())
}
