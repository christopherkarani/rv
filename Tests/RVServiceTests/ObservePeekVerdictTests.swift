import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVService

/// `peekVerdict` carries, under observe, the verdict enforce would show,
/// so `rv test` / `rv explain` can render it (the door still allows).
@Suite("Observe peek verdict")
struct ObservePeekVerdictTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func peek(_ command: String, home: HomeDirectory) async -> GatedVerdict {
        await GatedEvaluate().peekVerdict(
            command: ShellCommand(rawValue: command), cwd: nil, home: home,
            grants: EphemeralAllowOnceTable(), now: now,
            allowlist: { AllowlistSnapshot(entries: []) }
        )
    }

    @Test("observe: the door allows and the would-be deny keeps its rule")
    func observeCarriesWouldBeDeny() async throws {
        let home = try guardHome(mode: "observe")
        defer { remove(home) }
        let verdict = await Self.peek("git reset --hard", home: home)
        #expect(verdict.result.decision == .allow)
        #expect(verdict.result.outcome == .plain)
        guard case .deny(let deny, let matched)? = verdict.observedWouldBe?.outcome else {
            Issue.record("expected a would-be deny, got \(String(describing: verdict.observedWouldBe))")
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
        #expect(verdict.observedWouldBe?.decision == .allow)
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
        #expect(verdict.observedWouldBe == nil)
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
        #expect(verdict.observedWouldBe == nil)
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
}
