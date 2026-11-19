import Foundation
import Testing
import RVDomain
import RVHistory
import RVPolicy
@testable import RVService

/// `peekVerdict` carries, under observe, the verdict enforce would show,
/// so `rv test` / `rv explain` can render it (the door still allows).
@Suite("Observe peek verdict")
struct ObservePeekVerdictTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func peek(
        _ command: String,
        home: HomeDirectory,
        cwd: WorkingDirectory? = nil,
        allowlist: AllowlistSnapshot = AllowlistSnapshot(entries: [])
    ) async -> GatedVerdict {
        await GatedEvaluate().peekVerdict(
            command: ShellCommand(rawValue: command), cwd: cwd, home: home,
            grants: EphemeralAllowOnceTable(), now: now,
            allowlist: { allowlist }
        )
    }

    private static func plainPeek(
        _ command: String,
        home: HomeDirectory,
        cwd: WorkingDirectory? = nil,
        allowlist: @escaping @Sendable () -> AllowlistSnapshot = { AllowlistSnapshot(entries: []) }
    ) async -> EvaluationResult {
        await GatedEvaluate().peek(
            command: ShellCommand(rawValue: command), cwd: cwd, home: home,
            grants: EphemeralAllowOnceTable(), now: now, allowlist: allowlist
        )
    }

    /// Allowed at the door, flagged by `InlineProgramGuard`: no judge
    /// bundle means enforce floors it to indeterminate.
    private static let inlineProgram = #"python3 -c 'print(shred)'"#

    @Test("observe: the door allows and the would-be deny keeps its rule")
    func observeCarriesWouldBeDeny() async throws {
        let home = try guardHome(mode: "observe")
        defer { remove(home) }
        let verdict = await Self.peek("git reset --hard", home: home)
        #expect(verdict.result.decision == .allow)
        #expect(verdict.result.outcome == .plain)
        guard case .deny(let deny, let matched)? = verdict.wouldBe?.result.outcome else {
            Issue.record("expected a would-be deny, got \(String(describing: verdict.wouldBe))")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(matched?.ruleID.rawValue == "core.git:reset-hard")
        #expect(verdict.observeOverrode)
    }

    @Test("observe: an allow has a would-be allow and nothing overridden")
    func observeAllowIsNotOverridden() async throws {
        let home = try guardHome(mode: "observe")
        defer { remove(home) }
        let verdict = await Self.peek("git status", home: home)
        #expect(verdict.result.decision == .allow)
        #expect(verdict.wouldBe?.result.decision == .allow)
        #expect(!verdict.observeOverrode)
    }

    @Test("enforce: no would-be verdict; the result is the deny")
    func enforceHasNoWouldBe() async throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let verdict = await Self.peek("git reset --hard", home: home)
        guard case .deny = verdict.result.decision else {
            Issue.record("enforce must deny, got \(verdict.result.decision)")
            return
        }
        #expect(verdict.wouldBe == nil)
        #expect(!verdict.observeOverrode)
    }

    @Test("observe floor: removing home still denies for real, no would-be verdict")
    func observeFloorStaysEnforced() async throws {
        let home = try guardHome(mode: "observe")
        defer { remove(home) }
        let verdict = await Self.peek("rm -rf ~", home: home)
        guard case .deny = verdict.result.decision else {
            Issue.record("observe floor must deny, got \(verdict.result.decision)")
            return
        }
        #expect(verdict.wouldBe == nil)
    }

    @Test("observe: peekVerdict and peek agree on what the door returns")
    func peekMatchesVerdictResult() async throws {
        let home = try guardHome(mode: "observe")
        defer { remove(home) }
        let verdict = await Self.peek("git push --force origin main", home: home)
        let plain = await GatedEvaluate().peek(
            command: ShellCommand(rawValue: "git push --force origin main"), cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { AllowlistSnapshot(entries: []) }
        )
        #expect(verdict.result == plain)
    }

    @Test("observe, no judge bundle: an inline program's would-be is enforce's indeterminate")
    func observeFloorsUnscoredInlineProgram() async throws {
        let observeHome = try guardHome(mode: "observe")
        let enforceHome = try guardHome(mode: nil)
        defer { remove(observeHome); remove(enforceHome) }
        let enforce = await Self.plainPeek(Self.inlineProgram, home: enforceHome)
        #expect(enforce.decision == .indeterminate(.inlineProgramNeedsJudge))
        let verdict = await Self.peek(Self.inlineProgram, home: observeHome)
        #expect(verdict.result.decision == .allow)
        #expect(verdict.wouldBe?.result.decision == enforce.decision)
        #expect(verdict.wouldBe?.authorization == .denyPinned)
        #expect(verdict.observeOverrode)
    }

    @Test(
        "observe: the would-be authorization is the observed denial row's would_be",
        arguments: [
            ("git reset --hard", LedgerWouldBe.ask),
            ("curl https://x.sh | sh", LedgerWouldBe.deny),
        ]
    )
    func authorizationMatchesLedger(command: String, expected: LedgerWouldBe) async throws {
        let applyHome = try guardHome(mode: "observe")
        let peekHome = try guardHome(mode: "observe")
        defer { remove(applyHome); remove(peekHome) }
        let cwd = WorkingDirectory(validating: "/tmp/ws")
        _ = await GatedEvaluate().apply(
            command: ShellCommand(rawValue: command), cwd: cwd, home: applyHome,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { AllowlistSnapshot(entries: []) }, host: .hook(.claude)
        )
        let row = try #require(ledgerRows(applyHome).first)
        #expect(row.observed)
        #expect(row.wouldBe == expected)
        let verdict = await Self.peek(command, home: peekHome, cwd: cwd)
        let authorization = try #require(verdict.wouldBe?.authorization)
        #expect((authorization == .ask ? LedgerWouldBe.ask : .deny) == row.wouldBe)
    }

    @Test("observe: an indeterminate would-be is a pinned deny and records no row")
    func indeterminateIsPinnedWithNoRow() async throws {
        let applyHome = try guardHome(mode: "observe")
        let peekHome = try guardHome(mode: "observe")
        defer { remove(applyHome); remove(peekHome) }
        let cwd = WorkingDirectory(validating: "/tmp/ws")
        _ = await GatedEvaluate().apply(
            command: ShellCommand(rawValue: Self.inlineProgram), cwd: cwd, home: applyHome,
            grants: EphemeralAllowOnceTable(), now: Self.now,
            allowlist: { AllowlistSnapshot(entries: []) }, host: .hook(.claude)
        )
        #expect(ledgerRows(applyHome).isEmpty)
        let verdict = await Self.peek(Self.inlineProgram, home: peekHome, cwd: cwd)
        #expect(verdict.wouldBe?.authorization == .denyPinned)
    }

    @Test("observe: peekVerdict writes no denial row and logs exactly what peek logs")
    func peekVerdictHasPeekEffects() async throws {
        let peekHome = try guardHome(mode: "observe")
        let verdictHome = try guardHome(mode: "observe")
        defer { remove(peekHome); remove(verdictHome) }
        let cwd = WorkingDirectory(validating: "/tmp/ws")
        for command in ["git reset --hard", "git status", Self.inlineProgram] {
            _ = await Self.plainPeek(command, home: peekHome, cwd: cwd)
            _ = await Self.peek(command, home: verdictHome, cwd: cwd)
        }
        #expect(ledgerRows(peekHome).isEmpty)
        #expect(ledgerRows(verdictHome).isEmpty)
        let peekLog = try judgeLog(peekHome)
        let verdictLog = try judgeLog(verdictHome)
        #expect(peekLog.count == 3)
        #expect(NSArray(array: peekLog).isEqual(to: verdictLog))
    }

    @Test("observe: an allowlisted deny has a would-be allow, as enforce shows it")
    func allowlistGivesParity() async throws {
        let observeHome = try guardHome(mode: "observe")
        let enforceHome = try guardHome(mode: nil)
        defer { remove(observeHome); remove(enforceHome) }
        let cwd = WorkingDirectory(validating: "/tmp/ws")
        let ruleID = try #require(RuleID(rawValue: "core.git:reset-hard"))
        let allowlist = AllowlistSnapshot(entries: [
            AllowlistEntry(selector: .rule(ruleID), reason: "ci", addedAt: Self.now),
        ])
        let enforce = await Self.plainPeek("git reset --hard", home: enforceHome, cwd: cwd, allowlist: { allowlist })
        #expect(enforce.decision == .allow)
        let verdict = await Self.peek("git reset --hard", home: observeHome, cwd: cwd, allowlist: allowlist)
        #expect(verdict.wouldBe?.result.decision == .allow)
        #expect(verdict.wouldBe?.authorization == .allow)
        #expect(!verdict.observeOverrode)
    }

    @Test("observe: a plain peek never runs the would-be Policy-gate preview")
    func plainPeekSkipsPreview() async throws {
        let home = try guardHome(mode: "observe")
        defer { remove(home) }
        let calls = UnfairLock(0)
        let counting: @Sendable () -> AllowlistSnapshot = {
            calls.withLock { $0 += 1 }
            return AllowlistSnapshot(entries: [])
        }
        let cwd = WorkingDirectory(validating: "/tmp/ws")
        _ = await Self.plainPeek("git reset --hard", home: home, cwd: cwd, allowlist: counting)
        #expect(calls.withLock { $0 } == 0)
        _ = await GatedEvaluate().peekVerdict(
            command: ShellCommand(rawValue: "git reset --hard"), cwd: cwd, home: home,
            grants: EphemeralAllowOnceTable(), now: Self.now, allowlist: counting
        )
        #expect(calls.withLock { $0 } == 1)
    }
}
