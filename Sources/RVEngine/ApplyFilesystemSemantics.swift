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
    enabledPacks: [PackID] = dayOnePackIDs
) -> EvaluationResult {
    applyFilesystemSemantics(
        pack: pack,
        analysis: analyzeFilesystem(command, context: context),
        command: command,
        context: context,
        enabledPacks: enabledPacks
    )
}

public func applyFilesystemSemantics(
    pack: EvaluationResult,
    analysis: SemanticAnalysis,
    command: ShellCommand,
    context: FilesystemAnalysisContext = .empty,
    enabledPacks: [PackID] = dayOnePackIDs
) -> EvaluationResult {
    if pack.analysis.gitAction != nil {
        return pack
    }

    var result = pack
    result.analysis = analysis

    switch pack.decision {
    case .deny, .indeterminate:
        return result
    case .allow:
        break
    }

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
