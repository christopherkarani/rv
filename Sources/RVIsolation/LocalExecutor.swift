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
}
