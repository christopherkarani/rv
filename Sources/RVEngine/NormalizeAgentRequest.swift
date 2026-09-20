import RVDomain

/// Describes a validated process request as a `ProposedAction`.
///
/// Calls `analyzeSemantics` only. Does not evaluate packs, bind policy, or
/// authorize. The result is a proposal, not a permit.
public func normalizeAgentRequest(
    _ request: AgentRequest,
    gitWorld: GitAnalysisWorld = .unprobed,
    filesystemWorld: FilesystemAnalysisWorld = .unprobed
) -> Result<ProposedAction, AgentNormalizationError> {
    switch request {
    case .process(let process):
        let analysis = analyzeSemantics(
            process.command,
            gitWorld: gitWorld,
            filesystemWorld: filesystemWorld
        )
        return ProposedAction.process(
            host: process.host,
            session: process.session,
            cwd: process.workingDirectory,
            command: process.command,
            analysis: analysis
        )
    }
}
