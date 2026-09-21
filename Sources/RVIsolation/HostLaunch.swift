import RVDomain

public enum HostLaunchError: Error, Sendable, Equatable {
    case hostUnsupported
    case planNotContained
    case apply(IsolationApplyError)
}

/// RV-owned host spawn door. Not `LocalExecutor.perform`.
public func launchContainedHost(
    host: HookHost,
    command: IsolatedCommand,
    plan: IsolationPlan
) -> Result<IsolatedRunResult, HostLaunchError> {
    switch host {
    case .opencode:
        break
    case .grok, .pi, .claude, .openclaw, .hermes, .codex, .cursor:
        return .failure(.hostUnsupported)
    }
    switch plan.mode {
    case .observed, .mediated:
        return .failure(.planNotContained)
    case .contained:
        switch IsolationBackends.apply(plan, command: command, io: .inherit) {
        case .success(let result):
            return .success(result)
        case .failure(let error):
            return .failure(.apply(error))
        }
    }
}
