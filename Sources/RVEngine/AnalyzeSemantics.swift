import RVDomain

/// Unwrap supported wrappers, then run the existing Git / filesystem analyzers
/// on the inner command. Does not invent a second policy engine.
public func analyzeSemantics(
    _ command: ShellCommand,
    gitWorld: GitAnalysisWorld = .unprobed,
    filesystemWorld: FilesystemAnalysisWorld = .unprobed,
    maxDepth: Int = UnwrapLimits.maxDepth,
    maxBytes: Int = UnwrapLimits.maxBytes
) -> SemanticAnalysis {
    let startCwd = gitWorkingDirectory(gitWorld) ?? filesystemWorkingDirectory(filesystemWorld)
    return analyzeSemantics(
        unwrapped: unwrapCommand(
            command,
            workingDirectory: startCwd,
            maxDepth: maxDepth,
            maxBytes: maxBytes
        ),
        gitWorld: gitWorld,
        filesystemWorld: filesystemWorld
    )
}

/// Same analyzers as the command entry, when the caller already unwrapped once
/// (Evaluate door live probe).
public func analyzeSemantics(
    unwrapped: UnwrapOutcome,
    gitWorld: GitAnalysisWorld = .unprobed,
    filesystemWorld: FilesystemAnalysisWorld = .unprobed
) -> SemanticAnalysis {
    switch unwrapped {
    case .limited(let layers):
        return SemanticAnalysis.unwrapLimited.wrapping(layers)
    case .complete(let unwrapped):
        let git = analyzeGit(
            unwrapped.command,
            context: gitAnalysisContext(
                world: gitWorld,
                workingDirectory: unwrapped.workingDirectory
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

private func gitWorkingDirectory(_ world: GitAnalysisWorld) -> WorkingDirectory? {
    switch world {
    case .unprobed:
        return nil
    case .probed(let context):
        return context.workingDirectory
    }
}

private func gitAnalysisContext(
    world: GitAnalysisWorld,
    workingDirectory: WorkingDirectory?
) -> GitAnalysisContext {
    switch world {
    case .unprobed:
        return GitAnalysisContext(workingDirectory: workingDirectory)
    case .probed(let context):
        return GitAnalysisContext(
            workingDirectory: workingDirectory ?? context.workingDirectory,
            currentBranch: context.currentBranch,
            isSharedBranch: context.isSharedBranch
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

private func filesystemContext(
    world: FilesystemAnalysisWorld,
    workingDirectory: WorkingDirectory?
) -> FilesystemAnalysisContext {
    switch world {
    case .unprobed:
        // Unwrap cwd is command text (`env -C`), not a live probe.
        guard let workingDirectory else {
            return .empty
        }
        return FilesystemAnalysisContext(workingDirectory: workingDirectory)
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
