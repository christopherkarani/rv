import RVDomain

/// Attach filesystem analysis and apply semantic policy without weakening a pack deny.
///
/// Pack deny / indeterminate is a floor. When `core.filesystem` is enabled, a
/// parsed protected-path mutation may still deny if packs allow. Disabled /
/// empty filesystem packs skip that extra deny so pack selection stays the
/// product switch. Unknown syntax keeps the pack verdict.
public func applyFilesystemSemantics(
    pack: EvaluationResult,
    command: ShellCommand,
    context: FilesystemAnalysisContext = .empty,
    enabledPacks: [PackID] = dayOnePackIDs,
    policy: EffectiveActionPolicy = .empty
) -> EvaluationResult {
    applyFilesystemSemantics(
        pack: pack,
        analysis: analyzeFilesystem(command, context: context),
        command: command,
        context: context,
        enabledPacks: enabledPacks,
        policy: policy
    )
}

public func applyFilesystemSemantics(
    pack: EvaluationResult,
    analysis: SemanticAnalysis,
    command: ShellCommand,
    context: FilesystemAnalysisContext = .empty,
    enabledPacks: [PackID] = dayOnePackIDs,
    policy: EffectiveActionPolicy = .empty
) -> EvaluationResult {
    if pack.analysis.gitAction != nil {
        return pack
    }

    if let floored = pack.packFloor(attaching: analysis) {
        return floored
    }

    var result = pack
    result.analysis = analysis

    guard enabledPacks.contains(.coreFilesystem) else {
        return result
    }

    guard let action = analysis.filesystemAction else {
        return result
    }

    let verdict = ActionPolicyEngine.evaluate(
        action: action.proposedAction(
            command: command,
            workingDirectory: context.workingDirectory
        ),
        context: ReviewContext(repository: RepositoryReviewContext()),
        policy: policy
    )
    switch verdict.decision {
    case .hardAllow, .reviewEligible:
        return result
    case .hardDeny(let deny):
        if context.probe == .unprobed,
            deny.ruleID == ActionPolicyEngine.Builtin.unresolvedFilesystem.ruleID
        {
            // ActionPolicyEngine ranks unresolved first. Unprobed worlds skip
            // that tighten, but catalog / out-of-repo hits on other targets
            // must still deny.
            if let boundary = catalogOrBoundaryDeny(for: action) {
                return filesystemSemanticDeny(
                    boundary,
                    pack: pack,
                    analysis: analysis
                )
            }
            return result
        }
        return filesystemSemanticDeny(deny, pack: pack, analysis: analysis)
    case .mandatoryHuman(let deny):
        return EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: pack.matchingView,
            analysis: analysis,
            boundReview: .mandatoryHuman(deny)
        )
    }
}

private func filesystemSemanticDeny(
    _ deny: Deny,
    pack: EvaluationResult,
    analysis: SemanticAnalysis
) -> EvaluationResult {
    EvaluationResult(
        outcome: .deny(deny, matched: nil),
        matchingView: pack.matchingView,
        analysis: analysis,
        boundReview: .deny(deny)
    )
}

/// Protected-path and out-of-repo still tighten when unprobed. Unresolved
/// must not mask those hits on a mixed-target command.
private func catalogOrBoundaryDeny(for action: FilesystemAction) -> Deny? {
    let kinds = action.effects.kinds
    if kinds.contains(.protectedPathMutation) {
        return ActionPolicyEngine.Builtin.protectedPath
    }
    if kinds.contains(.outsideRepositoryMutation) {
        return ActionPolicyEngine.Builtin.outsideRepository
    }
    return nil
}
