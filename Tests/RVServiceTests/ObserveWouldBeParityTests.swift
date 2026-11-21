import Foundation
import Testing
import RVDomain
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
/// allows, blocks, is unavailable (the packs-only floor), or has no bundle.
@Suite("Observe would-be is the enforce peek")
struct ObserveWouldBeParityTests {
    enum Answer: String, CaseIterable, Sendable {
        case allow, block, unavailable, noBundle
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
        }
        let selection = JudgeSelection(engine: .ft, bundle: answer == .noBundle ? nil : bundle)
        return (GatedEvaluate(EvaluateSession(), judge: EffectFixedJudge(run: run)), selection)
    }

    /// The enforce peek and the observe would-be for one command.
    private static func both(
        _ command: String, door: GatedEvaluate, selection: JudgeSelection,
        home: HomeDirectory, cwd: WorkingDirectory, store: PolicyStoreInputs
    ) async -> (enforce: EvaluationResult, observe: GatedVerdict) {
        let request = EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs)
        let enforceInputs = EvaluationInputs(guardMode: .enforce, judge: selection, store: store)
        let observeInputs = EvaluationInputs(guardMode: .observe, judge: selection, store: store)
        let enforce = await door.gated(
            .peek, request, cwd: cwd, home: home, grants: EphemeralAllowOnceTable(), now: now,
            allowlist: { allowlist }, host: .hook(.claude), tool: .bash, inputs: enforceInputs
        )
        let observe = await door.gatedVerdict(
            .peek, request, cwd: cwd, home: home, grants: EphemeralAllowOnceTable(), now: now,
            allowlist: { allowlist }, host: .hook(.claude), tool: .bash,
            previewsWouldBe: true, inputs: observeInputs
        )
        return (enforce, observe)
    }

    @Test(arguments: Answer.allCases)
    func observeWouldBeIsEnforcePeek(_ answer: Answer) async throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let cwd = wd("/tmp/ws")
        let (door, selection) = try Self.door(answer)
        let store = PolicyStoreInputs.gather(home: home, cwd: cwd)
        let commands = EquivalenceCorpus.engineCorpus().map(\.1) + EquivalenceCorpus.everydayCommands()
        var observed = 0
        var overridden = 0
        for command in commands {
            let (enforce, verdict) = await Self.both(
                command, door: door, selection: selection, home: home, cwd: cwd, store: store)
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
        // The corpus is there, most of it observed, and enforce would have
        // refused a good share of it.
        #expect(commands.count > 2_000)
        #expect(observed > commands.count / 2)
        #expect(overridden > 100)
    }
}
