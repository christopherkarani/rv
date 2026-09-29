import RVDomain

/// Outcome of one already-decided authorization. Ask is a wait, not an error.
///
/// Executor-internal: only `LocalExecutor` produces turns. Interactive
/// commands attach to the workspace host through `WorkspaceClient`.
enum AgentTurn: Sendable, Equatable {
    case executed(IsolatedRunResult)
    case awaitingApproval(PendingAuthorization)
    case denied(DeniedAction)
}

/// Failures while dispatching a turn. Pending without approval is not this type.
enum AgentTurnError: Error, Sendable, Equatable {
    case approval(AgentApprovalError)
    case compile(ExecutableCompileError)
    case execute(LocalExecutorError)
}
