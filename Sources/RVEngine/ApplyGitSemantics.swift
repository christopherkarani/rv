import RVDomain

/// Attach Git analysis and apply semantic policy without weakening a pack deny.
///
/// Pack deny / indeterminate is a floor. When `core.git` is enabled, a parsed
/// high-impact action may still deny if packs allow. Disabled / empty git
/// packs skip the builtin wall so pack selection stays the product switch.
/// Saved typed gitPush rules still apply. Unknown syntax keeps the pack verdict.
public func applyGitSemantics(
    pack: EvaluationResult,
    command: ShellCommand,
    context: GitAnalysisContext = .empty,
    enabledPacks: [PackID] = dayOnePackIDs,
    policy: EffectiveActionPolicy = .empty
) -> EvaluationResult {
    applyGitSemantics(
        pack: pack,
        analysis: analyzeGit(command, context: context),
        command: command,
        context: context,
        enabledPacks: enabledPacks,
        policy: policy
    )
}

public func applyGitSemantics(
    pack: EvaluationResult,
    analysis: SemanticAnalysis,
    command: ShellCommand,
    context: GitAnalysisContext = .empty,
    enabledPacks: [PackID] = dayOnePackIDs,
    policy: EffectiveActionPolicy = .empty
) -> EvaluationResult {
    if let floored = pack.packFloor(attaching: analysis) {
        return floored
    }

    var result = pack
    result.analysis = analysis

    guard let action = analysis.gitAction else {
        return result
    }

    let verdict: ActionPolicyVerdict
    if enabledPacks.contains(.coreGit) {
        verdict = ActionPolicyEngine.evaluate(
            action: action.proposedAction(
                command: command,
                workingDirectory: context.workingDirectory
            ),
            context: context.reviewContext,
            policy: policy,
            gitAction: action
        )
    } else if let typed = ActionPolicyEngine.typedRestriction(
        gitAction: action,
        rules: policy.rules
    ) {
        verdict = typed
    } else {
        return result
    }
    switch verdict.decision {
    case .hardAllow, .reviewEligible:
        return result
    case .hardDeny(let deny):
        return EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: pack.matchingView,
            analysis: analysis,
            boundReview: .deny(deny)
        )
    case .mandatoryHuman(let deny):
        return EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: pack.matchingView,
            analysis: analysis,
            boundReview: .mandatoryHuman(deny)
        )
    }
}
