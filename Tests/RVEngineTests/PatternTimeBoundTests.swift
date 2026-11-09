import Foundation
import Testing
import RVDomain
@testable import RVEngine

/// ICU backtracking is bounded: a search that cannot finish by its deadline
/// is `.exhausted`, and the gate turns that into indeterminate, never allow.
@Suite("Pattern time bound")
struct PatternTimeBoundTests {
    /// Exponential on a near-miss subject; never finishes unbounded.
    private let catastrophic = #"(a+)+$"#
    private let nearMiss = String(repeating: "a", count: 40) + "b"

    @Test func icuSearch_pastDeadline_isExhausted() throws {
        let engine = ICUPatternEngine()
        let compiled = try engine.compile(catastrophic)
        let started = ContinuousClock.now
        let result = engine.search(compiled, in: nearMiss, deadline: started + .milliseconds(100))
        #expect(result == .exhausted)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func icuSearch_withinDeadline_matchesLikeFirstMatch() throws {
        let engine = ICUPatternEngine()
        let compiled = try engine.compile(#"git\s+reset\s+--hard"#)
        let text = "cd x && git reset --hard"
        guard case .match(let range) = engine.search(compiled, in: text, deadline: .now + .seconds(1)) else {
            Issue.record("expected a match")
            return
        }
        #expect(range == engine.firstMatch(compiled, in: text))
        #expect(engine.search(compiled, in: "git status", deadline: .now + .seconds(1)) == .noMatch)
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

    private func evaluateWithSinglePack(
        safe: [String],
        destructive: [String],
        command: String
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
            compiled: compiled
        )
    }
}
