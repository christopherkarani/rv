import Foundation
import RVDomain
import RVEngine
import RVPolicy
import RVPresentation

/// Typed rules that also match an explained command.
///
/// A pack deny is a floor: the engine returns it before typed rules run, so
/// explain named only the pack, and a repo rule such as
/// `typed.git:force-push-main` never appeared. This reads the same layers
/// evaluation reads (machine, `<cwd>/.rv`, then the owner's ceiling) and
/// lists each matching rule the verdict did not already name. Read-only; it
/// never changes a verdict.
enum ExplainTypedRules {
    static func matches(
        result: EvaluationResult,
        command: ShellCommand,
        cwd: WorkingDirectory?,
        home: HomeDirectory?
    ) -> [ExplainAlsoMatch] {
        let workspace = cwd.map { URL(fileURLWithPath: $0.rawValue, isDirectory: true) }
        let policy = PolicyWorkspace(home: home, workspace: workspace)
        guard let layers = try? policy.loadLayers() else { return [] }
        let ceiling = (try? policy.loadCeiling())?.typedRules ?? []
        let rules = layers.machine.map { ($0, ExplainAlsoMatch.Source.machine) }
            + layers.repo.map { ($0, .repo) }
            + ceiling.map { ($0, .ceiling) }
        guard rules.isEmpty == false else { return [] }
        let action = action(result.analysis)
            ?? action(analyzeSemantics(command, gitWorld: .unprobed, filesystemWorld: .unprobed))
        return matches(rules: rules, action: action, decidedBy: result.outcome.explainRuleID)
    }

    /// Pure core: the rules matching `action`, less the one that decided.
    static func matches(
        rules: [(TypedRule, ExplainAlsoMatch.Source)], action: SemanticAction?, decidedBy: RuleID?
    ) -> [ExplainAlsoMatch] {
        guard let action else { return [] }
        return rules
            .filter { $0.0.id != decidedBy && PolicyMatch.matches($0.0.predicate, action) }
            .map { ExplainAlsoMatch(ruleID: $0.0.id, source: $0.1, verdict: $0.0.verdict) }
    }

    private static func action(_ analysis: SemanticAnalysis) -> SemanticAction? {
        if let git = analysis.gitAction { return .git(git) }
        if let filesystem = analysis.filesystemAction { return .filesystem(filesystem) }
        return nil
    }
}
