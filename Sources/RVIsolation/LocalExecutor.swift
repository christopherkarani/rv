import RVDomain

public enum LocalExecutorError: Error, Sendable, Equatable {
    case cancelled
    case alreadyExecuted(ActionFingerprint)
    case applyFailed(IsolationApplyError)
}

/// Dispatches a compiled `ExecutableAction` at most once per fingerprint.
///
/// Spawn is only `IsolationBackends.apply`. The contained plan is converted
/// to `IsolationPlan` at that call.
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
        switch IsolationBackends.apply(executable.plan.isolationPlan(), command: executable.command) {
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
    /// without approval waits. Pending with approval goes through `step`,
    /// which maps the ledger click through `humanDecision` before `resolve`.
    public func perform(
        _ authorization: AgentAuthorization,
        plan: ContainedPlan,
        approval: Result<ApprovalDecision, AgentApprovalError>? = nil
    ) -> Result<AgentTurn, AgentTurnError> {
        switch AgentAuthorization.step(authorization, approval: approval) {
        case .execute(let allowed):
            return compileAndRun(allowed: allowed, plan: plan)
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
        plan: ContainedPlan
    ) -> Result<AgentTurn, AgentTurnError> {
        switch compileExecutable(allowed: allowed, plan: plan) {
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
