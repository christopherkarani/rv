import Foundation
import RVDomain

extension IsolationBackends {
    /// Landlock backend. `run` applies via `rv-isolation-exec` on Linux.
    /// Darwin `run` is `backendUnavailable` (prepare may still succeed).
    ///
    /// `executable` is a test seam: an absolute regular file whose last
    /// path component is `rv-isolation-exec` and whose realpath is not
    /// at or under the workspace. Other paths fail closed. Production
    /// `apply()` does not read `RV_ISOLATION_EXEC`.
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
            case .success(let resolved):
                guard ruleset.workspacePath == resolved else {
                    return .failure(.workspacePathUnresolvable)
                }
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
    guard let ruleset = request.landlockRuleset else {
        return .failure(.backendMismatch)
    }
    guard let path = resolvedIsolationExecPath(
        override: executable,
        workspacePath: ruleset.workspacePath
    ) else {
        return .failure(.backendUnavailable)
    }
    return spawn(request, executablePath: path)
    #else
    return .failure(.backendUnavailable)
    #endif
}

/// Exit 125 means the trampoline did not apply Landlock or rejected argv.
/// Exit 126 means apply succeeded then `execve` failed — not established,
/// and not a successful inner exit.
func interpretIsolationExecExit(
    _ status: Int32,
    established: EstablishedIsolation
) -> Result<IsolatedRunResult, IsolationApplyError> {
    if status == IsolationBackends.isolationExecCouldNotEstablishExit {
        return .failure(.backendUnavailable)
    }
    if status == IsolationBackends.isolationExecExecFailedExit {
        return .failure(.processSpawnFailed)
    }
    return .success(IsolatedRunResult(established: established, exitStatus: status))
}

/// Locate `rv-isolation-exec`. Never a relative argv0 guess, never an env
/// override, never a helper at or under the workspace (including a
/// workspace symlink whose target is outside).
func resolvedIsolationExecPath(override: URL?, workspacePath: String) -> String? {
    if let override {
        return usableIsolationExecPath(override.path, workspacePath: workspacePath)
    }
    if let argv0 = CommandLine.arguments.first,
        IsolatedCommand.isAbsoluteExecutable(argv0)
    {
        let sibling = URL(fileURLWithPath: argv0)
            .deletingLastPathComponent()
            .appendingPathComponent(IsolationBackends.isolationExecName)
            .path
        if let path = usableIsolationExecPath(sibling, workspacePath: workspacePath) {
            return path
        }
    }
    for bundle in Bundle.allBundles {
        let sibling = bundle.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(IsolationBackends.isolationExecName)
            .path
        if let path = usableIsolationExecPath(sibling, workspacePath: workspacePath) {
            return path
        }
    }
    return nil
}

func usableIsolationExecPath(_ path: String, workspacePath: String) -> String? {
    guard IsolatedCommand.isAbsoluteExecutable(path) else {
        return nil
    }
    let name = URL(fileURLWithPath: path).lastPathComponent
    guard name == IsolationBackends.isolationExecName else {
        return nil
    }
    guard FileManager.default.isExecutableFile(atPath: path) else {
        return nil
    }
    guard let resolved = posixRealpath(path) else {
        return nil
    }
    guard IsolatedCommand.isAbsoluteExecutable(resolved),
        isFilesystemRoot(resolved) == false,
        URL(fileURLWithPath: resolved).lastPathComponent == IsolationBackends.isolationExecName
    else {
        return nil
    }
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory)
    guard exists, isDirectory.boolValue == false else {
        return nil
    }
    let canonicalWorkspace = posixRealpath(workspacePath) ?? workspacePath
    if isFilesystemRoot(canonicalWorkspace)
        || isLookupInsideWorkspace(path, workspace: canonicalWorkspace)
        || isResolvedPath(resolved, atOrBeneath: canonicalWorkspace)
    {
        return nil
    }
    return resolved
}

/// True when the lookup lives in the workspace, even if the last component
/// is a symlink to an outside file named `rv-isolation-exec`.
func isLookupInsideWorkspace(_ path: String, workspace: String) -> Bool {
    if isResolvedPath(path, atOrBeneath: workspace) {
        return true
    }
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    guard let parentReal = posixRealpath(parent),
        isFilesystemRoot(parentReal) == false
    else {
        return false
    }
    return isResolvedPath(parentReal, atOrBeneath: workspace)
}
