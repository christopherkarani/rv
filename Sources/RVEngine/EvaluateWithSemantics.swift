import RVDomain

/// The evaluation door: pack evaluate, then unwrap, analyze, and apply
/// semantic policy in one composition.
///
/// Pack deny / indeterminate is a floor — semantic stages can only tighten an
/// allow. Path / cwd / repo I/O stays outside the Engine: callers inject
/// filesystem facts through `filesystemProbe`, which the door calls once with
/// the unwrapped outcome. The Policy gate is downstream of this door, never
/// inside it.
public func evaluateWithSemantics<E: PatternEngine>(
    _ request: EvaluationRequest,
    packs: [PackSnapshot],
    secrets: SecretPathCatalog = .dayOne,
    safety: SafetyLevel = .normal,
    allowPaths: SecretAllowPathSet = .empty,
    home: String? = nil,
    patterns: E,
    compiled: CompiledPacks<E.Compiled>,
    gitContext: GitAnalysisContext = .empty,
    filesystemProbe: (UnwrapOutcome) -> FilesystemAnalysisContext = { _ in .empty },
    policy: EffectiveActionPolicy = .empty
) -> EvaluationResult {
    let pack = evaluate(
        request,
        packs: packs,
        secrets: secrets,
        safety: safety,
        allowPaths: allowPaths,
        home: home,
        patterns: patterns,
        compiled: compiled
    )
    let unwrapped = unwrapCommand(
        request.command,
        workingDirectory: gitContext.workingDirectory
    )
    let filesystemContext = filesystemProbe(unwrapped)
    let analysis = analyzeSemantics(
        unwrapped: unwrapped,
        gitContext: gitContext,
        filesystemContext: filesystemContext
    )
    return applySemantics(
        pack: pack,
        analysis: analysis,
        command: request.command,
        gitContext: gitContext,
        filesystemContext: filesystemContext,
        enabledPacks: request.enabledPacks,
        policy: policy
    )
}
