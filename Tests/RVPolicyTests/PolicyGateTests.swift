import Foundation
import Testing
import RVDomain
@testable import RVPolicy

struct PolicyGateTests {
    @Test func denyWithoutGrantStaysDeny() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = resetHardDeny()
        let gated = await PolicyGate.apply(denied, cwd: "/tmp/ws", store: store, now: now)
        #expect(gated.override == .none)
        guard case .deny = gated.result.decision else {
            Issue.record("engine deny without grant must stay deny")
            return
        }
    }

    @Test func denyWithGrantAllowsOnce() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = resetHardDeny()
        try await store.insertGranted(matchingView: denied.matchingView, cwd: "/tmp/ws", now: now)
        let first = await PolicyGate.apply(denied, cwd: "/tmp/ws", store: store, now: now)
        #expect(first.override == .allowOnce)
        #expect(first.result.decision == .allow)
        let second = await PolicyGate.apply(denied, cwd: "/tmp/ws", store: store, now: now)
        #expect(second.override == .none)
        guard case .deny = second.result.decision else {
            Issue.record("second evaluate must deny after the grant is spent")
            return
        }
    }

    @Test func allowDoesNotConsumeGrant() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.insertGranted(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)
        let allow = EvaluationResult(decision: .allow, matchingView: "git reset --hard")
        let gated = await PolicyGate.apply(allow, cwd: "/tmp/ws", store: store, now: now)
        #expect(gated.override == .none)
        #expect(gated.result.decision == .allow)
        let still = await store.consume(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)
        guard case .consumed = still else {
            Issue.record("allow must not spend the grant")
            return
        }
    }

    @Test func indeterminateDoesNotConsumeGrant() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.insertGranted(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)
        let incomplete = EvaluationResult(
            decision: .indeterminate(.commandTooLarge),
            matchingView: "git reset --hard"
        )
        let gated = await PolicyGate.apply(incomplete, cwd: "/tmp/ws", store: store, now: now)
        #expect(gated.override == .none)
        guard case .indeterminate = gated.result.decision else {
            Issue.record("indeterminate must not become allow")
            return
        }
        let still = await store.consume(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)
        guard case .consumed = still else {
            Issue.record("indeterminate must not spend the grant")
            return
        }
    }

    @Test func previewDoesNotSpendGrant() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = resetHardDeny()
        try await store.insertGranted(matchingView: denied.matchingView, cwd: "/tmp/ws", now: now)
        let preview = await PolicyGate.peek(
            denied,
            cwd: "/tmp/ws",
            store: store,
            now: now
        )
        #expect(preview.override == .allowOnce)
        #expect(preview.result.decision == .allow)
        let still = await store.consume(matchingView: denied.matchingView, cwd: "/tmp/ws", now: now)
        guard case .consumed = still else {
            Issue.record("preview must not spend the grant")
            return
        }
    }

    @Test func storeUnavailableStaysDeny() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = resetHardDeny()
        try await store.insertGranted(matchingView: denied.matchingView, cwd: "/tmp/ws", now: now)
        try sabotageLock(in: store.baseDirectory)
        let gated = await PolicyGate.apply(denied, cwd: "/tmp/ws", store: store, now: now)
        #expect(gated.override == .none)
        guard case .deny = gated.result.decision else {
            Issue.record("store unavailable must stay deny")
            return
        }
    }

    @Test func emptyCwdDoesNotHonor() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = resetHardDeny()
        try await store.insertGranted(matchingView: denied.matchingView, cwd: "/tmp/ws", now: now)
        let gated = await PolicyGate.apply(denied, cwd: "", store: store, now: now)
        #expect(gated.override == .none)
        guard case .deny = gated.result.decision else {
            Issue.record("empty cwd must not honor")
            return
        }
    }
}

private func resetHardDeny() -> EvaluationResult {
    EvaluationResult(
        decision: .deny(
            Deny(
                ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                reason: "git reset --hard destroys uncommitted changes"
            )
        ),
        matchingView: "git reset --hard"
    )
}

private func isolatedStore() throws -> AllowOnceStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-policy-gate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return AllowOnceStore(baseDirectory: root)
}

private func sabotageLock(in directory: URL) throws {
    let lock = directory.appendingPathComponent(".allow-once.lock", isDirectory: false)
    if FileManager.default.fileExists(atPath: lock.path) {
        try FileManager.default.removeItem(at: lock)
    }
    try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
}
