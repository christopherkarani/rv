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
        // Step 8B.1: the memory table is an actor, so two racing consumers
        // serialize and exactly one spends the grant.
        let grants = EphemeralAllowOnceTable()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = resetHardDeny()
        #expect(
            await grants.plant(
                matchingView: denied.matchingView, cwd: wd("/tmp/ws"), codeHash: "stress-race",
                now: now
            ) == .planted
        )
        async let first = PolicyGate.consumingGrant(
            for: denied,
            cwd: wd("/tmp/ws"),
            grants: grants,
            now: now
        )
        async let second = PolicyGate.consumingGrant(
            for: denied,
            cwd: wd("/tmp/ws"),
            grants: grants,
            now: now
        )
        let results = await [first, second]
        let allowed = results.filter { $0.override == .allowOnce }
        #expect(allowed.count == 1, "racing consumers must spend the grant once")
        #expect(results.contains { $0.override == .none })
    }

    @Test func emptyMatchingView_neverConsumes() async throws {
        let grants = EphemeralAllowOnceTable()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let empty = EvaluationResult(
            outcome: .deny(
                Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "x"),
                matched: nil
            ),
            matchingView: ""
        )
        let gated = await PolicyGate.consumingGrant(
            for: empty,
            cwd: wd("/tmp/ws"),
            grants: grants,
            now: now
        )
        #expect(gated.override == .none)
        guard case .deny = gated.result.decision else {
            Issue.record("empty matching view must stay deny")
            return
        }
        #expect(await grants.hasGrant(matchingView: "", cwd: wd("/tmp/ws"), now: now) == false)
    }

    @Test func pinnedSecret_neverSpends() async throws {
        let grants = EphemeralAllowOnceTable()
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
        let gated = await PolicyGate.consumingGrant(
            for: secret,
            cwd: wd("/tmp/ws"),
            grants: grants,
            now: now
        )
        #expect(gated.override == .none)
        guard case .deny = gated.result.decision else {
            Issue.record("pinned secret must not spend")
            return
        }
        #expect(
            await grants.hasGrant(matchingView: secret.matchingView, cwd: wd("/tmp/ws"), now: now)
                == false
        )
    }

    @Test func consumingGrant_withoutGrantStaysDeny() async throws {
        // Step 8B: no host callback can plant authority. Only a planted
        // grant (human approval) flips the decision.
        let grants = EphemeralAllowOnceTable()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = resetHardDeny()
        let gated = await PolicyGate.consumingGrant(
            for: denied,
            cwd: wd("/tmp/ws"),
            grants: grants,
            now: now
        )
        #expect(gated.override == .none)
        guard case .deny = gated.result.decision else {
            Issue.record("must stay deny without a planted grant")
            return
        }
        #expect(
            await grants.hasGrant(
                matchingView: denied.matchingView, cwd: wd("/tmp/ws"), now: now
            ) == false
        )
    }

    @Test func twoStores_casUnderMiss_neitherAllows() async throws {
        // Step 8B.1: two independent epochs (tables), no grant in either.
        let a = EphemeralAllowOnceTable()
        let b = EphemeralAllowOnceTable()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = resetHardDeny()
        async let first = PolicyGate.consumingGrant(
            for: denied,
            cwd: wd("/tmp/ws"),
            grants: a,
            now: now
        )
        async let second = PolicyGate.consumingGrant(
            for: denied,
            cwd: wd("/tmp/ws"),
            grants: b,
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
