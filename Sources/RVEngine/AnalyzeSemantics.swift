import RVDomain

/// Unwrap supported wrappers, then run the existing Git / filesystem analyzers
/// on the inner command. Does not invent a second policy engine.
public func analyzeSemantics(
    _ command: ShellCommand,
    gitContext: GitAnalysisContext = .empty,
    filesystemWorld: FilesystemAnalysisWorld = .unprobed,
    maxDepth: Int = UnwrapLimits.maxDepth,
    maxBytes: Int = UnwrapLimits.maxBytes
) -> SemanticAnalysis {
    let startCwd = gitContext.workingDirectory ?? filesystemWorkingDirectory(filesystemWorld)
    return analyzeSemantics(
        unwrapped: unwrapCommand(
            command,
            workingDirectory: startCwd,
            maxDepth: maxDepth,
            maxBytes: maxBytes
        ),
        gitContext: gitContext,
        filesystemWorld: filesystemWorld
    )
}

/// Same analyzers as the command entry, when the caller already unwrapped once
/// (Evaluate door live probe).
public func analyzeSemantics(
    unwrapped: UnwrapOutcome,
    gitContext: GitAnalysisContext = .empty,
    filesystemWorld: FilesystemAnalysisWorld = .unprobed
) -> SemanticAnalysis {
    switch unwrapped {
    case .limited(let layers):
        return SemanticAnalysis.unwrapLimited.wrapping(layers)
    case .complete(let unwrapped):
        let git = analyzeGit(
            unwrapped.command,
            context: GitAnalysisContext(
                workingDirectory: unwrapped.workingDirectory ?? gitContext.workingDirectory,
                currentBranch: gitContext.currentBranch,
                isSharedBranch: gitContext.isSharedBranch
            )
        )
        if case .git = git {
            return git.wrapping(unwrapped.layers)
        }
        let filesystem = analyzeFilesystem(
            unwrapped.command,
            context: filesystemContext(
                world: filesystemWorld,
                workingDirectory: unwrapped.workingDirectory
            )
        )
        return filesystem.wrapping(unwrapped.layers)
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

private func filesystemContext(
    world: FilesystemAnalysisWorld,
    workingDirectory: WorkingDirectory?
) -> FilesystemAnalysisContext {
    switch world {
    case .unprobed:
        return .empty
    case .probed(let context):
        return FilesystemAnalysisContext(
            workingDirectory: workingDirectory ?? context.workingDirectory,
            repositoryRoot: context.repositoryRoot,
            homeDirectory: context.homeDirectory,
            catalog: context.catalog,
            facts: context.facts
        )
    }
}
