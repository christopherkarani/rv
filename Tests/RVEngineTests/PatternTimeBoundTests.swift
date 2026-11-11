import Foundation
import Testing
import RVDomain
@testable import RVEngine

/// ICU backtracking is bounded by one CPU-time budget per request: a search
/// past its own cap or the request's total is `.exhausted`. Exhaustion never
/// allows, never skips the remaining deny rules, and never downgrades a deny.
@Suite("Pattern time bound")
struct PatternTimeBoundTests {
    /// Exponential on a near-miss subject; never finishes unbounded.
    private let catastrophic = #"(a+)+$"#
    private let nearMiss = String(repeating: "a", count: 40) + "b"

    @Test func icuSearch_pastPerSearchCap_isExhausted() throws {
        let engine = ICUPatternEngine()
        let compiled = try engine.compile(catastrophic)
        var budget = PatternBudget(perSearchCPU: .milliseconds(50))
        let started = ContinuousClock.now
        #expect(engine.search(compiled, in: nearMiss, budget: &budget) == .exhausted)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func icuSearch_spentBudget_isExhaustedWithoutSearching() throws {
        let engine = ICUPatternEngine()
        let compiled = try engine.compile(#"git\s+status"#)
        var budget = PatternBudget(totalCPU: .zero)
        #expect(budget.isSpent)
        #expect(engine.search(compiled, in: "git status", budget: &budget) == .exhausted)
    }

    @Test func icuSearch_withinBudget_matchesLikeFirstMatch() throws {
        let engine = ICUPatternEngine()
        let compiled = try engine.compile(#"git\s+reset\s+--hard"#)
        let text = "cd x && git reset --hard"
        var budget = PatternBudget()
        guard case .match(let range) = engine.search(compiled, in: text, budget: &budget) else {
            Issue.record("expected a match")
            return
        }
        #expect(range == engine.firstMatch(compiled, in: text))
        #expect(engine.search(compiled, in: "git status", budget: &budget) == .noMatch)
    }

    @Test func budget_isSharedAcrossSearches() throws {
        let engine = ICUPatternEngine()
        let compiled = try engine.compile(catastrophic)
        var budget = PatternBudget(totalCPU: .milliseconds(60), perSearchCPU: .milliseconds(40))
        _ = engine.search(compiled, in: nearMiss, budget: &budget)
        _ = engine.search(compiled, in: nearMiss, budget: &budget)
        #expect(budget.isSpent)
    }

    @Test func evaluate_catastrophicDestructivePattern_isIndeterminateNotAllow() throws {
        let result = try evaluateWithSinglePack(
            safe: [], destructive: [catastrophic], command: "rm " + nearMiss)
        #expect(result.decision == .indeterminate(.budgetExhausted))
    }

    @Test func evaluate_catastrophicSafePattern_neverVouches() throws {
        let result = try evaluateWithSinglePack(
            safe: [#"rm\s+(a+)+$"#], destructive: [#"rm\s+-rf"#], command: "rm " + nearMiss)
        #expect(result.decision == .indeterminate(.budgetExhausted))
    }

    @Test func evaluate_exhaustedSafePattern_stillDenies() throws {
        let result = try evaluateWithSinglePack(
            safe: [#"rm\s+(a+)+$"#], destructive: [#"rm\s+a"#], command: "rm " + nearMiss)
        #expect(deniedRule(result) == "core.filesystem:rule-0")
    }

    @Test func evaluate_exhaustedEarlierDestructiveRule_laterRuleStillDenies() throws {
        let result = try evaluateWithSinglePack(
            safe: [], destructive: [catastrophic, #"rm\s+a"#], command: "rm " + nearMiss)
        #expect(deniedRule(result) == "core.filesystem:rule-1")
    }

    @Test func evaluate_exhaustionInSegmentPass_laterSegmentStillDenies() throws {
        let result = try evaluateWithSinglePack(
            safe: [], destructive: [catastrophic], command: "rm \(nearMiss); git reset --hard")
        #expect(deniedRule(result) == "core.git:reset-hard")
    }

    /// rvd passes the hook client's deadline: past it no search starts, so
    /// an abandoned evaluation stops early and cannot end in an allow.
    @Test func hardDeadline_pullsTheWallCeilingIn() throws {
        #expect(PatternBudget(hardDeadline: .now - .seconds(1)).isSpent)
        #expect(PatternBudget(hardDeadline: .now + .seconds(60)).isSpent == false)
        let engine = ICUPatternEngine()
        let compiled = try engine.compile(catastrophic)
        var budget = PatternBudget(perSearchCPU: .seconds(30), hardDeadline: .now + .milliseconds(50))
        let started = ContinuousClock.now
        #expect(engine.search(compiled, in: nearMiss, budget: &budget) == .exhausted)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func evaluate_pastHardDeadline_isNotAllow() throws {
        let result = try evaluateWithSinglePack(
            safe: [], destructive: [#"rm\s+-rf"#], command: "rm a",
            budget: PatternBudget(hardDeadline: .now - .seconds(1)))
        #expect(result.decision == .indeterminate(.budgetExhausted))
    }

    private func deniedRule(_ result: EvaluationResult) -> String? {
        guard case .deny(let deny) = result.decision else { return nil }
        return deny.ruleID.rawValue
    }

    private func evaluateWithSinglePack(
        safe: [String],
        destructive: [String],
        command: String,
        budget: PatternBudget = PatternBudget(perSearchCPU: .milliseconds(50))
    ) throws -> EvaluationResult {
        var packs = [PackSnapshot(
            id: .coreGit,
            name: "git",
            description: "git",
            keywords: ["git"],
            safe: [],
            destructive: [DestructiveRule(name: "reset-hard", pattern: #"git\s+reset\s+--hard"#, severity: .critical, reason: "g")]
        )]
        packs.append(PackSnapshot(
            id: .coreFilesystem,
            name: "fs",
            description: "fs",
            keywords: ["rm"],
            safe: safe.enumerated().map { NamedPattern(name: "safe-\($0.offset)", pattern: $0.element) },
            destructive: destructive.enumerated().map {
                DestructiveRule(name: "rule-\($0.offset)", pattern: $0.element, severity: .high, reason: "r")
            } + [DestructiveRule(name: "fork-bomb", pattern: "(?!)", severity: .critical, reason: "f")]
        ))
        let engine = ICUPatternEngine()
        let compiled = try CompiledPacks<ICUCompiledPattern>.compile(packs: packs, using: engine)
        return evaluate(
            EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: [.coreFilesystem, .coreGit]),
            packs: packs,
            engine: engine,
            compiled: compiled,
            patternBudget: budget
        )
    }
}
