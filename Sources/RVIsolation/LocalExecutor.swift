import RVDomain

public enum LocalExecutorError: Error, Sendable, Equatable {
    case cancelled
    case alreadyExecuted(ActionFingerprint)
    case applyFailed(IsolationApplyError)
}

/// Dispatches a compiled `ExecutableAction` at most once per fingerprint.
///
/// Spawn is only `IsolationBackends.apply` of `executable.isolation.plan`.
/// Observed and mediated plans are not representable on this door.
public actor LocalExecutor {
    private var dispatched: Set<ActionFingerprint> = []

    public init() {}

    public func run(_ executable: ExecutableAction) throws -> IsolatedRunResult {
        guard Task.isCancelled == false else {
            throw LocalExecutorError.cancelled
        }
        let fingerprint = executable.allowed.action.fingerprint
        if dispatched.contains(fingerprint) {
            throw LocalExecutorError.alreadyExecuted(fingerprint)
        }
        // Apply can fail after the child has produced effects. Never make the
        // same authorization reusable based on an ambiguous backend result.
        dispatched.insert(fingerprint)
        switch IsolationBackends.apply(executable.isolation.plan, command: executable.command) {
        case .success(let result):
            return result
        case .failure(.cancelled):
            throw LocalExecutorError.cancelled
        case .failure(let error):
            throw LocalExecutorError.applyFailed(error)
        }
    }

    /// Dispatches an already-decided authorization. Does not call `decide`.
    ///
    /// Allowed compiles and runs. Denied returns without spawn. Pending
    /// without approval waits. Pending with approval goes through `resolve`
    /// before compile + run.
    public func perform(
        _ authorization: AgentAuthorization,
        plan isolation: ContainedIsolation,
        approval: Result<ApprovalDecision, AgentApprovalError>? = nil
    ) -> Result<AgentTurn, AgentTurnError> {
        switch AgentAuthorization.step(authorization, approval: approval) {
        case .execute(let allowed):
            return compileAndRun(allowed: allowed, isolation: isolation)
        case .denied(let denied):
            return .success(.denied(denied))
        case .awaitingApproval(let pending):
            return .success(.awaitingApproval(pending))
        case .approvalFailed(let error):
            return .failure(.approval(error))
        }
    }

    private func compileAndRun(
        allowed: AllowedAction,
        isolation: ContainedIsolation
    ) -> Result<AgentTurn, AgentTurnError> {
        switch compileExecutable(allowed: allowed, isolation: isolation) {
        case .failure(let error):
            return .failure(.compile(error))
        case .success(let executable):
            do {
                return .success(.executed(try run(executable)))
            } catch let error as LocalExecutorError {
                return .failure(.execute(error))
            } catch {
                preconditionFailure("LocalExecutor.run throws only LocalExecutorError")
            }
        }
    }
}
