import Foundation
import Testing
import RVDomain
import RVEngine
import RVPolicy
@testable import RVService

/// The observe would-be verdict is the enforce peek verdict.
///
/// Every engine-corpus command (and the everyday commands the hook-local
/// harness sends) goes through the shell door twice with the same inputs
/// but the guard mode: an enforce peek, and an observe peek that shows the
/// would-be. Wherever observe let the command run (the observe floor did
/// not hold), the would-be must be exactly what enforce returned, and its
/// authorization exactly enforce's projection. The judge is stubbed: it
/// allows, blocks, is unavailable (the packs-only floor), has no bundle,
/// fails closed (failed, warming, busy), or answers late (the late-result
/// row is logged). One run also holds live allow-once grants, so the
/// Policy-gate preview redeems some denies through them.
@Suite("Observe would-be is the enforce peek")
struct ObserveWouldBeParityTests {
    enum Answer: String, CaseIterable, Sendable {
        case allow, block, unavailable, noBundle, failed, warming, busy, late
    }

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let bundle = URL(fileURLWithPath: "/nonexistent/rv-fake-bundle", isDirectory: true)

    /// One rule allowlisted, so the Policy-gate preview turns some denies
    /// into allows on both sides.
    private static let allowlist: AllowlistSnapshot = {
        let rule = RuleID(rawValue: "core.git:reset-hard")!
        return AllowlistSnapshot(entries: [AllowlistEntry(selector: .rule(rule), reason: "parity", addedAt: now)])
    }()

    private static func door(_ answer: Answer) throws -> (GatedEvaluate, JudgeSelection) {
        let run: JudgeRuntime.JudgeRun
        switch answer {
        case .allow: run = .verdict(try effectVerdict(choice: "allow", risk: 0.05))
        case .block: run = .verdict(try effectVerdict(choice: "block", risk: 0.95))
        case .unavailable, .noBundle: run = .unavailable("parity")
        case .failed: run = .failed
        case .warming: run = .warming
        case .busy: run = .busy
        case .late:
            let late = LateJudge(answer: .verdict(try effectVerdict(choice: "allow", risk: 0.05)))
            return (GatedEvaluate(EvaluateSession(), judge: late), JudgeSelection(engine: .ft, bundle: bundle))
        }
        let selection = JudgeSelection(engine: .ft, bundle: answer == .noBundle ? nil : bundle)
        return (GatedEvaluate(EvaluateSession(), judge: EffectFixedJudge(run: run)), selection)
    }

    /// The enforce peek and the observe would-be for one command.
    private static func both(
        _ command: String, door: GatedEvaluate, selection: JudgeSelection,
        home: HomeDirectory, cwd: WorkingDirectory, store: PolicyStoreInputs,
        grants: EphemeralAllowOnceTable = EphemeralAllowOnceTable()
    ) async -> (enforce: EvaluationResult, observe: GatedVerdict) {
        let request = EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs)
        let enforceInputs = EvaluationInputs(guardMode: .enforce, judge: selection, store: store)
        let observeInputs = EvaluationInputs(guardMode: .observe, judge: selection, store: store)
        let enforce = await door.gated(
            .peek, request, cwd: cwd, home: home, grants: grants, now: now,
            allowlist: { allowlist }, host: .hook(.claude), tool: .bash, inputs: enforceInputs
        ).result
        let observe = await door.gated(
            .peek, request, cwd: cwd, home: home, grants: grants, now: now,
            allowlist: { allowlist }, host: .hook(.claude), tool: .bash,
            showsWouldBe: true, inputs: observeInputs
        )
        return (enforce, observe)
    }

    private static var commands: [String] {
        EquivalenceCorpus.engineCorpus().map(\.1) + EquivalenceCorpus.everydayCommands()
    }

    /// Every command through both doors; each would-be must be enforce's
    /// peek. Returns the enforce verdicts and the observed and overridden
    /// counts.
    private static func check(
        _ answer: Answer, door: GatedEvaluate, selection: JudgeSelection,
        home: HomeDirectory, cwd: WorkingDirectory, store: PolicyStoreInputs,
        grants: EphemeralAllowOnceTable = EphemeralAllowOnceTable()
    ) async -> (enforced: [String: EvaluationResult], observed: Int, overridden: Int) {
        var enforced: [String: EvaluationResult] = [:]
        var observed = 0
        var overridden = 0
        for command in commands {
            let (enforce, verdict) = await both(
                command, door: door, selection: selection, home: home, cwd: cwd, store: store, grants: grants)
            enforced[command] = enforce
            guard let wouldBe = verdict.wouldBe else {
                // The observe floor held: the enforce branch decided.
                continue
            }
            observed += 1
            if verdict.observeOverrode { overridden += 1 }
            #expect(verdict.result.decision == .allow, "\(answer) \(command)")
            #expect(wouldBe.result == enforce, "\(answer) \(command)")
            #expect(
                wouldBe.authorization == HookAuthorization.project(result: enforce, cwd: cwd),
                "\(answer) \(command)"
            )
        }
        return (enforced, observed, overridden)
    }

    @Test(arguments: Answer.allCases)
    func observeWouldBeIsEnforcePeek(_ answer: Answer) async throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let cwd = wd("/tmp/ws")
        let (door, selection) = try Self.door(answer)
        let store = PolicyStoreInputs.gather(home: home, cwd: cwd)
        let checked = await Self.check(answer, door: door, selection: selection, home: home, cwd: cwd, store: store)
        // The corpus is there, most of it observed, and enforce would have
        // refused a good share of it.
        #expect(Self.commands.count > 2_000)
        #expect(checked.observed > Self.commands.count / 2)
        #expect(checked.overridden > 100)
    }

    /// A live allow-once grant for every deny the Policy gate sees: the
    /// preview redeems it on both sides (a peek spends nothing), so the
    /// would-be follows enforce through the allow-once path too.
    @Test("observe would-be is the enforce peek with live allow-once grants")
    func observeWouldBeIsEnforcePeekWithGrants() async throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let cwd = wd("/tmp/ws")
        let (door, selection) = try Self.door(.allow)
        let store = PolicyStoreInputs.gather(home: home, cwd: cwd)
        let before = await Self.check(.allow, door: door, selection: selection, home: home, cwd: cwd, store: store)
        let grants = EphemeralAllowOnceTable()
        var planted = 0
        for command in Self.commands where planted < EphemeralAllowOnceTable.maxGrants {
            guard let denied = before.enforced[command], case .deny = denied.decision,
                  HookAuthorization.policyGateAccess(for: denied) != .skip else { continue }
            let shell = ShellCommand(rawValue: command)
            let result = await grants.plant(
                matchingView: denied.matchingView, cwd: cwd, codeHash: "parity", now: Self.now,
                maskedSegments: Normalize.maskedSegments(of: shell),
                invocationPrefix: Normalize.invocationPrefix(of: shell)
            )
            if result == .planted { planted += 1 }
        }
        #expect(await grants.hasLiveGrants(now: Self.now))
        let after = await Self.check(
            .allow, door: door, selection: selection, home: home, cwd: cwd, store: store, grants: grants)
        // Some deny enforce refused without a grant, the grant now lets through.
        let redeemed = Self.commands.filter { command in
            guard case .deny = before.enforced[command]?.decision else { return false }
            return after.enforced[command]?.decision == .allow
        }
        #expect(planted > 0)
        #expect(redeemed.count > 0)
    }
}

/// A judge that misses its budget: it hands back `late` and then delivers
/// its verdict through `onLateResult`, as a prediction that answered after
/// its caller gave up does (the late-result row is logged).
private struct LateJudge: JudgePort {
    let answer: JudgeRuntime.JudgeRun
    func judge(_ call: JudgeCall) -> JudgeRuntime.JudgeRun {
        call.onLateResult?(answer, .milliseconds(5))
        return .late
    }
}
