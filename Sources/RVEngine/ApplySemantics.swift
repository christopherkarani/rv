import RVDomain

/// Compose wrapper unwrap with Git / filesystem semantic policy.
///
/// Pack deny / indeterminate is a floor. Limit / unreliable unwrap never
/// becomes an auto-allow.
public func applySemantics(
    pack: EvaluationResult,
    command: ShellCommand,
    gitContext: GitAnalysisContext = .empty,
    filesystemContext: FilesystemAnalysisContext = .empty,
    enabledPacks: [PackID] = dayOnePackIDs,
    maxDepth: Int = UnwrapLimits.maxDepth,
    maxBytes: Int = UnwrapLimits.maxBytes,
    policy: EffectiveActionPolicy = .empty
) -> EvaluationResult {
    let analysis = analyzeSemantics(
        command,
        gitContext: gitContext,
        filesystemContext: filesystemContext,
        maxDepth: maxDepth,
        maxBytes: maxBytes
    )
    return applySemantics(
        pack: pack,
        analysis: analysis,
        command: command,
        gitContext: gitContext,
        filesystemContext: filesystemContext,
        enabledPacks: enabledPacks,
        policy: policy
    )
}

public func applySemantics(
    pack: EvaluationResult,
    analysis: SemanticAnalysis,
    command: ShellCommand,
    gitContext: GitAnalysisContext = .empty,
    filesystemContext: FilesystemAnalysisContext = .empty,
    enabledPacks: [PackID] = dayOnePackIDs,
    policy: EffectiveActionPolicy = .empty
) -> EvaluationResult {
    let limited = applyUnwrapLimit(pack: pack, analysis: analysis)
    let afterGit = applyGitSemantics(
        pack: limited,
        analysis: analysis,
        command: command,
        context: gitContext,
        enabledPacks: enabledPacks,
        policy: policy
    )
    return applyFilesystemSemantics(
        pack: afterGit,
        analysis: analysis,
        command: command,
        context: filesystemContext,
        enabledPacks: enabledPacks,
        policy: policy
    )
}

/// Fail-closed deny when unwrap hit a depth / size / parse limit.
public func applyUnwrapLimit(
    pack: EvaluationResult,
    analysis: SemanticAnalysis
) -> EvaluationResult {
    var result = pack
    result.analysis = analysis
    switch pack.decision {
    case .deny, .indeterminate:
        return result
    case .allow:
        break
    }
    guard case .unwrapLimited = analysis.innermost else {
        return result
    }
    return EvaluationResult(
        outcome: .deny(ActionPolicyEngine.Builtin.unwrapLimited, matched: nil),
        matchingView: pack.matchingView,
        analysis: analysis
    )
}
