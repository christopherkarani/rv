import Foundation
import RVDomain
import RVEngine
import RVPolicy

/// The person's own typed rules that also match an explained command.
///
/// A pack deny is a floor: the engine returns it before typed rules run, so
/// explain named only the pack, and a repo rule such as
/// `typed.git:force-push-main` never appeared. This reads the same layers
/// evaluation reads (machine, then `<cwd>/.rv`) and lists each matching rule
/// the verdict did not already name. Read-only; it never changes a verdict.
enum ExplainTypedRules {
    static func lines(
        result: EvaluationResult,
        command: ShellCommand,
        cwd: WorkingDirectory?,
        home: HomeDirectory?
    ) -> [String] {
        let workspace = cwd.map { URL(fileURLWithPath: $0.rawValue, isDirectory: true) }
        guard let rules = try? PolicyWorkspace(home: home, workspace: workspace).loadEffectiveRules(builtin: []),
            rules.isEmpty == false
        else { return [] }
        let action = action(result.analysis)
            ?? action(analyzeSemantics(command, gitWorld: .unprobed, filesystemWorld: .unprobed))
        return lines(rules: rules, action: action, decidedBy: result.outcome.explainRuleID)
    }

    /// Pure core: the rules matching `action`, less the one that decided.
    static func lines(rules: [TypedRule], action: SemanticAction?, decidedBy: RuleID?) -> [String] {
        guard let action else { return [] }
        return rules
            .filter { $0.id != decidedBy && PolicyMatch.matches($0.predicate, action) }
            .map { rule in
                var line = "  Your rule  \(DisplayedText.field(rule.id.rawValue)) · \(origin(rule.origin)) · "
                    + "\(rule.verdict.rawValue) · also matches"
                if rule.verdict == .allow {
                    line += " (allow is restrict-only: it never lets through what rv or a pack stops)"
                }
                return line
            }
    }

    private static func action(_ analysis: SemanticAnalysis) -> SemanticAction? {
        if let git = analysis.gitAction { return .git(git) }
        if let filesystem = analysis.filesystemAction { return .filesystem(filesystem) }
        return nil
    }

    private static func origin(_ origin: TypedRuleOrigin) -> String {
        switch origin {
        case .builtin: return "built-in"
        case .machine: return "this machine (~/.config/rv/policy.toml)"
        case .repo: return "this repo (.rv/policy.toml)"
        }
    }
}
