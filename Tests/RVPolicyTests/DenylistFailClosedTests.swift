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
        #expect(deny == PolicyGate.denylistUnreadable)
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

    @Test func corruptDenylist_suspendedOverrideDoesNotSpendGrant() async throws {
        let ruleID = RuleID(pack: .coreGit, pattern: "reset-hard")
        let snap = AllowlistSnapshot(
            entries: [AllowlistEntry(selector: .rule(ruleID), reason: "ci", addedAt: now)],
            blocked: .unreadable
        )
        let grants = EphemeralAllowOnceTable()
        #expect(
            await grants.plant(
                matchingView: "git reset --hard", cwd: wd("/tmp/ws"), codeHash: "denylist-corrupt",
                now: now
            ) == .planted
        )
        let gated = await PolicyGate.consumingGrant(
            for: resetHardDeny(),
            cwd: wd("/tmp/ws"),
            allowlist: snap,
            grants: grants,
            now: now
        )
        #expect(gated.override == .none)
        #expect(gated.result.decision == .deny(PolicyGate.denylistUnreadable))
        #expect(await grants.hasGrant(matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now))
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
