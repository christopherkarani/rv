import Foundation
import Testing
import RVDomain
@testable import RVPolicy

/// Adversarial PolicyGate / allow-once / Host Ask spend net. Fakes only; no
/// live TTY. Races, empty matching view, pinned unlockable, spend-first vs
/// deny-or-TTY hosts, two-process CAS under miss.
///
/// Run: `tools/gate.sh --quiet RVPolicyTests --filter PolicyGateStress`
@Suite("Policy gate stress")
struct PolicyGateStressTests {
    @Test func concurrentConsumeOfOneGrant_winsOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-policy-stress-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let writer = AllowOnceStore(baseDirectory: root)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = resetHardDeny()
        try await writer.insertGranted(
            matchingView: denied.matchingView,
            cwd: wd("/tmp/ws"),
            now: now
        )
        let a = AllowOnceStore(baseDirectory: root)
        let b = AllowOnceStore(baseDirectory: root)
        async let first = PolicyGate.consumingGrant(
            for: denied,
            cwd: wd("/tmp/ws"),
            store: a,
            now: now
        )
        async let second = PolicyGate.consumingGrant(
            for: denied,
            cwd: wd("/tmp/ws"),
            store: b,
            now: now
        )
        let results = await [first, second]
        let allowed = results.filter { $0.override == .allowOnce }
        #expect(allowed.count == 1, "two-process consume must spend the grant once")
        #expect(results.contains { $0.override == .none })
    }

    /// Host Ask spend plants a grant each confirm. Two same-turn plants are a
    /// residual race (no Ask token); the consume CAS above is the lock we have.
    @Test func sequentialHostAskSpend_plantsEachConfirm() async throws {
        let store = try isolatedPolicyStressStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = resetHardDeny()
        let first = await PolicyGate.spendHostAllowOnce(
            denied,
            cwd: wd("/tmp/ws"),
            store: store,
            now: now
        )
        #expect(first.override == .allowOnce)
        let second = await PolicyGate.spendHostAllowOnce(
            denied,
            cwd: wd("/tmp/ws"),
            store: store,
            now: now
        )
        #expect(second.override == .allowOnce)
    }

    @Test func emptyMatchingView_neverSpends() async throws {
        let store = try isolatedPolicyStressStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let empty = EvaluationResult(
            outcome: .deny(
                Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "x"),
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
        #expect(gated.override == .none)
        guard case .deny = gated.result.decision else {
            Issue.record("empty matching view must stay deny")
            return
        }
        #expect((await store.list(now: now)).isEmpty)
        #expect(
            await HostGrantWriter.plantAndSpend(
                matchingView: MatchingView(""),
                cwd: wd("/tmp/ws"),
                store: store,
                now: now
            ) == .rejected(.missingCallback)
        )
    }

    @Test func pinnedSecret_neverSpends() async throws {
        let store = try isolatedPolicyStressStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let secret = EvaluationResult(
            outcome: .deny(
                Deny(
                    ruleID: RuleID(pack: .coreSecrets, pattern: "env"),
                    reason: "Access to a sensitive path is not allowed."
                ),
                matched: nil
            ),
            matchingView: MatchingView("cat .env")
        )
        #expect(UnlockableDeny.isPinned(secret))
        #expect(UnlockableDeny.matches(result: secret, cwd: wd("/tmp/ws")) == false)
        let gated = await PolicyGate.spendHostAllowOnce(
            secret,
            cwd: wd("/tmp/ws"),
            store: store,
            now: now
        )
        #expect(gated.override == .none)
        guard case .deny = gated.result.decision else {
            Issue.record("pinned secret must not spend")
            return
        }
        #expect((await store.list(now: now)).isEmpty)
    }

    @Test func spendFirstHosts_spendUnlockableDeny() async throws {
        let store = try isolatedPolicyStressStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = resetHardDeny()
        for host in HookHost.allCases {
            let profile = HostNativeAsk.profile(for: host)
            switch profile.pause {
            case .spendFirst:
                let gated = await PolicyGate.spendHostAllowOnce(
                    denied,
                    cwd: wd("/tmp/ws-\(host.rawValue)"),
                    store: store,
                    now: now
                )
                #expect(gated.override == .allowOnce, "\(host) spend-first")
                #expect(gated.result.decision == .allow, "\(host)")
            case .noPause, .leftoverAskForbidden:
                let withoutSpend = PolicyGate.decision(
                    for: denied,
                    cwd: wd("/tmp/ws-\(host.rawValue)"),
                    allowlist: .empty,
                    grant: .none,
                    now: now
                )
                #expect(withoutSpend.override == .none, "\(host) deny-or-TTY must not auto-spend")
                guard case .deny = withoutSpend.result.decision else {
                    Issue.record("\(host) must stay deny without a spend callback")
                    continue
                }
            }
        }
    }

    @Test func twoStores_casUnderMiss_neitherAllows() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-policy-stress-miss-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let a = AllowOnceStore(baseDirectory: root)
        let b = AllowOnceStore(baseDirectory: root)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = resetHardDeny()
        async let first = PolicyGate.consumingGrant(
            for: denied,
            cwd: wd("/tmp/ws"),
            store: a,
            now: now
        )
        async let second = PolicyGate.consumingGrant(
            for: denied,
            cwd: wd("/tmp/ws"),
            store: b,
            now: now
        )
        let results = await [first, second]
        #expect(results.allSatisfy { $0.override == .none })
        #expect(results.allSatisfy { result in
            if case .deny = result.result.decision { return true }
            return false
        })
    }

    @Test func mintEmptyMatchingView_throwsWithoutTTY() async throws {
        let store = try isolatedPolicyStressStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        await #expect(throws: AllowOnceError.emptyCommand) {
            try await store.mint(
                matchingView: MatchingView(""),
                cwd: wd("/tmp/ws"),
                ruleID: nil,
                tty: tty,
                now: now
            )
        }
        #expect((await store.list(now: now)).isEmpty)
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

private func isolatedPolicyStressStore() throws -> AllowOnceStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-policy-stress-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return AllowOnceStore(baseDirectory: root)
}
