import Foundation
import RVDomain

extension IsolationBackends {
    /// Landlock backend. `run` applies via `rv-isolation-exec` on Linux.
    /// Darwin `run` is `backendUnavailable` (prepare may still succeed).
    /// `executable` is a test seam: an absolute existing trampoline, or
    /// fail closed without searching.
    public static func landlock(executable: URL? = nil) -> IsolationBackend {
        IsolationBackend(
            family: .landlock,
            prepare: prepareLandlock,
            run: { request in
                runLandlock(request, executable: executable)
            }
        )
    }
}

func prepareLandlock(
    _ plan: IsolationPlan,
    _ command: IsolatedCommand
) -> Result<IsolatedLaunchRequest, IsolationApplyError> {
    switch plan.mode {
    case .observed, .mediated:
        return .failure(.profileNotApplicable)
    case .contained:
        switch compileLandlockRuleset(plan) {
        case .failure(let error):
            return .failure(error)
        case .success(let ruleset):
            guard let workspace = plan.workspace else {
                return .failure(.containedGuaranteesUnsupported)
            }
            switch existingResolvedWorkspacePath(workspace) {
            case .failure(let error):
                return .failure(error)
            case .success:
                break
            }
            guard
                let request = IsolatedLaunchRequest(
                    plan: plan,
                    command: command,
                    launch: .landlock(ruleset)
                )
            else {
                return .failure(.containedGuaranteesUnsupported)
            }
            return .success(request)
        }
    }
}

func runLandlock(
    _ request: IsolatedLaunchRequest,
    executable: URL?
) -> Result<IsolatedRunResult, IsolationApplyError> {
    guard request.family == .landlock else {
        return .failure(.backendMismatch)
    }
    #if os(Linux)
    guard let path = resolvedIsolationExecPath(override: executable) else {
        return .failure(.backendUnavailable)
    }
    return spawn(request, executablePath: path)
    #else
    return .failure(.backendUnavailable)
    #endif
}

/// Exit 125 means the trampoline did not exec the inner command.
func interpretIsolationExecExit(
    _ status: Int32,
    established: EstablishedIsolation
) -> Result<IsolatedRunResult, IsolationApplyError> {
    if status == IsolationBackends.isolationExecCouldNotEstablishExit {
        return .failure(.backendUnavailable)
    }
    return .success(IsolatedRunResult(established: established, exitStatus: status))
}

/// Locate `rv-isolation-exec`. Never a relative guess.
/// Override (test seam) that is not an absolute executable fails closed.
func resolvedIsolationExecPath(override: URL?) -> String? {
    if let override {
        return usableIsolationExecPath(override.path)
    }
    if let env = ProcessInfo.processInfo.environment["RV_ISOLATION_EXEC"],
        let path = usableIsolationExecPath(env)
    {
        return path
    }
    if let argv0 = CommandLine.arguments.first {
        let sibling = URL(fileURLWithPath: argv0)
            .deletingLastPathComponent()
            .appendingPathComponent(IsolationBackends.isolationExecName)
            .path
        if let path = usableIsolationExecPath(sibling) {
            return path
        }
    }
    for bundle in Bundle.allBundles {
        let sibling = bundle.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(IsolationBackends.isolationExecName)
            .path
        if let path = usableIsolationExecPath(sibling) {
            return path
        }
    }
    return nil
}

private func usableIsolationExecPath(_ path: String) -> String? {
    guard IsolatedCommand.isAbsoluteExecutable(path),
        FileManager.default.isExecutableFile(atPath: path)
    else {
        return nil
    }
    return path
}
