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
        let gated = PolicyGate.decision(
            for: denied,
            cwd: wd("/tmp/ws"),
            allowlist: allowlist,
            grant: .pending,
            now: now
        )
        #expect(gated.override == .allowlist)
        #expect(gated.result.decision == .allow)
    }

    @Test func decidePendingGrantHonorsMandatoryHuman() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let gated = PolicyGate.decision(
            for: mandatoryHumanRemoteBranchAsk(),
            cwd: wd("/tmp/ws"),
            allowlist: .empty,
            grant: .pending,
            now: now
        )
        #expect(gated.override == .allowOnce)
        #expect(gated.result.decision == .allow)
    }

    @Test func decideEmptyCwdSkipsPendingGrant() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let gated = PolicyGate.decision(
            for: resetHardDeny(),
            cwd: nil,
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
        let gated = PolicyGate.decision(
            for: incomplete,
            cwd: wd("/tmp/ws"),
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
        let grants = EphemeralAllowOnceTable()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = resetHardDeny()
        let gated = await PolicyGate.consumingGrant(for: denied, cwd: wd("/tmp/ws"), grants: grants, now: now)
        #expect(gated.override == .none)
        guard case .deny = gated.result.decision else {
            Issue.record("engine deny without grant must stay deny")
            return
        }
    }

    @Test func denyWithGrantAllowsOnce() async throws {
        let grants = EphemeralAllowOnceTable()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = resetHardDeny()
        #expect(
            await grants.plant(
                matchingView: denied.matchingView, cwd: wd("/tmp/ws"), codeHash: "pg-once", now: now
            ) == .planted
        )
        let first = await PolicyGate.consumingGrant(for: denied, cwd: wd("/tmp/ws"), grants: grants, now: now)
        #expect(first.override == .allowOnce)
        #expect(first.result.decision == .allow)
        let second = await PolicyGate.consumingGrant(for: denied, cwd: wd("/tmp/ws"), grants: grants, now: now)
        #expect(second.override == .none)
        guard case .deny = second.result.decision else {
            Issue.record("second evaluate must deny after the grant is spent")
            return
        }
    }

    @Test func allowlistBeforeAllowOnce() async throws {
        let grants = EphemeralAllowOnceTable()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = resetHardDeny()
        #expect(
            await grants.plant(
                matchingView: denied.matchingView, cwd: wd("/tmp/ws"), codeHash: "pg-allowlist",
                now: now
            ) == .planted
        )
        let ruleID = try #require(RuleID(rawValue: "core.git:reset-hard"))
        let allowlist = AllowlistSnapshot(entries: [
            AllowlistEntry(selector: .rule(ruleID), reason: "ci", addedAt: now),
        ])
        let gated = await PolicyGate.consumingGrant(
            for: denied,
            cwd: wd("/tmp/ws"),
            allowlist: allowlist,
            grants: grants,
            now: now
        )
        #expect(gated.override == .allowlist)
        #expect(gated.result.decision == .allow)
        #expect(
            await grants.consume(matchingView: denied.matchingView, cwd: wd("/tmp/ws"), now: now),
            "allowlist must not spend the grant"
        )
    }

    @Test func allowDoesNotConsumeGrant() async throws {
        let grants = EphemeralAllowOnceTable()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            await grants.plant(
                matchingView: "git reset --hard", cwd: wd("/tmp/ws"), codeHash: "pg-allow", now: now
            ) == .planted
        )
        let allow = EvaluationResult(outcome: .plain, matchingView: "git reset --hard")
        let gated = await PolicyGate.consumingGrant(for: allow, cwd: wd("/tmp/ws"), grants: grants, now: now)
        #expect(gated.override == .none)
        #expect(gated.result.decision == .allow)
        #expect(
            await grants.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now),
            "allow must not spend the grant"
        )
    }

    @Test func indeterminateIsNotAllow() async throws {
        let grants = EphemeralAllowOnceTable()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            await grants.plant(
                matchingView: "git reset --hard", cwd: wd("/tmp/ws"), codeHash: "pg-indet", now: now
            ) == .planted
        )
        let incomplete = EvaluationResult(
            outcome: .indeterminate(.commandTooLarge),
            matchingView: "git reset --hard"
        )
        let gated = await PolicyGate.consumingGrant(for: incomplete, cwd: wd("/tmp/ws"), grants: grants, now: now)
        #expect(gated.override == .none)
        #expect(gated.result.decision != .allow)
        guard case .indeterminate = gated.result.decision else {
            Issue.record("indeterminate must stay miss-policy (not allow)")
            return
        }
        #expect(
            await grants.consume(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now),
            "indeterminate must not spend the grant"
        )
    }

    @Test func redeemThenGateAllowsOnce() async throws {
        let store = try isolatedStore()
        let grants = EphemeralAllowOnceTable()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let denied = resetHardDeny()
        let code = try await store.mint(
            matchingView: denied.matchingView,
            cwd: wd("/tmp/a"),
            ruleID: nil,
            tty: tty,
            now: now
        )
        _ = try await store.redeem(code: code.rawValue, tty: tty, now: now)
        // The file redeem flips projection only. Authority arrives via the
        // ceremony plant (genuine-CLI attest / UI resolver in production).
        #expect(
            await grants.plant(
                matchingView: denied.matchingView, cwd: wd("/tmp/a"), codeHash: "pg-redeem",
                now: now
            ) == .planted
        )
        let first = await PolicyGate.consumingGrant(for: denied, cwd: wd("/tmp/a"), grants: grants, now: now)
        #expect(first.override == .allowOnce)
        #expect(first.result.decision == .allow)
        let second = await PolicyGate.consumingGrant(for: denied, cwd: wd("/tmp/a"), grants: grants, now: now)
        guard case .deny = second.result.decision else {
            Issue.record("second identical command must deny")
            return
        }
    }

    @Test func allowOnceKeepsMatchedRuleDetail() async throws {
        let grants = EphemeralAllowOnceTable()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = resetHardDenyWithMatch()
        #expect(
            await grants.plant(
                matchingView: denied.matchingView, cwd: wd("/tmp/ws"), codeHash: "pg-match",
                now: now
            ) == .planted
        )
        let gated = await PolicyGate.consumingGrant(for: denied, cwd: wd("/tmp/ws"), grants: grants, now: now)
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
        let grants = EphemeralAllowOnceTable()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = resetHardDeny()
        #expect(
            await grants.plant(
                matchingView: denied.matchingView, cwd: wd("/tmp/ws"), codeHash: "pg-preview",
                now: now
            ) == .planted
        )
        let preview = await PolicyGate.preview(
            for: denied,
            cwd: wd("/tmp/ws"),
            grants: grants,
            now: now
        )
        #expect(preview.override == .allowOnce)
        #expect(preview.result.decision == .allow)
        #expect(
            await grants.consume(matchingView: denied.matchingView, cwd: wd("/tmp/ws"), now: now),
            "preview must not spend the grant"
        )
    }

    @Test func fileSabotageDoesNotAffectMemoryAuthority() async throws {
        // Step 8B.1: the JSONL file is display-only. Sabotaging its lock
        // must neither create authority nor destroy memory authority.
        let store = try isolatedStore()
        let grants = EphemeralAllowOnceTable()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = resetHardDeny()
        #expect(
            await grants.plant(
                matchingView: denied.matchingView, cwd: wd("/tmp/ws"), codeHash: "pg-sabotage",
                now: now
            ) == .planted
        )
        try sabotageLock(in: store.baseDirectory)
        let gated = await PolicyGate.consumingGrant(for: denied, cwd: wd("/tmp/ws"), grants: grants, now: now)
        #expect(gated.override == .allowOnce)
        #expect(gated.result.decision == .allow)
    }

    @Test func pinnedDenyDoesNotSpendGrant() async throws {
        let grants = EphemeralAllowOnceTable()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pinned = pinnedSecretDeny()
        #expect(RulePinning.blocksAllowOverride(pinned))
        #expect(
            await grants.plant(
                matchingView: pinned.matchingView, cwd: wd("/tmp/ws"), codeHash: "pg-pinned",
                now: now
            ) == .planted
        )
        let gated = await PolicyGate.consumingGrant(for: pinned, cwd: wd("/tmp/ws"), grants: grants, now: now)
        #expect(gated.override == .none)
        guard case .deny = gated.result.decision else {
            Issue.record("pinned deny must stay deny")
            return
        }
        #expect(
            await grants.consume(matchingView: pinned.matchingView, cwd: wd("/tmp/ws"), now: now),
            "pinned deny must not spend the grant"
        )
    }

    @Test func emptyCwdDoesNotHonor() async throws {
        let grants = EphemeralAllowOnceTable()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let denied = resetHardDeny()
        #expect(
            await grants.plant(
                matchingView: denied.matchingView, cwd: wd("/tmp/ws"), codeHash: "pg-emptycwd",
                now: now
            ) == .planted
        )
        let gated = await PolicyGate.consumingGrant(for: denied, cwd: nil, grants: grants, now: now)
        #expect(gated.override == .none)
        guard case .deny = gated.result.decision else {
            Issue.record("empty cwd must not honor")
            return
        }
        #expect(
            await grants.consume(matchingView: denied.matchingView, cwd: wd("/tmp/ws"), now: now),
            "empty cwd must not spend the grant"
        )
    }
}

private func pinnedSecretDeny() -> EvaluationResult {
    EvaluationResult(
        outcome: .deny(
            Deny(
                ruleID: RuleID(pack: .coreSecrets, pattern: "secret-path"),
                reason: "reads a secret path"
            ),
            matched: nil
        ),
        matchingView: "cat ~/.ssh/id_rsa"
    )
}

private func mandatoryHumanRemoteBranchAsk() -> EvaluationResult {
    EvaluationResult(
        outcome: .deny(ActionPolicyEngine.Builtin.remoteBranchAsk, matched: nil),
        matchingView: "git push --force-with-lease origin feature",
        analysis: .unknown,
        boundReview: .mandatoryHuman(ActionPolicyEngine.Builtin.remoteBranchAsk)
    )
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
