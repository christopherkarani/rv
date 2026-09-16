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
    filesystemWorld: FilesystemAnalysisWorld = .unprobed,
    enabledPacks: [PackID] = dayOnePackIDs,
    policy: EffectiveActionPolicy = .empty
) -> EvaluationResult {
    applyFilesystemSemantics(
        pack: pack,
        analysis: analyzeFilesystem(command, context: filesystemAnalysisContext(filesystemWorld)),
        command: command,
        filesystemWorld: filesystemWorld,
        enabledPacks: enabledPacks,
        policy: policy
    )
}

public func applyFilesystemSemantics(
    pack: EvaluationResult,
    analysis: SemanticAnalysis,
    command: ShellCommand,
    filesystemWorld: FilesystemAnalysisWorld = .unprobed,
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

    guard let action = analysis.filesystemAction else {
        return result
    }

    let verdict: ActionPolicyVerdict
    if enabledPacks.contains(.coreFilesystem) {
        verdict = ActionPolicyEngine.evaluate(
            action: action.proposedAction(
                command: command,
                workingDirectory: filesystemWorkingDirectory(filesystemWorld)
            ),
            context: ReviewContext(repository: RepositoryReviewContext()),
            policy: policy
        )
    } else if let typed = ActionPolicyEngine.typedRestriction(
        .filesystem(action),
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
        if case .unprobed = filesystemWorld,
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
private func filesystemAnalysisContext(_ world: FilesystemAnalysisWorld) -> FilesystemAnalysisContext {
    switch world {
    case .unprobed:
        return .empty
    case .probed(let context):
        return context
    }
}

private func filesystemWorkingDirectory(_ world: FilesystemAnalysisWorld) -> WorkingDirectory? {
    switch world {
    case .unprobed:
        return nil
    case .probed(let context):
        return context.workingDirectory
    }
}

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
