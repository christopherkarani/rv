import Testing
import RVDomain
@testable import RVEngine

/// A containment witness is a real command: its shell spelling, analyzed by
/// the same analyzers the hook runs, gives an action the candidate's typed
/// rules let through and the ceiling's restrict.
@Suite("PolicyContainmentWitness")
struct PolicyContainmentWitnessTests {
    private let repo = FilesystemAnalysisWorld.probed(
        FilesystemAnalysisContext(
            workingDirectory: WorkingDirectory(validating: "/repo"),
            repositoryRoot: RepositoryRoot(validating: "/repo")
        )
    )

    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var candidate: [TypedRule]
        var ceiling: [TypedRule]
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(
            name: "force push to main",
            candidate: [rule("allow-main", .allow, .gitPush(force: .any, branch: "main"))],
            ceiling: [rule("no-force", .deny, .gitPush(force: .exactly(.force), branch: nil))]
        ),
        Case(
            name: "push to a nested branch",
            candidate: [rule("allow-feature", .allow, .gitPush(force: .exactly(.none), branch: "feature/main"))],
            ceiling: [rule("no-main", .deny, .gitPush(force: .any, branch: "main"))]
        ),
        Case(
            name: "discard two pathspecs",
            candidate: [rule("allow-docs", .ask, .gitDiscardWorktree(pathspec: "docs"))],
            ceiling: [rule("no-src", .deny, .gitDiscardWorktree(pathspec: "src"))]
        ),
        Case(
            name: "hard reset",
            candidate: [rule("allow-reset", .allow, .gitReset(mode: nil))],
            ceiling: [rule("no-hard", .ask, .gitReset(mode: .hard))]
        ),
        Case(
            name: "clean with directories",
            candidate: [rule("allow-clean", .allow, .gitClean(force: true, directories: nil))],
            ceiling: [rule("no-clean-d", .deny, .gitClean(force: nil, directories: true))]
        ),
        Case(
            name: "recursive forced delete",
            candidate: [rule("allow-rm", .allow, .filesystemDelete(recursive: nil, force: true))],
            ceiling: [rule("no-rm-r", .deny, .filesystemDelete(recursive: true, force: nil))]
        ),
        Case(
            name: "move",
            candidate: [rule("allow-mv", .allow, .filesystemMove)],
            ceiling: [rule("no-mv", .deny, .filesystemMove)]
        ),
    ]

    @Test(arguments: cases)
    func witnessCommandReplaysThroughTheAnalyzerAndEvaluator(_ example: Case) throws {
        guard case .exceeds(let witness) = PolicyContainment.check(
            candidate: example.candidate, ceiling: example.ceiling)
        else {
            Issue.record("expected exceeds")
            return
        }
        let analysis = analyzeSemantics(ShellCommand(rawValue: witness.command), filesystemWorld: repo).innermost
        let action: SemanticAction
        switch analysis {
        case .git(let git): action = .git(git)
        case .filesystem(let filesystem): action = .filesystem(filesystem)
        default:
            Issue.record("\(witness.command) did not analyze to a typed action: \(analysis)")
            return
        }
        let ceilingVerdict = try #require(ActionPolicyEngine.typedRestriction(action, rules: example.ceiling))
        let candidateVerdict = ActionPolicyEngine.typedRestriction(action, rules: example.candidate)
        switch witness.ceilingVerdict {
        case .deny:
            guard case .hardDeny = ceilingVerdict.decision else {
                Issue.record("ceiling does not deny \(witness.command)")
                return
            }
            if case .hardDeny? = candidateVerdict?.decision {
                Issue.record("candidate denies \(witness.command) too")
            }
        case .ask:
            guard case .mandatoryHuman = ceilingVerdict.decision else {
                Issue.record("ceiling does not ask for \(witness.command)")
                return
            }
            #expect(candidateVerdict == nil)
        case .allow:
            Issue.record("a ceiling allow is never a bound")
        }
        #expect(example.candidate.contains { PolicyMatch.matches($0.predicate, action) }, "candidate must speak on it")
    }

    private static func rule(_ id: String, _ verdict: TypedRuleVerdict, _ predicate: PolicyPredicate) -> TypedRule {
        TypedRule(id: RuleID(pack: .typedGit, pattern: id), predicate: predicate, verdict: verdict, origin: .repo)
    }
}
