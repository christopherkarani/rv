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
        try await store.insertGranted(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now)

        let engine = session.evaluate(request)
        guard case .deny = engine.decision else {
            Issue.record("Evaluate session must stay grant-free")
            return
        }

        let gated = GatedEvaluate(session)
        let peeked = await gated.peek(request, cwd: wd("/tmp/ws"), store: store, now: now, allowlist: { .empty })
        #expect(peeked.decision == .allow)

        let first = await gated.apply(request, cwd: wd("/tmp/ws"), store: store, now: now, allowlist: { .empty })
        #expect(first.decision == .allow)
        let second = await gated.apply(request, cwd: wd("/tmp/ws"), store: store, now: now, allowlist: { .empty })
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
        try await store.insertGranted(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now)

        let peeked = await gated.peek(request, cwd: nil, store: store, now: now, allowlist: { .empty })
        guard case .deny = peeked.decision else {
            Issue.record("missing cwd must skip honor")
            return
        }
        let appliedEmpty = await gated.apply(request, cwd: nil, store: store, now: now, allowlist: { .empty })
        guard case .deny = appliedEmpty.decision else {
            Issue.record("empty cwd must skip honor")
            return
        }
        let applied = await gated.apply(request, cwd: wd("/tmp/ws"), store: store, now: now, allowlist: { .empty })
        #expect(applied.decision == .allow)
    }

    @Test func injectedEmptyAllowlistIgnoresSiblingAllowlistFile() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ruleID = try #require(RuleID(rawValue: "core.git:reset-hard"))
        try AllowlistStore(baseDirectory: store.baseDirectory).add(
            AllowlistEntry(selector: .rule(ruleID), reason: "ci", addedAt: now),
            tty: TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        )
        let gated = GatedEvaluate()
        let applied = await gated.apply(
            resetHardRequest(),
            cwd: wd("/tmp/ws"),
            store: store,
            now: now,
            allowlist: { .empty }
        )
        guard case .deny = applied.decision else {
            Issue.record("injected empty snapshot must not load store.baseDirectory")
            return
        }
    }

    @Test func injectedAllowlistSnapshotHonorsWithoutStoreDirectory() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ruleID = try #require(RuleID(rawValue: "core.git:reset-hard"))
        let allowlist = AllowlistSnapshot(entries: [
            AllowlistEntry(selector: .rule(ruleID), reason: "ci", addedAt: now),
        ])
        let gated = GatedEvaluate()
        let applied = await gated.apply(
            resetHardRequest(),
            cwd: wd("/tmp/ws"),
            store: store,
            now: now,
            allowlist: { allowlist }
        )
        #expect(applied.decision == .allow)
    }

    @Test func allowPathDoesNotCreateAllowlistFile() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let gated = GatedEvaluate()
        let request = stashDropRequest()

        let peeked = await gated.peek(request, cwd: wd("/tmp/ws"), store: store, now: now, allowlist: { .empty })
        #expect(peeked.decision == .allow)
        let applied = await gated.apply(request, cwd: wd("/tmp/ws"), store: store, now: now, allowlist: { .empty })
        #expect(applied.decision == .allow)

        let allowlist = AllowlistStore(baseDirectory: store.baseDirectory).fileURL
        #expect(FileManager.default.fileExists(atPath: allowlist.path) == false)
    }

    @Test func allowPathDoesNotInvokeAllowlistLoader() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calls = UnfairLock(0)
        let gated = GatedEvaluate()
        let applied = await gated.apply(
            stashDropRequest(),
            cwd: wd("/tmp/ws"),
            store: store,
            now: now,
            allowlist: {
                calls.withLock { $0 += 1 }
                return .empty
            }
        )
        #expect(applied.decision == .allow)
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func indeterminateIsNotAllowAndDoesNotHonor() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.insertGranted(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now)
        let gated = GatedEvaluate(.missingCore)
        let request = resetHardRequest()

        let peeked = await gated.peek(request, cwd: wd("/tmp/ws"), store: store, now: now, allowlist: { .empty })
        #expect(peeked.decision == .indeterminate(.corePacksUnavailable))
        let applied = await gated.apply(request, cwd: wd("/tmp/ws"), store: store, now: now, allowlist: { .empty })
        #expect(applied.decision == .indeterminate(.corePacksUnavailable))
        let still = await store.consume(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/ws"),
            now: now
        )
        guard case .consumed = still else {
            Issue.record("indeterminate must not spend the grant")
            return
        }
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
