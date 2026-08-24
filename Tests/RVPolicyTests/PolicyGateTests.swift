import Foundation
import Testing
import RVDomain
@testable import RVPolicy

struct PolicyGateTests {
    @Test func decideAllowlistBeforeGrant() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = resetHardDeny()
        let ruleID = try #require(RuleID(rawValue: "core.git:reset-hard"))
        let allowlist = AllowlistSnapshot(entries: [
            AllowlistEntry(selector: .rule(ruleID), reason: "ci", addedAt: now),
        ])
        let gated = PolicyGate.decide(
            denied,
            cwd: "/tmp/ws",
            allowlist: allowlist,
            grant: .pending,
            now: now
        )
        #expect(gated.override == .allowlist)
        #expect(gated.result.decision == .allow)
    }

    @Test func decideEmptyCwdSkipsPendingGrant() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let gated = PolicyGate.decide(
            resetHardDeny(),
            cwd: "",
            allowlist: .empty,
            grant: .pending,
            now: now
        )
        #expect(gated.override == .none)
        guard case .deny = gated.result.decision else {
            Issue.record("empty cwd must not honor a pending grant")
            return
        }
    }

    @Test func decideIndeterminateNeverHonorsGrant() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let incomplete = EvaluationResult(
            outcome: .indeterminate(.commandTooLarge),
            matchingView: "git reset --hard"
        )
        let gated = PolicyGate.decide(
            incomplete,
            cwd: "/tmp/ws",
            allowlist: .empty,
            grant: .pending,
            now: now
        )
        #expect(gated.override == .none)
        guard case .indeterminate = gated.result.decision else {
            Issue.record("indeterminate must stay miss-policy (not allow)")
            return
        }
    }

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
        let allow = EvaluationResult(outcome: .plain, matchingView: "git reset --hard")
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
            outcome: .indeterminate(.commandTooLarge),
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

    @Test func allowOnceKeepsMatchedRuleDetail() async throws {
        let store = try isolatedStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = resetHardDenyWithMatch()
        try await store.insertGranted(matchingView: denied.matchingView, cwd: "/tmp/ws", now: now)
        let gated = await PolicyGate.apply(denied, cwd: "/tmp/ws", store: store, now: now)
        #expect(gated.override == .allowOnce)
        guard case .hit(let match, safe: nil) = gated.result.outcome else {
            Issue.record("override must keep the hit structure on an allow")
            return
        }
        #expect(match.ruleID.rawValue == "core.git:reset-hard")
        #expect(match.severity == .critical)
        #expect(gated.result.decision == .allow)
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
        let still = await store.consume(matchingView: denied.matchingView, cwd: "/tmp/ws", now: now)
        guard case .consumed = still else {
            Issue.record("empty cwd must not spend the grant")
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

private func resetHardDenyWithMatch() -> EvaluationResult {
    let ruleID = RuleID(pack: .coreGit, pattern: "reset-hard")
    return EvaluationResult(
        outcome: .deny(
            Deny(ruleID: ruleID, reason: "git reset --hard destroys uncommitted changes"),
            matched: RuleMatch(
                ruleID: ruleID,
                packID: .coreGit,
                patternName: "reset-hard",
                severity: .critical,
                reason: "git reset --hard destroys uncommitted changes"
            )
        ),
        matchingView: MatchingView("git reset --hard")
    )
}

private func isolatedStore() throws -> AllowOnceStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-policy-gate-\(UUID().uuidString)", isDirectory: true)
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
