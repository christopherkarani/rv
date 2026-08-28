import RVDomain

/// Attach Git analysis and apply semantic policy without weakening a pack deny.
///
/// Pack deny / indeterminate is a floor. When `core.git` is enabled, a parsed
/// high-impact action may still deny if packs allow. Disabled / empty git
/// packs skip that extra deny so pack selection stays the product switch.
/// Unknown syntax keeps the pack verdict.
public func applyGitSemantics(
    pack: EvaluationResult,
    command: ShellCommand,
    context: GitAnalysisContext = .empty,
    enabledPacks: [PackID] = dayOnePackIDs
) -> EvaluationResult {
    applyGitSemantics(
        pack: pack,
        analysis: analyzeGit(command, context: context),
        command: command,
        context: context,
        enabledPacks: enabledPacks
    )
}

public func applyGitSemantics(
    pack: EvaluationResult,
    analysis: SemanticAnalysis,
    command: ShellCommand,
    context: GitAnalysisContext = .empty,
    enabledPacks: [PackID] = dayOnePackIDs
) -> EvaluationResult {
    var result = pack
    result.analysis = analysis

    switch pack.decision {
    case .deny, .indeterminate:
        return result
    case .allow:
        break
    }

    guard enabledPacks.contains(.coreGit) else {
        return result
    }

    guard case .git(let action) = analysis else {
        return result
    }

    let verdict = ActionPolicyEngine.evaluate(
        action: action.proposedAction(
            command: command,
            workingDirectory: context.workingDirectory
        ),
        context: context.reviewContext,
        policy: .empty
    )
    switch verdict.decision {
    case .hardAllow, .reviewEligible:
        return result
    case .hardDeny(let deny), .mandatoryHuman(let deny):
        return EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: pack.matchingView,
            analysis: analysis
        )
    }
}
