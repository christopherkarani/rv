import RVDomain

/// Balanced-profile allowance for deleting regenerable workspace output.
///
/// `CodingAgentBalanced` (SafetyLevel.normal) auto-allows `rm -rf` iff every
/// victim is positively proven to be generated output inside the repository.
/// Anything else — source, unknown kind, outside/unknown scope, uncertain
/// resolution, wrappers, composition, globs — keeps the pack deny.
///
/// Positive proof only: parser failure, missing analysis, and unprobed
/// worlds all fail closed by construction (no override).
public enum ContainedReversibleDelete {
    /// Pack rules this override may lift. Root/home rm, find-delete,
    /// unlink, and every other destructive pattern are never overridden.
    public static let overridablePatterns: Set<String> = [
        "rm-rf-general",
        "rm-r-f-separate",
        "rm-recursive-force-long",
    ]

    /// Shell metacharacters that can widen the victim set past the probed
    /// apparent path (glob expansion, brace expansion). `$` and backtick
    /// never reach here: the analyzer rejects dynamic tokens as unknown.
    private static let wideningCharacters: Set<Character> = ["*", "?", "[", "]", "{", "}"]

    /// True iff `result` is an overridable pack rm deny over a pure,
    /// fully-contained generated-output delete.
    public static func permits(_ result: EvaluationResult) -> Bool {
        guard case .deny(let deny, _) = result.outcome else { return false }
        guard deny.ruleID.pack == .coreFilesystem else { return false }
        guard overridablePatterns.contains(deny.ruleID.pattern) else { return false }
        // Semantic hard binds are never overridden by profile.
        if case .deny = result.boundReview { return false }
        let analysis = result.analysis
        guard analysis.wrappers.isEmpty else { return false }
        guard case .filesystem(.delete(let targets, recursive: true, force: true)) =
            analysis.innermost
        else {
            return false
        }
        guard targets.isEmpty == false else { return false }
        return targets.allSatisfy(isContainedGeneratedVictim)
    }

    private static func isContainedGeneratedVictim(_ target: FilesystemTarget) -> Bool {
        guard target.scope == .insideRepository else { return false }
        guard target.kind == .generatedOutput else { return false }
        guard target.resolution != .uncertain else { return false }
        guard target.apparent.contains(where: wideningCharacters.contains) == false else {
            return false
        }
        return true
    }
}
