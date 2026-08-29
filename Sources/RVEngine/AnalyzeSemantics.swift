import RVDomain

/// Unwrap supported wrappers, then run the existing Git / filesystem analyzers
/// on the inner command. Does not invent a second policy engine.
public func analyzeSemantics(
    _ command: ShellCommand,
    gitContext: GitAnalysisContext = .empty,
    filesystemContext: FilesystemAnalysisContext = .empty,
    maxDepth: Int = UnwrapLimits.maxDepth,
    maxBytes: Int = UnwrapLimits.maxBytes
) -> SemanticAnalysis {
    let startCwd = gitContext.workingDirectory ?? filesystemContext.workingDirectory
    switch unwrapCommand(
        command,
        workingDirectory: startCwd,
        maxDepth: maxDepth,
        maxBytes: maxBytes
    ) {
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
            context: FilesystemAnalysisContext(
                workingDirectory: unwrapped.workingDirectory ?? filesystemContext.workingDirectory,
                repositoryRoot: filesystemContext.repositoryRoot,
                homeDirectory: filesystemContext.homeDirectory,
                catalog: filesystemContext.catalog,
                facts: filesystemContext.facts
            )
        )
        return filesystem.wrapping(unwrapped.layers)
    }
}
