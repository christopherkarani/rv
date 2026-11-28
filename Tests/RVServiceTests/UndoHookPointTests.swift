import Foundation
import RVDomain
import RVHistory
import RVPolicy
import RVUndo
import Testing
@testable import RVService

/// The hook point asks for a copy only for the destructive classes, only
/// for agent hooks, and only with hook budget to spare.
@Suite("Undo hook point")
struct UndoHookPointTests {
    static let cwd = WorkingDirectory(validating: "/tmp/app")

    static func result(_ analysis: SemanticAnalysis) -> EvaluationResult {
        EvaluationResult(
            outcome: .deny(Deny(ruleID: RuleID(pack: PackID(rawValue: "core.git"), pattern: "reset-hard"), reason: "r"),
                           matched: nil),
            matchingView: "git reset --hard", analysis: analysis)
    }

    @Test("a reset from an agent hook asks for git refs within the budget")
    func resetAsks() throws {
        let keep = try #require(UndoHookPoint.request(
            for: Self.result(.git(.reset(mode: .hard, target: nil))), command: ShellCommand(rawValue: "git reset --hard"),
            cwd: Self.cwd, host: .hook(.claude), reason: .watched, deadline: nil))
        #expect(keep.target == .gitWorkingTree)
        #expect(keep.host == "claude")
        #expect(keep.reason == .watched)
        #expect(keep.budget == UndoHookPoint.budget)
    }

    @Test("reads, soft resets, terminal callers and a missing cwd ask for nothing")
    func othersPayNothing() {
        let soft = Self.result(.git(.reset(mode: .soft, target: nil)))
        let hard = Self.result(.git(.reset(mode: .hard, target: nil)))
        #expect(UndoHookPoint.request(for: soft, command: ShellCommand(rawValue: "git reset --soft"), cwd: Self.cwd, host: .hook(.claude),
                                      reason: .watched, deadline: nil) == nil)
        #expect(UndoHookPoint.request(for: Self.result(.unknown), command: ShellCommand(rawValue: "ls"), cwd: Self.cwd, host: .hook(.claude),
                                      reason: .watched, deadline: nil) == nil)
        #expect(UndoHookPoint.request(for: hard, command: ShellCommand(rawValue: "git reset --hard"), cwd: Self.cwd, host: .tty,
                                      reason: .watched, deadline: nil) == nil)
        #expect(UndoHookPoint.request(for: hard, command: ShellCommand(rawValue: "git reset --hard"), cwd: nil, host: .hook(.claude),
                                      reason: .watched, deadline: nil) == nil)
    }

    @Test("the copy never eats the reply's share of the hook budget")
    func budgetFollowsDeadline() throws {
        let now = ContinuousClock.now
        let hard = Self.result(.git(.reset(mode: .hard, target: nil)))
        let roomy = HookDeadline(expiresAt: now + .seconds(7), now: { now })
        #expect(UndoHookPoint.request(for: hard, command: ShellCommand(rawValue: "git reset --hard"), cwd: Self.cwd, host: .hook(.claude),
                                      reason: .unlocked, deadline: roomy, now: now)?.budget == UndoHookPoint.budget)
        let tight = HookDeadline(expiresAt: now + .seconds(3), now: { now })
        let squeezed = try #require(UndoHookPoint.request(
            for: hard, command: ShellCommand(rawValue: "git reset --hard"), cwd: Self.cwd, host: .hook(.claude), reason: .unlocked,
            deadline: tight, now: now))
        #expect(squeezed.budget == .milliseconds(500))
        let spent = HookDeadline(expiresAt: now + .seconds(2), now: { now })
        #expect(UndoHookPoint.request(for: hard, command: ShellCommand(rawValue: "git reset --hard"), cwd: Self.cwd, host: .hook(.claude),
                                      reason: .unlocked, deadline: spent, now: now) == nil)
    }

    // MARK: Through the gated decision

    private static func decide(
        _ intent: EvaluationIntent, _ command: String, mode: GuardMode, cwd: WorkingDirectory?
    ) async -> [GatedEffect] {
        await GatedEvaluate().decide(
            intent, EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
            cwd: cwd, home: nil, grants: EphemeralAllowOnceTable(), now: Date(), allowlist: { .empty },
            host: .hook(.claude), tool: .bash,
            inputs: EvaluationInputs(
                guardMode: mode, judge: JudgeSelection(engine: .ft, bundle: nil, shadow: false), store: .gather(home: nil, cwd: nil))
        ).effects
    }

    private static func keeps(_ effects: [GatedEffect]) -> [UndoRequest] {
        effects.compactMap { if case .keepCopy(let keep) = $0 { keep } else { nil } }
    }

    @Test("watch mode letting a reset through asks for a copy before the denial row")
    func watchedResetKeepsACopy() async throws {
        let effects = await Self.decide(.apply, "git reset --hard", mode: .observe, cwd: Self.cwd)
        let keep = try #require(Self.keeps(effects).first)
        #expect(keep.target == .gitWorkingTree)
        #expect(keep.reason == .watched)
        #expect(keep.command == "git reset --hard")
    }

    @Test("a stop, a peek, a plain allow and a soft reset ask for no copy")
    func noCopyOtherwise() async {
        #expect(Self.keeps(await Self.decide(.apply, "git reset --hard", mode: .enforce, cwd: Self.cwd)).isEmpty)
        #expect(Self.keeps(await Self.decide(.peek, "git reset --hard", mode: .observe, cwd: Self.cwd)).isEmpty)
        #expect(Self.keeps(await Self.decide(.apply, "git status", mode: .observe, cwd: Self.cwd)).isEmpty)
        #expect(Self.keeps(await Self.decide(.apply, "git reset --soft HEAD~1", mode: .observe, cwd: Self.cwd)).isEmpty)
    }
}
