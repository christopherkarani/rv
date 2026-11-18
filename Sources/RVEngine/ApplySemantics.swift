import RVDomain

/// Compose an already-analyzed unwrap with Git / filesystem semantic policy.
///
/// Pack deny / indeterminate is a floor. Limit / unreliable unwrap never
/// becomes an auto-allow. Product callers go through `evaluateWithSemantics`
/// rather than re-analyzing here.
public func applySemantics(
    pack: EvaluationResult,
    analysis: SemanticAnalysis,
    command: ShellCommand,
    gitWorld: GitAnalysisWorld = .unprobed,
    filesystemWorld: FilesystemAnalysisWorld = .unprobed,
    enabledPacks: [PackID] = dayOnePackIDs,
    policy: EffectiveActionPolicy = .empty
) -> EvaluationResult {
    if let floored = pack.packFloor(attaching: analysis) {
        return floored
    }
    let limited = applyUnwrapLimit(pack: pack, analysis: analysis)
    let afterGit = applyGitSemantics(
        pack: limited,
        analysis: analysis,
        command: command,
        context: gitWorld,
        enabledPacks: enabledPacks,
        policy: policy
    )
    let afterFilesystem = applyFilesystemSemantics(
        pack: afterGit,
        analysis: analysis,
        command: command,
        filesystemWorld: filesystemWorld,
        enabledPacks: enabledPacks,
        policy: policy
    )
    // Host MCP config writes the filesystem parser cannot see
    // (`mcpHostConfigUnmodeledWrite`), only while the guard is on.
    guard case .allow = afterFilesystem.decision, case .probed(let context) = filesystemWorld,
          let guarded = context.mcpHostConfigGuard,
          mcpHostConfigUnmodeledWrite(command.rawValue, guard: guarded, context: context)
    else { return afterFilesystem }
    return mcpHostConfigDeny(pack: afterFilesystem, analysis: analysis)
}

extension EvaluationResult {
    /// Pack deny / indeterminate is a floor: semantic stages attach `analysis`
    /// but never rewrite the outcome. `nil` means the pack allowed and
    /// semantic policy may tighten.
    func packFloor(attaching analysis: SemanticAnalysis) -> EvaluationResult? {
        switch decision {
        case .deny, .indeterminate:
            var result = self
            result.analysis = analysis
            return result
        case .allow:
            return nil
        }
    }
}

/// Fail-closed deny when unwrap hit a depth / size / parse limit.
public func applyUnwrapLimit(
    pack: EvaluationResult,
    analysis: SemanticAnalysis
) -> EvaluationResult {
    if let floored = pack.packFloor(attaching: analysis) {
        return floored
    }
    var result = pack
    result.analysis = analysis
    guard case .unwrapLimited = analysis.innermost else {
        return result
    }
    return EvaluationResult(
        outcome: .deny(ActionPolicyEngine.Builtin.unwrapLimited, matched: nil),
        matchingView: pack.matchingView,
        analysis: analysis
    )
}
