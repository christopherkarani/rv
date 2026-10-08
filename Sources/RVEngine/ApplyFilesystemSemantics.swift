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
        analysis: analyzeSemantics(command, gitWorld: .unprobed, filesystemWorld: filesystemWorld),
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
    // Single-segment git claims skip filesystem policy (the command was
    // fully classified as git) — except their shell-side redirects, which
    // the git claim must not shadow: `git stash list > /tmp/x` writes
    // outside the repository (A-F2). Chains always fall through: a git
    // segment must not shadow a filesystem risk in a later segment (§24).
    let chainView = Normalize.matchingView(of: command.rawValue).rawValue
    if splitSegments(chainView).count < 2, pack.analysis.gitAction != nil {
        return gitClaimRedirectResult(
            pack: pack,
            analysis: analysis,
            command: command,
            view: chainView,
            filesystemWorld: filesystemWorld,
            enabledPacks: enabledPacks,
            policy: policy
        )
    }

    if let floored = pack.packFloor(attaching: analysis) {
        return floored
    }

    var result = pack
    result.analysis = analysis

    // Step 8B §24: on a chain, evaluate the shared analysis action
    // first (it may carry an unwrapped wrapper verdict), then every
    // parsed filesystem segment; the first deny wins, so a benign prefix
    // cannot hide a risky later segment. The attached analysis stays the
    // whole-command analysis.
    let view = chainView
    if splitSegments(view).count > 1 {
        if let action = analysis.filesystemAction,
            let denied = filesystemSegmentResult(
                action: action,
                pack: pack,
                analysis: analysis,
                command: command,
                filesystemWorld: filesystemWorld,
                enabledPacks: enabledPacks,
                policy: policy
            )
        {
            return denied
        }
        let segmentContext: FilesystemAnalysisContext
        switch filesystemWorld {
        case .unprobed:
            segmentContext = .empty
        case .probed(let probed):
            segmentContext = probed
        }
        // M-24: values the matcher rewrote excuse their own bare segments.
        let assignmentValues = ShellPipeline.collectTopLevelAssignmentValues(
            ShellPipeline.peelStage(command.rawValue)
        )
        for action in parseFilesystemSegments(view, context: segmentContext, assignmentValues: assignmentValues) {
            if let denied = filesystemSegmentResult(
                action: action,
                pack: pack,
                analysis: analysis,
                command: command,
                filesystemWorld: filesystemWorld,
                enabledPacks: enabledPacks,
                policy: policy
            ) {
                return denied
            }
        }
        return result
    }

    guard let action = analysis.filesystemAction else {
        return result
    }

    return filesystemSegmentResult(
        action: action,
        pack: pack,
        analysis: analysis,
        command: command,
        filesystemWorld: filesystemWorld,
        enabledPacks: enabledPacks,
        policy: policy
    ) ?? result
}

/// Evaluates shell-side redirects under a single-segment git claim. The git
/// action itself is evaluated by the git stage; here only redirect writes
/// can deny. The segment head is `git` whenever the claim comes from this
/// command, so the filesystem parse takes the redirect-only path and git
/// verbs never misparse as filesystem verbs. No redirects (or nothing
/// parsed) returns `pack` untouched, exactly like the legacy skip; a pack
/// floor still wins first, exactly like chains. Dynamic segments stay
/// pack-covered.
private func gitClaimRedirectResult(
    pack: EvaluationResult,
    analysis: SemanticAnalysis,
    command: ShellCommand,
    view: String,
    filesystemWorld: FilesystemAnalysisWorld,
    enabledPacks: [PackID],
    policy: EffectiveActionPolicy
) -> EvaluationResult {
    if let floored = pack.packFloor(attaching: analysis) {
        return floored
    }
    let segmentContext: FilesystemAnalysisContext
    switch filesystemWorld {
    case .unprobed:
        segmentContext = .empty
    case .probed(let probed):
        segmentContext = probed
    }
    // M-24: values the matcher rewrote excuse their own bare segments.
    let assignmentValues = ShellPipeline.collectTopLevelAssignmentValues(
        ShellPipeline.peelStage(command.rawValue)
    )
    for action in parseFilesystemSegments(view, context: segmentContext, assignmentValues: assignmentValues) {
        if let denied = filesystemSegmentResult(
            action: action,
            pack: pack,
            analysis: analysis,
            command: command,
            filesystemWorld: filesystemWorld,
            enabledPacks: enabledPacks,
            policy: policy
        ) {
            return denied
        }
    }
    return pack
}

/// Evaluates one filesystem action exactly as the single-command path. Nil
/// means the pack verdict stands; non-nil is a deny to return.
private func filesystemSegmentResult(
    action: FilesystemAction,
    pack: EvaluationResult,
    analysis: SemanticAnalysis,
    command: ShellCommand,
    filesystemWorld: FilesystemAnalysisWorld,
    enabledPacks: [PackID],
    policy: EffectiveActionPolicy
) -> EvaluationResult? {
    let verdict: ActionPolicyVerdict
    if enabledPacks.contains(.coreFilesystem) {
        verdict = ActionPolicyEngine.evaluate(
            action: action.proposedAction(
                command: command,
                workingDirectory: filesystemWorkingDirectory(filesystemWorld)
            ),
            context: ReviewContext(repository: RepositoryReviewContext()),
            policy: policy,
            gitWorld: .unprobed
        )
    } else if let typed = ActionPolicyEngine.typedRestriction(
        .filesystem(action),
        rules: policy.rules
    ) {
        verdict = typed
    } else {
        return nil
    }
    switch verdict.decision {
    case .hardAllow, .reviewEligible:
        return nil
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
            return nil
        }
        return filesystemSemanticDeny(deny, pack: pack, analysis: analysis)
    case .mandatoryHuman(let deny):
        return filesystemBound(
            HostNativeAsk.hookBound(.mandatoryHuman(deny)),
            pack: pack,
            analysis: analysis
        )
    }
}

private func filesystemSemanticDeny(
    _ deny: Deny,
    pack: EvaluationResult,
    analysis: SemanticAnalysis
) -> EvaluationResult {
    filesystemBound(
        HostNativeAsk.hookBound(.hardDeny(deny)),
        pack: pack,
        analysis: analysis
    )
}

private func filesystemBound(
    _ bound: BoundReview,
    pack: EvaluationResult,
    analysis: SemanticAnalysis
) -> EvaluationResult {
    switch bound {
    case .allow:
        return pack
    case .deny(let deny), .mandatoryHuman(let deny):
        return EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: pack.matchingView,
            analysis: analysis,
            boundReview: bound
        )
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
