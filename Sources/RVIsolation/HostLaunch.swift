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
    plan: ContainedPlan,
    admission: RuntimeAdmissionConfiguration = .failClosed
) -> Result<IsolatedRunResult, HostLaunchError> {
    switch host {
    case .opencode:
        break
    case .grok, .pi, .claude, .openclaw, .hermes, .codex, .cursor, .antigravity:
        return .failure(.hostUnsupported)
    }
    switch IsolationBackends.applyLaunch(
        plan.isolationPlan(),
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

/// Same door as `launchContainedHost`, off the cooperative pool.
public func launchContainedHostOffPool(
    host: HookHost,
    command: IsolatedCommand,
    plan: ContainedPlan,
    admission: RuntimeAdmissionConfiguration = .failClosed
) async -> Result<IsolatedRunResult, HostLaunchError> {
    await IsolationBlockingWork.perform {
        launchContainedHost(host: host, command: command, plan: plan, admission: admission)
    }
}
