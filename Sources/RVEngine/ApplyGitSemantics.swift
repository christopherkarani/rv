import RVDomain

/// Attach Git analysis and apply semantic policy without weakening a pack deny.
///
/// Pack deny / indeterminate is a floor. When `core.git` is enabled, a parsed
/// high-impact action may still deny if packs allow. Disabled / empty git
/// packs skip the builtin wall so pack selection stays the product switch.
/// Saved typed git rules still apply. Unknown syntax keeps the pack verdict.
public func applyGitSemantics(
    pack: EvaluationResult,
    command: ShellCommand,
    context: GitAnalysisWorld = .unprobed,
    enabledPacks: [PackID] = dayOnePackIDs,
    policy: EffectiveActionPolicy = .empty
) -> EvaluationResult {
    applyGitSemantics(
        pack: pack,
        analysis: analyzeSemantics(command, gitWorld: context, filesystemWorld: .unprobed),
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
    context: GitAnalysisWorld = .unprobed,
    enabledPacks: [PackID] = dayOnePackIDs,
    policy: EffectiveActionPolicy = .empty
) -> EvaluationResult {
    if let floored = pack.packFloor(attaching: analysis) {
        return floored
    }

    var result = pack
    result.analysis = analysis

    // Step 8B §24: on a chain, evaluate the shared analysis action
    // first (it may carry an unwrapped wrapper verdict), then every
    // parsed git segment; the first deny wins, so a benign prefix cannot
    // hide a risky later segment. The attached analysis stays the
    // whole-command analysis.
    let view = Normalize.matchingView(of: command.rawValue).rawValue
    let gitContext = gitAnalysisContext(context)
    if splitSegments(view).count > 1 {
        if let action = analysis.gitAction,
            let denied = gitSegmentResult(
                action: action,
                pack: pack,
                analysis: analysis,
                command: command,
                gitContext: gitContext,
                world: context,
                enabledPacks: enabledPacks,
                policy: policy
            )
        {
            return denied
        }
        for action in parseGitSegments(view, context: gitContext) {
            if let denied = gitSegmentResult(
                action: action,
                pack: pack,
                analysis: analysis,
                command: command,
                gitContext: gitContext,
                world: context,
                enabledPacks: enabledPacks,
                policy: policy
            ) {
                return denied
            }
        }
        return result
    }

    guard let action = analysis.gitAction else {
        return result
    }

    return gitSegmentResult(
        action: action,
        pack: pack,
        analysis: analysis,
        command: command,
        gitContext: gitContext,
        world: context,
        enabledPacks: enabledPacks,
        policy: policy
    ) ?? result
}

/// Evaluates one git action exactly as the single-command path. Nil means
/// the pack verdict stands; non-nil is a deny to return.
private func gitSegmentResult(
    action: GitAction,
    pack: EvaluationResult,
    analysis: SemanticAnalysis,
    command: ShellCommand,
    gitContext: GitAnalysisContext,
    world: GitAnalysisWorld,
    enabledPacks: [PackID],
    policy: EffectiveActionPolicy
) -> EvaluationResult? {
    let verdict: ActionPolicyVerdict
    if enabledPacks.contains(.coreGit) {
        verdict = ActionPolicyEngine.evaluate(
            action: action.proposedAction(
                command: command,
                workingDirectory: gitContext.workingDirectory
            ),
            context: gitContext.reviewContext,
            policy: policy,
            gitWorld: world
        )
    } else if let typed = ActionPolicyEngine.typedRestriction(
        .git(action),
        rules: policy.rules
    ) {
        verdict = typed
    } else {
        return nil
    }
    let bound = HostNativeAsk.hookBound(verdict.decision)
    switch bound {
    case .allow:
        return nil
    case .deny(let deny), .mandatoryHuman(let deny):
        return EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: pack.matchingView,
            analysis: analysis,
            boundReview: bound
        )
    }
}

private func gitAnalysisContext(_ world: GitAnalysisWorld) -> GitAnalysisContext {
    switch world {
    case .unprobed:
        return .empty
    case .probed(let context):
        return context
    }
}
