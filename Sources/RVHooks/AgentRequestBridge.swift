import RVDomain

/// Maps an already-decoded hook request to a runtime `AgentRequest`.
///
/// `.shell` reuses typed validate. `.file` and `.spend` are unrepresentable.
/// Does not parse host JSON.
public func agentRequest(
    from request: HookRequest
) -> Result<AgentRequest, AgentRequestValidationError> {
    switch request {
    case .shell(let host, let command, let cwd, let session):
        return AgentRequest.validate(
            host: host,
            command: command,
            workingDirectory: cwd,
            session: session
        )
    case .file, .spend:
        return .failure(.unsupportedKind)
    }
}
