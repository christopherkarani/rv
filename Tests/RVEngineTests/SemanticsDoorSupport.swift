import RVDomain
@testable import RVEngine

func runSemanticsPack(_ command: String) throws -> EvaluationResult {
    let world = try semanticsSampleWorld()
    return evaluate(
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
        packs: world.packs,
        engine: world.engine,
        compiled: world.compiled
    )
}

func runSemanticsDoor(
    _ command: String,
    gitProbe: (UnwrapOutcome) -> GitAnalysisWorld = { _ in .unprobed },
    filesystemProbe: (UnwrapOutcome) -> FilesystemAnalysisWorld = { _ in .unprobed },
    policy: EffectiveActionPolicy = .empty
) throws -> EvaluationResult {
    let world = try semanticsSampleWorld()
    return evaluateWithSemantics(
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
        packs: world.packs,
        engine: world.engine,
        compiled: world.compiled,
        gitProbe: gitProbe,
        filesystemProbe: filesystemProbe,
        policy: policy
    )
}

func semanticsSampleWorld() throws -> (
    packs: [PackSnapshot],
    engine: ICUPatternEngine,
    compiled: CompiledPacks<ICUCompiledPattern>
) {
    let packs = [
        PackSnapshot(
            id: .coreFilesystem,
            name: "fs",
            description: "fs",
            keywords: ["rm"],
            safe: [],
            destructive: [
                DestructiveRule(
                    name: "rm-rf-general",
                    pattern: #"rm\s+-rf"#,
                    severity: .high,
                    reason: "rm -rf is destructive"
                ),
            ]
        ),
        PackSnapshot(
            id: .coreGit,
            name: "git",
            description: "git",
            keywords: ["git"],
            safe: [NamedPattern(name: "checkout-new-branch", pattern: #"git\s+checkout\s+-b\s+"#)],
            destructive: [
                DestructiveRule(
                    name: "reset-hard",
                    pattern: #"git\s+reset\s+--hard"#,
                    severity: .critical,
                    reason: "git reset --hard destroys uncommitted changes"
                ),
            ]
        ),
    ]
    let engine = ICUPatternEngine()
    let compiled = try CompiledPacks<ICUCompiledPattern>.compile(packs: packs, using: engine)
    return (packs, engine, compiled)
}
