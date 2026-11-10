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
    policy: EffectiveActionPolicy = .empty
) -> EvaluationResult {
    let pack = evaluate(
        request,
        packs: packs,
        secretPaths: secretPaths,
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
    let result = applySemantics(
        pack: pack,
        analysis: analysis,
        command: request.command,
        gitWorld: gitWorld,
        filesystemWorld: filesystemWorld,
        enabledPacks: request.enabledPacks,
        policy: policy
    )
    return floorInstallPaths(result, command: request.command, home: secretPaths.home, cwd: workingDirectory)
}

/// An allowed command that writes, moves or removes rv's install
/// (`RVInstallPathGuard`) is indeterminate: stopping or replacing rvd is
/// the owner's job, in Terminal. Last, so no policy allow lowers it.
private func floorInstallPaths(
    _ result: EvaluationResult, command: ShellCommand, home: HomePath?, cwd: WorkingDirectory?
) -> EvaluationResult {
    guard result.decision == .allow, RVInstallPathGuard.touchesInstall(command, home: home, cwd: cwd) else {
        return result
    }
    return EvaluationResult(outcome: .indeterminate(.selfProtection), matchingView: result.matchingView)
}
