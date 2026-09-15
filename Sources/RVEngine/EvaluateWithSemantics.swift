import RVDomain

/// The evaluation door: pack evaluate, then unwrap, analyze, and apply
/// semantic policy in one composition.
///
/// Pack deny / indeterminate is a floor — semantic stages can only tighten an
/// allow. Path / cwd / repo I/O stays outside the Engine: callers inject
/// filesystem facts through `filesystemProbe`, and git facts through
/// `gitProbe`, each called once with the unwrapped outcome. Defaults are
/// unprobed. The Policy gate is downstream of this door, never inside it.
public func evaluateWithSemantics<E: PatternEngine>(
    _ request: EvaluationRequest,
    packs: [PackSnapshot],
    secrets: SecretPathCatalog = .dayOne,
    safety: SafetyLevel = .normal,
    allowPaths: SecretAllowPathSet = .empty,
    home: String? = nil,
    engine: E,
    compiled: CompiledPacks<E.Compiled>,
    workingDirectory: WorkingDirectory? = nil,
    gitProbe: (UnwrapOutcome) -> GitAnalysisWorld = { _ in .unprobed },
    filesystemProbe: (UnwrapOutcome) -> FilesystemAnalysisWorld = { _ in .unprobed },
    policy: EffectiveActionPolicy = .empty
) -> EvaluationResult {
    let pack = evaluate(
        request,
        packs: packs,
        secrets: secrets,
        safety: safety,
        allowPaths: allowPaths,
        home: home,
        engine: engine,
        compiled: compiled
    )
    let unwrapped = unwrapCommand(
        request.command,
        workingDirectory: workingDirectory
    )
    let gitWorld = gitProbe(unwrapped)
    let filesystemWorld = filesystemProbe(unwrapped)
    let analysis = analyzeSemantics(
        unwrapped: unwrapped,
        gitWorld: gitWorld,
        filesystemWorld: filesystemWorld
    )
    return applySemantics(
        pack: pack,
        analysis: analysis,
        command: request.command,
        gitWorld: gitWorld,
        filesystemWorld: filesystemWorld,
        enabledPacks: request.enabledPacks,
        policy: policy
    )
}
