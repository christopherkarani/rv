import RVDomain

public enum HostLaunchError: Error, Sendable, Equatable {
    case hostUnsupported
    case apply(IsolationApplyError)
}

/// RV-owned host spawn door. Not `LocalExecutor.perform`.
/// Observed and mediated plans cannot be passed here.
public func launchContainedHost(
    host: HookHost,
    command: IsolatedCommand,
    plan isolation: ContainedIsolation,
    admission: RuntimeAdmissionConfiguration = .failClosed
) -> Result<IsolatedRunResult, HostLaunchError> {
    switch host {
    case .opencode:
        break
    case .grok, .pi, .claude, .openclaw, .hermes, .codex, .cursor:
        return .failure(.hostUnsupported)
    }
    switch IsolationBackends.applyLaunch(
        isolation.plan,
        command: command,
        io: .inherit,
        host: host,
        sessionStore: .production,
        admission: admission
    ) {
    case .success(let result):
        return .success(result)
    case .failure(let error):
        return .failure(.apply(error))
    }
}
