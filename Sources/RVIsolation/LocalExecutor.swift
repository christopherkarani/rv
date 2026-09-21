import RVDomain

public enum LocalExecutorError: Error, Sendable, Equatable {
    case alreadyExecuted(ActionFingerprint)
    case applyFailed(IsolationApplyError)
}

/// Runs a compiled `ExecutableAction` once per fingerprint.
///
/// Spawn is only `IsolationBackends.apply`. Observed and mediated plans
/// fail closed here so this door cannot start an unsandboxed process.
public actor LocalExecutor {
    private var executed: Set<ActionFingerprint> = []

    public init() {}

    public func run(_ executable: ExecutableAction) throws -> IsolatedRunResult {
        let fingerprint = executable.allowed.action.fingerprint
        if executed.contains(fingerprint) {
            throw LocalExecutorError.alreadyExecuted(fingerprint)
        }
        switch executable.plan.mode {
        case .observed, .mediated:
            throw LocalExecutorError.applyFailed(.backendUnavailable)
        case .contained:
            break
        }
        switch IsolationBackends.apply(executable.plan, command: executable.command) {
        case .success(let result):
            executed.insert(fingerprint)
            return result
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
        plan: IsolationPlan,
        approval: Result<ApprovalDecision, AgentApprovalError>? = nil
    ) -> Result<AgentTurn, AgentTurnError> {
        switch authorization {
        case .allowed(let allowed):
            return compileAndRun(allowed: allowed, plan: plan)
        case .denied(let denied):
            return .success(.denied(denied))
        case .pending(let pending):
            guard let approval else {
                return .success(.awaitingApproval(pending))
            }
            switch AgentAuthorization.resolve(pending, approval: approval) {
            case .failure(let error):
                return .failure(.approval(error))
            case .success(.denied(let denied)):
                return .success(.denied(denied))
            case .success(.allowed(let allowed)):
                return compileAndRun(allowed: allowed, plan: plan)
            }
        }
    }

    private func compileAndRun(
        allowed: AllowedAction,
        plan: IsolationPlan
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
