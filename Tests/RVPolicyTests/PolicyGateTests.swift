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

    @Test func allowlistBeforeAllowOnce() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = resetHardDeny()
        try await store.insertGranted(matchingView: denied.matchingView, cwd: "/tmp/ws", now: now)
        let ruleID = try #require(RuleID(rawValue: "core.git:reset-hard"))
        let allowlist = AllowlistSnapshot(entries: [
            AllowlistEntry(selector: .rule(ruleID), reason: "ci", addedAt: now),
        ])
        let gated = await PolicyGate.apply(
            denied,
            cwd: "/tmp/ws",
            allowlist: allowlist,
            store: store,
            now: now
        )
        #expect(gated.override == .allowlist)
        #expect(gated.result.decision == .allow)
        let still = await store.consume(matchingView: denied.matchingView, cwd: "/tmp/ws", now: now)
        guard case .consumed = still else {
            Issue.record("allowlist must not spend the grant")
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

    @Test func indeterminateIsNotAllow() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.insertGranted(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)
        let incomplete = EvaluationResult(
            decision: .indeterminate(.commandTooLarge),
            matchingView: "git reset --hard"
        )
        let gated = await PolicyGate.apply(incomplete, cwd: "/tmp/ws", store: store, now: now)
        #expect(gated.override == .none)
        #expect(gated.result.decision != .allow)
        guard case .indeterminate = gated.result.decision else {
            Issue.record("indeterminate must stay miss-policy (not allow)")
            return
        }
        let still = await store.consume(matchingView: "git reset --hard", cwd: "/tmp/ws", now: now)
        guard case .consumed = still else {
            Issue.record("indeterminate must not spend the grant")
            return
        }
    }

    @Test func redeemThenGateAllowsOnce() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let denied = resetHardDeny()
        let code = try await store.mint(
            matchingView: denied.matchingView,
            cwd: "/tmp/a",
            ruleID: nil,
            tty: tty,
            now: now
        )
        _ = try await store.redeem(code: code, tty: tty, now: now)
        let first = await PolicyGate.apply(denied, cwd: "/tmp/a", store: store, now: now)
        #expect(first.override == .allowOnce)
        #expect(first.result.decision == .allow)
        let second = await PolicyGate.apply(denied, cwd: "/tmp/a", store: store, now: now)
        guard case .deny = second.result.decision else {
            Issue.record("second identical command must deny")
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
