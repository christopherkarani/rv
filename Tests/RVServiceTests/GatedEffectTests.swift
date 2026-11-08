import Foundation
import Testing
import RVDomain
import RVHistory
import RVPolicy
@testable import RVService

/// Value-level checks on the decision half of each door: which effects it
/// asks for, in what order, with what content. Most cases pass no home, so
/// nothing touches disk; the one that needs dropped repo literals uses a temp
/// home and checks that only `perform` writes.
@Suite("Gated effects as values")
struct GatedEffectTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let packDeny = ShellCommand(rawValue: "rm -rf ~")
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
        #expect(apply.effects == [.judgeLog(GatedEffect.JudgeLogRow(
            at: Self.now, guardMode: .enforce, engine: .ft, hash: Self.hash(apply.result),
            subject: .live(.allow), note: "judge-unavailable: x; context: partial", isPeek: false, score: nil
        ))])
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

    @Test("observe: every shell door asks for one would-be judge row and no denial row", arguments: [
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
        #expect(decided.effects == [
            .judgeLog(GatedEffect.JudgeLogRow(
                at: Self.now, guardMode: .observe, engine: .ft, hash: Self.hash(decided.result),
                subject: .wouldBe(.deny, rule: deny.ruleID.rawValue), note: "context: partial",
                isPeek: intent == .peek, score: nil
            )),
        ])
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

    @Test("file door: enforce asks for an unredacted secret denial row; observe asks for nothing")
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
        let observe = GatedEvaluate().decideFile(
            action, home: nil, cwd: nil, host: .hook(.claude), now: Self.now, guardMode: .observe
        )
        #expect(observe.result.decision == .allow)
        #expect(observe.effects.isEmpty)
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
        // The redeemed allow asks for no denial row, only an override audit.
        #expect(first.effects == [.overrideAudit(GatedEffect.OverrideRow(
            at: Self.now, host: .hook(.claude),
            ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
            override: "allowOnce", workspace: URL(fileURLWithPath: cwd.rawValue, isDirectory: true)
        ))])
        let second = await Self.decide(.apply, command, mode: .enforce, cwd: cwd, grants: grants)
        #expect(second.effects == [try #require(Self.denialRow(second.result))])
    }
}
