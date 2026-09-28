import RVDomain

/// Deprecated host-spawn door. Launch through `IsolationBackends.apply` or
/// the persistent workspace host instead. Kept for one release so external
/// `RVIsolation` library consumers keep compiling; then removed.
@available(*, deprecated, message: "Launch through IsolationBackends.apply or the persistent workspace host.")
public enum HostLaunchError: Error, Sendable, Equatable {
    case hostUnsupported
    case apply(IsolationApplyError)
}

/// RV-owned host spawn door. Not `LocalExecutor.perform`.
/// Observed and mediated plans cannot be passed here.
@available(*, deprecated, message: "Launch through IsolationBackends.apply or the persistent workspace host.")
public func launchContainedHost(
    host: HookHost,
    command: IsolatedCommand,
    plan: ContainedPlan,
    admission: RuntimeAdmissionConfiguration = .failClosed
) -> Result<IsolatedRunResult, HostLaunchError> {
    switch host {
    case .opencode:
        break
    case .grok, .pi, .claude, .openclaw, .hermes, .codex, .cursor:
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
@available(*, deprecated, message: "Launch through IsolationBackends.applyOffPool or the persistent workspace host.")
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
