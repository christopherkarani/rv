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
    secretPaths: SecretPathDecider = .dayOne,
    engine: E,
    compiled: CompiledPacks<E.Compiled>,
    workingDirectory: WorkingDirectory? = nil,
    gitProbe: (UnwrapOutcome) -> GitAnalysisWorld = { _ in .unprobed },
    filesystemProbe: (UnwrapOutcome) -> FilesystemAnalysisWorld = { _ in .unprobed },
    policy: EffectiveActionPolicy = .empty,
    patternBudget: PatternBudget = PatternBudget()
) -> EvaluationResult {
    var budget = patternBudget
    func judge(_ request: EvaluationRequest) -> EvaluationResult {
        evaluateSemanticsOnce(
            request,
            packs: packs,
            secretPaths: secretPaths,
            engine: engine,
            compiled: compiled,
            workingDirectory: workingDirectory,
            gitProbe: gitProbe,
            filesystemProbe: filesystemProbe,
            policy: policy,
            patternBudget: &budget
        )
    }
    // An alias body is judged by the same door: `git -c alias.p=push p`
    // is a remote push only the semantic stage can see.
    return gateAliases(judge(request), command: request.command, packs: packs, enabledPacks: request.enabledPacks) { expansion in
        var inner = request
        inner.command = expansion
        return judge(inner)
    }
}

private func evaluateSemanticsOnce<E: PatternEngine>(
    _ request: EvaluationRequest,
    packs: [PackSnapshot],
    secretPaths: SecretPathDecider,
    engine: E,
    compiled: CompiledPacks<E.Compiled>,
    workingDirectory: WorkingDirectory?,
    gitProbe: (UnwrapOutcome) -> GitAnalysisWorld,
    filesystemProbe: (UnwrapOutcome) -> FilesystemAnalysisWorld,
    policy: EffectiveActionPolicy,
    patternBudget: inout PatternBudget
) -> EvaluationResult {
    // The unresolved-invocation ask waits for the door's own gate, so a
    // semantic deny below still wins over it.
    let pack = evaluateGated(
        request,
        packs: packs,
        secretPaths: secretPaths,
        engine: engine,
        compiled: compiled,
        patternBudget: &patternBudget,
        floorUnresolved: false
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
