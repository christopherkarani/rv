import Foundation
import Testing
import RVDomain
@testable import RVPolicy

struct HostGrantWriterTests {
    @Test func plantAndSpendThenReplayDenies() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = resetHardDeny()
        let first = await PolicyGate.spendHostAllowOnce(
            denied,
            cwd: wd("/tmp/ws"),
            store: store,
            now: now
        )
        #expect(first.override == .allowOnce)
        #expect(first.result.decision == .allow)

        let replay = await PolicyGate.apply(denied, cwd: wd("/tmp/ws"), store: store, now: now)
        #expect(replay.override == .none)
        guard case .deny = replay.result.decision else {
            Issue.record("replay without a live grant must deny")
            return
        }
    }

    @Test func missingCwdDoesNotSpend() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = resetHardDeny()
        let gated = await PolicyGate.spendHostAllowOnce(
            denied,
            cwd: nil,
            store: store,
            now: now
        )
        #expect(gated.override == .none)
        guard case .deny = gated.result.decision else {
            Issue.record("missing cwd must not plant a grant")
            return
        }
        #expect(
            await HostGrantWriter.plantAndSpend(
                matchingView: denied.matchingView,
                cwd: nil,
                store: store,
                now: now
            ) == .rejected(.missingCallback)
        )
    }

    @Test func emptyMatchingViewDoesNotSpend() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let empty = EvaluationResult(
            outcome: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                    reason: "x"
                ),
                matched: nil
            ),
            matchingView: ""
        )
        let gated = await PolicyGate.spendHostAllowOnce(
            empty,
            cwd: wd("/tmp/ws"),
            store: store,
            now: now
        )
        guard case .deny = gated.result.decision else {
            Issue.record("empty matching view must not allow")
            return
        }
    }

    @Test func indeterminateNeverSpends() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let incomplete = EvaluationResult(
            outcome: .indeterminate(.commandTooLarge),
            matchingView: "git reset --hard"
        )
        let gated = await PolicyGate.spendHostAllowOnce(
            incomplete,
            cwd: wd("/tmp/ws"),
            store: store,
            now: now
        )
        #expect(gated.override == .none)
        #expect(gated.result.decision != .allow)
        let later = await store.consume(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/ws"),
            now: now
        )
        #expect(later == .notFound)
    }

    @Test func failedStoreDoesNotAllow() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try sabotageLock(in: store.baseDirectory)
        let gated = await PolicyGate.spendHostAllowOnce(
            resetHardDeny(),
            cwd: wd("/tmp/ws"),
            store: store,
            now: now
        )
        #expect(gated.override == .none)
        guard case .deny = gated.result.decision else {
            Issue.record("failed spend must stay deny")
            return
        }
    }
}

private func resetHardDeny() -> EvaluationResult {
    EvaluationResult(
        outcome: .deny(
            Deny(
                ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                reason: "git reset --hard destroys uncommitted changes"
            ),
            matched: nil
        ),
        matchingView: "git reset --hard"
    )
}

private func isolatedStore() throws -> AllowOnceStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-host-grant-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return AllowOnceStore(baseDirectory: root)
}

private func sabotageLock(in directory: URL) throws {
    let lock = RVPolicyPaths.allowOnceLockFile(inConfigDir: directory)
    if FileManager.default.fileExists(atPath: lock.path) {
        try FileManager.default.removeItem(at: lock)
    }
    try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
}
