import Foundation
import Testing
import RVDomain
import RVHistory
import RVHooks
import RVPolicy
@testable import RVService
import Synchronization

/// Value-level checks on the decision half of each door: which effects it
/// asks for, in what order, with what content. Most cases pass no home, so
/// nothing touches disk; the one that needs dropped repo literals uses a temp
/// home and checks that only `perform` writes.
@Suite("Gated effects as values")
struct GatedEffectTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    // Not `rm -rf ~`: that also removes rv's install, which observe never relaxes.
    private static let packDeny = ShellCommand(rawValue: "rm -rf ~/Documents")
    /// Pack-allowed and outside the safe lane, so it reaches the judge.
    private static let judged = ShellCommand(rawValue: "python3 deploy.py --prod")
    private static let fakeBundle = URL(fileURLWithPath: "/nonexistent/rv-fake-bundle", isDirectory: true)

    private static func inputs(_ mode: GuardMode, bundle: URL? = nil) -> EvaluationInputs {
        EvaluationInputs(
            guardMode: mode,
            judge: JudgeSelection(engine: .ft, bundle: bundle),
            store: .gather(home: nil, cwd: nil)
        )
    }

    private static func request(_ command: ShellCommand) -> EvaluationRequest {
        EvaluationRequest(command: command, enabledPacks: dayOnePackIDs)
    }

    private static func decide(
        _ intent: EvaluationIntent,
        _ command: ShellCommand,
        mode: GuardMode,
        door: GatedEvaluate = GatedEvaluate(),
        bundle: URL? = nil,
        cwd: WorkingDirectory? = nil,
        grants: EphemeralAllowOnceTable = EphemeralAllowOnceTable()
    ) async -> (result: EvaluationResult, effects: [GatedEffect]) {
        await door.decide(
            intent, request(command), cwd: cwd, home: nil, grants: grants, now: now,
            allowlist: { .empty }, host: .hook(.claude), tool: .bash,
            inputs: inputs(mode, bundle: bundle)
        )
    }

    private static func hash(_ result: EvaluationResult) -> String {
        String(RVDigest.sha256Hex([UInt8](result.matchingView.rawValue.utf8)).prefix(16))
    }

    /// The shell-door denial row for a pack or judge deny; nil otherwise.
    private static func denialRow(_ result: EvaluationResult) -> GatedEffect? {
        guard case .deny(let deny) = result.decision else { return nil }
        return .denialRow(GatedEffect.DenialRow(
            at: now, host: .hook(.claude), tool: .bash, ruleID: deny.ruleID,
            category: .pack(deny.ruleID.pack), path: ""
        ))
    }

    @Test("enforce pack deny: peek asks for nothing, apply asks for one denial row")
    func peekEmitsNoDenialRow() async throws {
        let peek = await Self.decide(.peek, Self.packDeny, mode: .enforce)
        #expect(peek.effects.isEmpty)
        let apply = await Self.decide(.apply, Self.packDeny, mode: .enforce)
        #expect(apply.effects == [try #require(Self.denialRow(apply.result))])
    }

    @Test("the hook's session id rides on the denial row; command text never does")
    func denialRowCarriesTheHookSession() async throws {
        let session = try #require(SessionID(validating: "0b7f3c2e-claude-session"))
        let enforced = await HookSessionAttribution.$current.withValue(session) {
            await Self.decide(.apply, Self.packDeny, mode: .enforce)
        }
        guard case .denialRow(let row)? = enforced.effects.last else {
            Issue.record("denial row expected, got \(enforced.effects)")
            return
        }
        #expect(row.session == session.rawValue)
        #expect(row.path.contains("Documents") == false)

        let observed = await HookSessionAttribution.$current.withValue(session) {
            await Self.decide(.apply, Self.packDeny, mode: .observe)
        }
        guard case .denialRow(let observedRow)? = observed.effects.last else {
            Issue.record("observed denial row expected, got \(observed.effects)")
            return
        }
        #expect(observedRow.session == session.rawValue)

        let unbound = await Self.decide(.apply, Self.packDeny, mode: .enforce)
        guard case .denialRow(let plain)? = unbound.effects.last else {
            Issue.record("denial row expected")
            return
        }
        #expect(plain.session == nil, "the TTY and other doors name no session")

        // A host id that is not an opaque token (here: command text) is dropped.
        let hostile = try #require(SessionID(validating: "rm -rf ~/Documents"))
        let dropped = await HookSessionAttribution.$current.withValue(hostile) {
            await Self.decide(.apply, Self.packDeny, mode: .enforce)
        }
        guard case .denialRow(let droppedRow)? = dropped.effects.last else {
            Issue.record("denial row expected")
            return
        }
        #expect(droppedRow.session == nil)
    }

    @Test("enforce judge review: judge log precedes the denial row; peek drops only the denial row")
    func judgeLogThenDenialRow() async throws {
        let door = GatedEvaluate(
            EvaluateSession(),
            judge: EffectFixedJudge(run: .verdict(try effectVerdict(choice: "review", risk: 0.5)))
        )
        func judgeLog(_ result: EvaluationResult, isPeek: Bool) -> GatedEffect {
            .judgeLog(GatedEffect.JudgeLogRow(
                at: Self.now, guardMode: .enforce, engine: .ft, hash: Self.hash(result),
                subject: .live(.deny), note: "context: partial", isPeek: isPeek,
                score: GatedEffect.JudgeLogRow.Score(
                    choice: "review", action: "review", risk: 0.5, malicious: 0,
                    checkpoint: "fake", milliseconds: 1, truncated: false
                )
            ))
        }
        let apply = await Self.decide(.apply, Self.judged, mode: .enforce, door: door, bundle: Self.fakeBundle)
        #expect(apply.effects == [judgeLog(apply.result, isPeek: false), try #require(Self.denialRow(apply.result))])
        let peek = await Self.decide(.peek, Self.judged, mode: .enforce, door: door, bundle: Self.fakeBundle)
        #expect(peek.effects == [judgeLog(peek.result, isPeek: true)])
    }

    @Test("enforce, judge unavailable: a risky inline program is floored; its judge log keeps the live allow")
    func packsOnlyFloorKeepsUnflooredLog() async throws {
        let inline = ShellCommand(rawValue: #"python3 -c 'print(shred)'"#)
        let door = GatedEvaluate(EvaluateSession(), judge: EffectFixedJudge(run: .unavailable("x")))
        let apply = await Self.decide(.apply, inline, mode: .enforce, door: door, bundle: Self.fakeBundle)
        #expect(apply.result.decision == .indeterminate(.inlineProgramNeedsJudge))
        // The refusal is chained as a marked deny (F6); never on the ledger.
        let indeterminate = RuleID(pack: PackID(rawValue: "rv.indeterminate"), pattern: "inlineProgramNeedsJudge")
        #expect(apply.effects == [
            .judgeLog(GatedEffect.JudgeLogRow(
                at: Self.now, guardMode: .enforce, engine: .ft, hash: Self.hash(apply.result),
                subject: .live(.allow), note: "judge-unavailable: x; context: partial", isPeek: false, score: nil
            )),
            .denialRow(GatedEffect.DenialRow(
                at: Self.now, host: .hook(.claude), tool: .bash, ruleID: indeterminate,
                category: .pack(indeterminate.pack), path: "", indeterminate: .inlineProgramNeedsJudge
            )),
        ])
    }

    @Test("decide writes nothing; the audit precedes the judge log and denial row; peek keeps the audit")
    func auditOrderAndNoWritesBeforePerform() async throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let repo = try effectRepo(in: home, named: "repo", dropping: ["dropped.env"])
        let cwd = try #require(WorkingDirectory(validating: repo.path))
        let door = GatedEvaluate(
            EvaluateSession(),
            judge: EffectFixedJudge(run: .verdict(try effectVerdict(choice: "review", risk: 0.5)))
        )
        func decide(_ intent: EvaluationIntent) async -> (result: EvaluationResult, effects: [GatedEffect]) {
            await door.decide(
                intent, Self.request(Self.judged), cwd: cwd, home: home, grants: EphemeralAllowOnceTable(),
                now: Self.now, allowlist: { .empty }, host: .hook(.claude), tool: .bash,
                inputs: EvaluationInputs(
                    guardMode: .enforce,
                    judge: JudgeSelection(engine: .ft, bundle: Self.fakeBundle),
                    store: .gather(home: home, cwd: cwd)
                )
            )
        }
        func kinds(_ effects: [GatedEffect]) -> [String] {
            effects.map {
                switch $0 {
                case .exemptionAudit: "audit"
                case .judgeLog: "judgeLog"
                case .denialRow: "denialRow"
                case .overrideAudit: "overrideAudit"
                }
            }
        }
        let audit = GatedEffect.exemptionAudit(GatedEffect.ExemptionAudit(
            dropped: ["dropped.env"], workspace: URL(fileURLWithPath: cwd.rawValue, isDirectory: true), at: Self.now
        ))
        let apply = await decide(.apply)
        #expect(kinds(apply.effects) == ["audit", "judgeLog", "denialRow"])
        #expect(apply.effects.first == audit)
        let peek = await decide(.peek)
        #expect(kinds(peek.effects) == ["audit", "judgeLog"])
        #expect(peek.effects.first == audit)
        #expect(try exemptionRows(home).isEmpty)
        #expect((try? judgeLogText(home)) == nil)
        #expect(ledgerRows(home).isEmpty)
        GatedEvaluate.perform(apply.effects, home: home)
        #expect(try exemptionRows(home).map(\.dropped) == [["dropped.env"]])
        #expect(try judgeLog(home).count == 1)
        #expect(ledgerRows(home).count == 1)
    }

    /// Past the hook deadline the decision asks for no denial row, and only
    /// that row is dropped: the client gave up on the reply, but the audit
    /// and judge log describe the evaluation.
    @Test("apply past the hook deadline: the shell writes the audit and judge log but no denial row")
    func lateApplyWritesNoDenialRow() async throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let repo = try effectRepo(in: home, named: "repo", dropping: ["dropped.env"])
        let cwd = try #require(WorkingDirectory(validating: repo.path))
        let door = GatedEvaluate(
            EvaluateSession(),
            judge: EffectFixedJudge(run: .verdict(try effectVerdict(choice: "review", risk: 0.5)))
        )
        let inputs = EvaluationInputs(
            guardMode: .enforce,
            judge: JudgeSelection(engine: .ft, bundle: Self.fakeBundle),
            store: .gather(home: home, cwd: cwd)
        )
        let stale = HookDeadline(receivedAt: .now - .seconds(30))
        let (decided, result) = await HookDeadline.$current.withValue(stale) {
            let decided = await door.decide(
                .apply, Self.request(Self.judged), cwd: cwd, home: home, grants: EphemeralAllowOnceTable(),
                now: Self.now, allowlist: { .empty }, host: .hook(.claude), tool: .bash, inputs: inputs
            )
            let result = await door.gated(
                .apply, Self.request(Self.judged), cwd: cwd, home: home, grants: EphemeralAllowOnceTable(),
                now: Self.now, allowlist: { .empty }, host: .hook(.claude), tool: .bash, inputs: inputs
            )
            return (decided, result)
        }
        guard case .deny = result.decision else {
            Issue.record("judge review must deny, got \(result.decision)")
            return
        }
        #expect(!decided.effects.contains { if case .denialRow = $0 { true } else { false } })
        #expect(stale.hasTripped)
        #expect(try exemptionRows(home).map(\.dropped) == [["dropped.env"]])
        #expect(try judgeLog(home).count == 1)
        #expect(ledgerRows(home).isEmpty)
    }

    /// Parity with the inline writes: an enforced apply checks the hook
    /// deadline even when it allows, so a late allow trips it and the hook
    /// door answers with the timeout deny.
    @Test("enforce: a late allowed apply still trips the hook deadline")
    func lateAllowedApplyTripsDeadline() async throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let repo = try effectRepo(in: home, named: "repo", dropping: [])
        let cwd = try #require(WorkingDirectory(validating: repo.path))
        let door = GatedEvaluate(EvaluateSession(), judge: EffectFixedJudge(run: .unavailable("test")))
        let inputs = EvaluationInputs(
            guardMode: .enforce,
            judge: JudgeSelection(engine: .ft, bundle: Self.fakeBundle),
            store: .gather(home: home, cwd: cwd)
        )
        let stale = HookDeadline(receivedAt: .now - .seconds(30))
        let result = await HookDeadline.$current.withValue(stale) {
            await door.gated(
                .apply, Self.request(ShellCommand(rawValue: "ls")), cwd: cwd, home: home, grants: EphemeralAllowOnceTable(),
                now: Self.now, allowlist: { .empty }, host: .hook(.claude), tool: .bash, inputs: inputs
            )
        }
        guard case .allow = result.decision else {
            Issue.record("plain ls must allow, got \(result.decision)")
            return
        }
        #expect(stale.hasTripped)
    }

    /// As for a deny: past the hook deadline an indeterminate refusal asks
    /// for no denial row (`HookDoor` answers with the timeout deny).
    @Test("enforce: a late indeterminate apply asks for no denial row")
    func lateIndeterminateApplyEmitsNoDenialRow() async throws {
        let stale = HookDeadline(receivedAt: .now - .seconds(30))
        let decided = await HookDeadline.$current.withValue(stale) {
            await Self.decide(.apply, ShellCommand(rawValue: "rv host mode claude off"), mode: .enforce)
        }
        guard case .indeterminate = decided.result.decision else {
            Issue.record("rv administration from the agent must be indeterminate, got \(decided.result.decision)")
            return
        }
        #expect(!decided.effects.contains { if case .denialRow = $0 { true } else { false } })
        #expect(stale.hasTripped)
    }

    @Test("observe: every shell door asks for one would-be judge row; apply adds an observed denial row", arguments: [
        EvaluationIntent.peek, .apply,
    ])
    func observeShellDoors(_ intent: EvaluationIntent) async throws {
        let decided = await Self.decide(intent, Self.packDeny, mode: .observe)
        #expect(decided.result.outcome == .plain)
        let wouldBe = GatedEvaluate().decideAgent(
            Self.request(Self.packDeny), cwd: nil, home: nil, now: Self.now, inputs: Self.inputs(.enforce)
        ).result
        guard case .deny(let deny) = wouldBe.decision else {
            Issue.record("pack deny expected, got \(wouldBe.decision)")
            return
        }
        let judgeLog = GatedEffect.judgeLog(GatedEffect.JudgeLogRow(
            at: Self.now, guardMode: .observe, engine: .ft, hash: Self.hash(decided.result),
            subject: .wouldBe(.deny, rule: deny.ruleID.rawValue), note: "context: partial",
            isPeek: intent == .peek, score: nil
        ))
        switch intent {
        case .peek:
            #expect(decided.effects == [judgeLog])
        case .apply:
            #expect(decided.effects == [
                judgeLog,
                .denialRow(GatedEffect.DenialRow(
                    at: Self.now, host: .hook(.claude), tool: .bash, ruleID: deny.ruleID,
                    category: .pack(deny.ruleID.pack), path: "", observed: true, wouldBe: .deny
                )),
            ])
        }
    }

    /// `would_be` is what the enforced hook would have surfaced: the same
    /// `HookAuthorization.project` the hook door runs over the enforced
    /// apply result. An unlockable deny asks; a pinned one (secret) denies.
    @Test("observe apply: the observed row's would_be matches the enforced hook projection", arguments: [
        ("git reset --hard", LedgerWouldBe.ask),
        // A secret read is not observed: it denies in every mode.
        ("rm -r .git", LedgerWouldBe.deny),
    ])
    func observeWouldBeMatchesEnforcedProjection(_ command: String, _ expected: LedgerWouldBe) async throws {
        let cwd = try #require(WorkingDirectory(validating: "/nonexistent/rv-effects-ws"))
        let shell = ShellCommand(rawValue: command)
        let enforced = await Self.decide(.apply, shell, mode: .enforce, cwd: cwd)
        guard case .deny = enforced.result.decision else {
            Issue.record("\(command) must deny under enforce, got \(enforced.result.decision)")
            return
        }
        let projected = HookAuthorization.project(result: enforced.result, cwd: cwd)
        #expect(projected == (expected == .ask ? .ask : .denyPinned), "\(command)")
        let observed = await Self.decide(.apply, shell, mode: .observe, cwd: cwd)
        #expect(observed.result.decision == .allow)
        let rows = observed.effects.compactMap { effect -> GatedEffect.DenialRow? in
            if case .denialRow(let row) = effect { return row }
            return nil
        }
        #expect(rows.count == 1, "\(command)")
        #expect(rows.first?.observed == true)
        #expect(rows.first?.wouldBe == expected, "\(command)")
    }

    /// The one case where observe `ask` depends on `boundReview == .mandatoryHuman`
    /// surviving scriptScreen -> JudgeRuntime.observe -> the Policy-gate preview:
    /// a plain push is a builtin-pack deny that only a carried mandatory-human bind
    /// keeps unpinned (HookAuthorization.isPinned).
    @Test("observe would-be ask survives a mandatory-human bind in a real git repo")
    func observeWouldBeAskCarriesMandatoryHumanBind() async throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-wouldbe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        for args in [["init", "-q"], ["remote", "add", "origin", "https://example.invalid/r.git"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = ["-C", repo.path] + args
            try git.run()
            git.waitUntilExit()
            try #require(git.terminationStatus == 0)
        }
        let cwd = try #require(WorkingDirectory(validating: repo.path))
        let shell = ShellCommand(rawValue: "git push origin feature")

        let enforced = await Self.decide(.apply, shell, mode: .enforce, cwd: cwd)
        guard case .deny = enforced.result.decision else {
            Issue.record("push must deny under enforce, got \(enforced.result.decision)")
            return
        }
        guard case .mandatoryHuman = enforced.result.boundReview else {
            Issue.record("expected a mandatory-human bind, got \(String(describing: enforced.result.boundReview))")
            return
        }
        #expect(HookAuthorization.project(result: enforced.result, cwd: cwd) == .ask)

        let observed = await Self.decide(.apply, shell, mode: .observe, cwd: cwd)
        #expect(observed.result.decision == .allow)
        let rows = observed.effects.compactMap { effect -> GatedEffect.DenialRow? in
            if case .denialRow(let row) = effect { return row }
            return nil
        }
        #expect(rows.count == 1)
        #expect(rows.first?.observed == true)
        #expect(rows.first?.wouldBe == .ask)
    }

    @Test("agent door never asks for a denial row")
    func agentNeverRecords() throws {
        let door = GatedEvaluate(
            EvaluateSession(),
            judge: EffectFixedJudge(run: .verdict(try effectVerdict(choice: "review", risk: 0.5)))
        )
        let packDeny = door.decideAgent(
            Self.request(Self.packDeny), cwd: nil, home: nil, now: Self.now, inputs: Self.inputs(.enforce)
        )
        #expect(packDeny.effects.isEmpty)
        let review = door.decideAgent(
            Self.request(Self.judged), cwd: nil, home: nil, now: Self.now,
            inputs: Self.inputs(.enforce, bundle: Self.fakeBundle)
        )
        guard case .deny = review.result.decision else {
            Issue.record("judge review must deny, got \(review.result.decision)")
            return
        }
        #expect(review.effects.count == 1)
        guard case .judgeLog(let row) = review.effects.first else {
            Issue.record("expected a judge-log effect, got \(review.effects)")
            return
        }
        #expect(row.subject == .live(.deny))
        #expect(row.isPeek == false)
    }

    @Test("file door: enforce and observe both ask for an unredacted secret denial row")
    func fileDoor() throws {
        let path = "/nonexistent/rv-effects/.env"
        let action = FileToolAction(kind: .read, path: FileToolPath(rawValue: path))
        let enforce = GatedEvaluate().decideFile(
            action, home: nil, cwd: nil, host: .hook(.claude), now: Self.now, guardMode: .enforce
        )
        guard case .deny(let deny) = enforce.result.decision else {
            Issue.record("secret read must deny, got \(enforce.result.decision)")
            return
        }
        #expect(enforce.effects == [
            .denialRow(GatedEffect.DenialRow(
                at: Self.now, host: .hook(.claude), tool: .file(.read), ruleID: deny.ruleID,
                category: .secret(.environment), path: path
            )),
        ])
        // A secret read denies in every mode: observe records it enforced.
        let observe = GatedEvaluate().decideFile(
            action, home: nil, cwd: nil, host: .hook(.claude), now: Self.now, guardMode: .observe
        )
        #expect(observe.result.decision == enforce.result.decision)
        #expect(observe.effects == enforce.effects)
    }

    /// Parity with the inline writes: an enforced file read checks the hook
    /// deadline whatever the verdict, so a late allow trips it and a late
    /// deny asks for no denial row.
    @Test("file door: a late enforced read trips the hook deadline and asks for no denial row", arguments: [
        "/nonexistent/rv-effects/notes.txt", "/nonexistent/rv-effects/.env",
    ])
    func lateFileReadTripsDeadline(_ path: String) {
        let action = FileToolAction(kind: .read, path: FileToolPath(rawValue: path))
        let stale = HookDeadline(receivedAt: .now - .seconds(30))
        let decided = HookDeadline.$current.withValue(stale) {
            GatedEvaluate().decideFile(
                action, home: nil, cwd: nil, host: .hook(.claude), now: Self.now, guardMode: .enforce
            )
        }
        #expect((decided.result.decision == .allow) == path.hasSuffix("notes.txt"))
        #expect(stale.hasTripped)
        #expect(decided.effects.isEmpty)
    }

    /// SEC-003: the grant is spent inside `decide`, not by applying effects.
    @Test("apply spends a grant inside the decision; the redeemed allow asks for an override audit, not a denial row")
    func grantSpendIsInline() async throws {
        let grants = EphemeralAllowOnceTable()
        let cwd = wd("/tmp/ws")
        #expect(
            await grants.plant(
                matchingView: "git reset --hard", cwd: cwd, codeHash: "effects-grant", now: Self.now
            ) == .planted
        )
        let command = ShellCommand(rawValue: "git reset --hard")
        let first = await Self.decide(.apply, command, mode: .enforce, cwd: cwd, grants: grants)
        #expect(first.result.decision == .allow)
        let second = await Self.decide(.apply, command, mode: .enforce, cwd: cwd, grants: grants)
        let denied = try #require(Self.denialRow(second.result))
        #expect(second.effects == [denied])
        guard case .denialRow(let denial) = denied else {
            Issue.record("expected a denial row")
            return
        }
        // The redeemed allow asks for no denial row, only an override audit
        // carrying the deny's rows for when it cannot be written.
        #expect(first.effects == [.overrideAudit(GatedEffect.OverrideRow(
            at: Self.now, host: .hook(.claude),
            ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
            override: "allowOnce", workspace: URL(fileURLWithPath: cwd.rawValue, isDirectory: true),
            denial: denial
        ))])
    }

    private final class Flag: Sendable {
        let raised = Mutex(false)
        var isRaised: Bool { raised.withLock { $0 } }
        func raise() { raised.withLock { $0 = true } }
    }

    /// L4: an override decided as the hook deadline passes carries no
    /// fallback deny rows, as no deny row is written past the deadline.
    /// The allowlist load (after the gate's own deadline check) moves the
    /// fake clock past the deadline.
    @Test("an override that lands past the hook deadline carries no deny rows")
    func lateOverrideCarriesNoDenyRows() async throws {
        let command = ShellCommand(rawValue: "git reset --hard")
        let rule = RuleID(pack: .coreGit, pattern: "reset-hard")
        let allowlist = AllowlistSnapshot(entries: [
            AllowlistEntry(selector: .rule(rule), reason: "test", addedAt: Self.now.addingTimeInterval(-60)),
        ])
        let late = Flag()
        let base = ContinuousClock.now
        let deadline = HookDeadline(
            expiresAt: base.advanced(by: .seconds(60)),
            now: { late.isRaised ? base.advanced(by: .seconds(120)) : base })
        let decided = await HookDeadline.$current.withValue(deadline) {
            await GatedEvaluate().decide(
                .apply, Self.request(command), cwd: wd("/tmp/ws"), home: nil, grants: EphemeralAllowOnceTable(),
                now: Self.now, allowlist: { late.raise(); return allowlist }, host: .hook(.claude), tool: .bash,
                inputs: Self.inputs(.enforce))
        }
        #expect(decided.result.decision == .allow)
        let overrides = decided.effects.compactMap { effect -> GatedEffect.OverrideRow? in
            if case .overrideAudit(let row) = effect { return row }
            return nil
        }
        #expect(overrides.count == 1)
        #expect(overrides.first?.ruleID == rule)
        #expect(overrides.first.map { $0.denial == nil } == true)
        #expect(deadline.hasTripped)
    }

    private final class Calls: Sendable {
        let count = Mutex(0)
        func next() -> Int { count.withLock { $0 += 1; return $0 } }
    }

    /// An allow-once grant spent in time keeps its reply when the deadline
    /// passes after: `HookDoor` sends it, not the timeout deny, so the deny
    /// it becomes if the override row fails keeps its deny rows. The fake
    /// clock is in time for the gate's check and the grant claim (the first
    /// two reads) and late from the third, the check after the gate.
    @Test("an allow-once spent in time keeps its deny rows when the deadline passes after")
    func spentGrantKeepsDenyRowsPastTheDeadline() async throws {
        let grants = EphemeralAllowOnceTable()
        let cwd = wd("/tmp/ws")
        #expect(
            await grants.plant(
                matchingView: "git reset --hard", cwd: cwd, codeHash: "late-grant", now: Self.now
            ) == .planted
        )
        let command = ShellCommand(rawValue: "git reset --hard")
        let calls = Calls()
        let base = ContinuousClock.now
        let deadline = HookDeadline(
            expiresAt: base.advanced(by: .seconds(60)),
            now: { calls.next() <= 2 ? base : base.advanced(by: .seconds(120)) })
        let decided = await HookDeadline.$current.withValue(deadline) {
            await Self.decide(.apply, command, mode: .enforce, cwd: cwd, grants: grants)
        }
        #expect(decided.result.decision == .allow, "the grant must be spent in time")
        #expect(deadline.hasTripped)
        #expect(deadline.requiresTimeoutReply == false)
        let overrides = decided.effects.compactMap { effect -> GatedEffect.OverrideRow? in
            if case .overrideAudit(let row) = effect { return row }
            return nil
        }
        #expect(overrides.count == 1)
        #expect(overrides.first?.override == "allowOnce")
        #expect(overrides.first?.denial?.ruleID == RuleID(pack: .coreGit, pattern: "reset-hard"))
    }
}
