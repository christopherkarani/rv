import Foundation
import Testing
import RVDomain
@testable import RVPolicy

/// A present-but-unusable `denylist.toml` must never read as "no Always-block
/// pins": the allowlist would then silently override denies the user pinned.
struct DenylistFailClosedTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test(arguments: CorruptDenylist.allCases)
    func corruptDenylist_suspendsAllowlistOverrideWithRecoveryReason(_ corruption: CorruptDenylist) throws {
        let root = try makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try allowResetHardByRule(in: root)
        try corruption.write(to: RVPolicyPaths.denylistFile(inConfigDir: root))

        let snap = AllowlistStore(baseDirectory: root).loadUserSnapshot(workspacePath: nil, now: now)
        #expect(snap.entries.count == 1)
        #expect(snap.blocked.isUnreadable)

        let gated = PolicyGate.decision(
            for: resetHardDeny(),
            cwd: wd("/tmp/ws"),
            allowlist: snap,
            grant: .none,
            now: now
        )
        #expect(gated.override == .none)
        guard case .deny(let deny) = gated.result.decision else {
            Issue.record("corrupt denylist must not let the allowlist override a deny")
            return
        }
        // Same deny as a validly pinned command, plus the recovery text.
        #expect(deny.ruleID == RuleID(pack: .coreGit, pattern: "reset-hard"))
        #expect(deny.reason.hasPrefix("git reset --hard destroys uncommitted changes"))
        #expect(deny.reason.contains("denylist.toml"))
        #expect(deny.reason.contains("Fix or remove"))
        #expect(gated.result.matchingView == "git reset --hard")
    }

    @Test func missingDenylist_allowlistOverrideStillApplies() throws {
        let root = try makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try allowResetHardByRule(in: root)

        let snap = AllowlistStore(baseDirectory: root).loadUserSnapshot(workspacePath: nil, now: now)
        #expect(snap.blocked == .empty)
        let gated = PolicyGate.decision(
            for: resetHardDeny(),
            cwd: wd("/tmp/ws"),
            allowlist: snap,
            grant: .none,
            now: now
        )
        #expect(gated.override == .allowlist)
        #expect(gated.result.decision == .allow)
    }

    @Test func corruptDenylist_withoutAllowlistMatch_leavesDenyUnchanged() {
        let snap = AllowlistSnapshot(entries: [], blocked: .unreadable)
        let denied = resetHardDeny()
        let gated = PolicyGate.decision(
            for: denied,
            cwd: wd("/tmp/ws"),
            allowlist: snap,
            grant: .none,
            now: now
        )
        #expect(gated == PolicyDecision(result: denied, override: .none))
    }

    @Test func corruptDenylist_behavesExactlyLikeValidPin_withAndWithoutGrant() async throws {
        let ruleID = RuleID(pack: .coreGit, pattern: "reset-hard")
        let entries = [AllowlistEntry(selector: .rule(ruleID), reason: "ci", addedAt: now)]
        let pinned = AllowlistSnapshot(
            entries: entries,
            blocked: DenylistSnapshot(entries: [
                DenylistEntry(matchingView: "git reset --hard", reason: "pin", addedAt: now)
            ])
        )
        let corrupt = AllowlistSnapshot(entries: entries, blocked: .unreadable)

        for planted in [false, true] {
            var outcomes: [PolicyDecision] = []
            for snap in [pinned, corrupt] {
                let grants = EphemeralAllowOnceTable()
                if planted {
                    _ = await grants.plant(
                        matchingView: "git reset --hard", cwd: wd("/tmp/ws"), codeHash: "c", now: now
                    )
                }
                outcomes.append(
                    await PolicyGate.consumingGrant(
                        for: resetHardDeny(), cwd: wd("/tmp/ws"), allowlist: snap,
                        grants: grants, now: now
                    )
                )
            }
            #expect(outcomes[0].override == outcomes[1].override)
            #expect(outcomes[0].result.boundReview == outcomes[1].result.boundReview)
            #expect(outcomes[0].result.matchingView == outcomes[1].result.matchingView)
        }
    }

    // MARK: HookAuthorization parity: a corrupt denylist reads as "every command validly pinned".

    @Test func corruptDenylist_ruleAllowlistedDeny_isAskableNotPinned() {
        let entries = [AllowlistEntry(
            selector: .rule(RuleID(pack: .coreGit, pattern: "reset-hard")), reason: "ci", addedAt: now
        )]
        let valid = verdict(entries: entries, blocked: validPin, result: resetHardDeny())
        let corrupt = verdict(entries: entries, blocked: .unreadable, result: resetHardDeny())
        #expect(valid == .ask)
        #expect(corrupt == valid)
    }

    @Test func corruptDenylist_exactCommandWithDigests_isAskableNotPinned() {
        let masked = ["payload"]
        let prefix = ["sudo"]
        let entries = [AllowlistEntry(
            selector: .exactCommand("git reset --hard"),
            reason: "ci",
            addedAt: now,
            maskedPayloadDigest: maskedPayloadContentDigest(masked),
            invocationDigest: maskedPayloadContentDigest(prefix)
        )]
        let valid = verdict(
            entries: entries, blocked: validPin, result: resetHardDeny(),
            masked: masked, prefix: prefix
        )
        let corrupt = verdict(
            entries: entries, blocked: .unreadable, result: resetHardDeny(),
            masked: masked, prefix: prefix
        )
        #expect(valid == .ask)
        #expect(corrupt == valid)
    }

    @Test func corruptDenylist_keepsMandatoryHumanBind_staysAskable() {
        let builtin = Deny(
            ruleID: RuleID(pack: ActionPolicyEngine.Builtin.pack, pattern: "review"),
            reason: "needs a human"
        )
        let result = EvaluationResult(
            outcome: .deny(builtin, matched: nil),
            matchingView: "git reset --hard",
            analysis: .unknown,
            boundReview: .mandatoryHuman(builtin)
        )
        let entries = [AllowlistEntry(
            selector: .exactCommand("git reset --hard"), reason: "ci", addedAt: now
        )]
        let valid = verdict(entries: entries, blocked: validPin, result: result)
        let corrupt = verdict(entries: entries, blocked: .unreadable, result: result)
        #expect(valid == .ask)
        #expect(corrupt == valid)
    }

    private var validPin: DenylistSnapshot {
        DenylistSnapshot(entries: [
            DenylistEntry(matchingView: "git reset --hard", reason: "pin", addedAt: now)
        ])
    }

    private func verdict(
        entries: [AllowlistEntry],
        blocked: DenylistSnapshot,
        result: EvaluationResult,
        masked: [String]? = nil,
        prefix: [String]? = nil
    ) -> HookAuthorization {
        let gated = PolicyGate.decision(
            for: result,
            cwd: wd("/tmp/ws"),
            allowlist: AllowlistSnapshot(entries: entries, blocked: blocked),
            grant: .none,
            now: now,
            maskedSegments: masked,
            invocationPrefix: prefix
        )
        return HookAuthorization.project(result: gated.result, cwd: wd("/tmp/ws"))
    }

    private func allowResetHardByRule(in root: URL) throws {
        try AllowlistStore(baseDirectory: root).pin(
            AllowlistEntry(
                selector: .rule(RuleID(pack: .coreGit, pattern: "reset-hard")),
                reason: "ci",
                addedAt: now
            )
        )
    }
}

enum CorruptDenylist: CaseIterable, Sendable, CustomTestStringConvertible {
    case invalidTOML
    case nonUTF8

    var testDescription: String {
        switch self {
        case .invalidTOML: "invalid TOML"
        case .nonUTF8: "non-UTF-8 bytes"
        }
    }

    func write(to url: URL) throws {
        switch self {
        case .invalidTOML:
            try "[[block]\nexact_command = \"git reset --hard".write(to: url, atomically: true, encoding: .utf8)
        case .nonUTF8:
            try Data([0xFF, 0xFE, 0x00]).write(to: url)
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

private func makeConfigDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-denylist-fail-closed-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
