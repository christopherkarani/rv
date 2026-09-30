import Foundation
import RVDomain

extension IsolationBackends {
    /// Landlock backend. Contained `prepare` returns
    /// `containedGuaranteesUnsupported` and does not exec. Darwin `run` is
    /// `backendUnavailable`. A hand-built landlock request is refused before exec.
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
        case .success:
            return .failure(.containedGuaranteesUnsupported)
        case .failure(let error):
            return .failure(error)
        }
    }
}

func runLandlockOffPool(
    _ request: IsolatedLaunchRequest,
    executable: URL?
) async -> Result<IsolatedRunResult, IsolationApplyError> {
    await IsolationBlockingWork.perform {
        runLandlock(request, executable: executable)
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
    guard
        case .success(let path) = resolvedIsolationExecPath(
            override: executable,
            workspacePath: ruleset.workspacePath
        )
    else {
        return .failure(.backendUnavailable)
    }
    return spawn(request, executablePath: path)
    #else
    return .failure(.backendUnavailable)
    #endif
}

/// Exit 125 means the trampoline did not apply Landlock or rejected argv.
/// Exit 126 means apply succeeded then `execve` failed.
/// Any other status, including 0, is not contained establishment.
/// Production launch does not exec the helper; this mapping stays for the
/// helper's own exit codes and must not mint `IsolatedRunResult`.
func interpretIsolationExecExit(
    _ status: Int32
) -> Result<IsolatedRunResult, IsolationApplyError> {
    if status == IsolationBackends.isolationExecCouldNotEstablishExit {
        return .failure(.backendUnavailable)
    }
    if status == IsolationBackends.isolationExecExecFailedExit {
        return .failure(.processSpawnFailed)
    }
    return .failure(.containedGuaranteesUnsupported)
}

/// Write-class Landlock does not meet a contained plan. Check helper identity,
/// then refuse before exec so a zero exit cannot be reported as establishment.
func refuseLandlockSpawn(
    _ request: IsolatedLaunchRequest,
    executablePath: String?
) -> Result<IsolatedRunResult, IsolationApplyError> {
    guard let ruleset = request.landlockRuleset else {
        return .failure(.backendMismatch)
    }
    guard
        case .success = usableIsolationExecPath(
            executablePath ?? request.launchExecutable,
            workspacePath: ruleset.workspacePath
        )
    else {
        return .failure(.backendUnavailable)
    }
    return .failure(.containedGuaranteesUnsupported)
}

/// Why an `rv-isolation-exec` candidate was refused. Every old `nil` is
/// one case; callers still fail closed with `.backendUnavailable`, but
/// tests and future diagnostics see the reason. `.unresolvable` and
/// `.doesNotExist` are teardown races (the path passed an earlier check
/// and vanished); every other case is deterministically pinned by tests.
enum IsolationExecRefusal: Error, Sendable, Equatable {
    /// Candidate path is not absolute.
    case notAbsolute
    /// Basename is not `rv-isolation-exec`.
    case wrongName
    /// `access(X_OK)` failed (missing, unexecutable, or dangling).
    case notExecutable
    /// Realpath failed after the executable check (torn down mid-lookup).
    case unresolvable
    /// Resolved to filesystem root.
    case resolvedIsRoot
    /// Resolved basename is not `rv-isolation-exec` (symlink retarget).
    case resolvedWrongName
    /// Resolved path vanished between realpath and stat.
    case doesNotExist
    /// Resolved path is a directory.
    case isDirectory
    /// Workspace canonicalizes to filesystem root.
    case workspaceIsRoot
    /// The lookup path lives in the workspace (even a symlink to outside).
    case lookupInsideWorkspace
    /// The resolved path is at or under the workspace.
    case resolvedInsideWorkspace
    /// `/proc/self/exe` did not resolve (Linux self-locate).
    case selfLookupFailed
    /// No candidate location existed to check.
    case notFound
}

/// Locate `rv-isolation-exec`. Never a relative argv0 guess, never an env
/// override, never a helper at or under the workspace (including a
/// workspace symlink whose target is outside). On failure returns the last
/// refusal encountered across the candidate locations.
func resolvedIsolationExecPath(
    override: URL?,
    workspacePath: String
) -> Result<String, IsolationExecRefusal> {
    if let override {
        return usableIsolationExecPath(override.path, workspacePath: workspacePath)
    }
    #if os(Linux)
    // argv[0] is caller-controlled and may be just `rv` when the installed
    // C front door execs rv-cli. Locate the sibling of the kernel's actual
    // executable, independent of PATH and the spelling of argv[0].
    guard let executable = posixRealpath("/proc/self/exe") else {
        return .failure(.selfLookupFailed)
    }
    let sibling = URL(fileURLWithPath: executable)
        .deletingLastPathComponent()
        .appendingPathComponent(IsolationBackends.isolationExecName).path
    return usableIsolationExecPath(sibling, workspacePath: workspacePath)
    #else
    var refusal = IsolationExecRefusal.notFound
    if let argv0 = CommandLine.arguments.first,
        IsolatedCommand.isAbsoluteExecutable(argv0)
    {
        let sibling = URL(fileURLWithPath: argv0)
            .deletingLastPathComponent()
            .appendingPathComponent(IsolationBackends.isolationExecName)
            .path
        switch usableIsolationExecPath(sibling, workspacePath: workspacePath) {
        case .success(let path):
            return .success(path)
        case .failure(let error):
            refusal = error
        }
    }
    for bundle in Bundle.allBundles {
        let sibling = bundle.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(IsolationBackends.isolationExecName)
            .path
        switch usableIsolationExecPath(sibling, workspacePath: workspacePath) {
        case .success(let path):
            return .success(path)
        case .failure(let error):
            refusal = error
        }
    }
    return .failure(refusal)
    #endif
}

func usableIsolationExecPath(
    _ path: String,
    workspacePath: String
) -> Result<String, IsolationExecRefusal> {
    guard IsolatedCommand.isAbsoluteExecutable(path) else {
        return .failure(.notAbsolute)
    }
    let name = URL(fileURLWithPath: path).lastPathComponent
    guard name == IsolationBackends.isolationExecName else {
        return .failure(.wrongName)
    }
    guard FileManager.default.isExecutableFile(atPath: path) else {
        return .failure(.notExecutable)
    }
    guard let resolved = posixRealpath(path) else {
        return .failure(.unresolvable)
    }
    // No absolute check: realpath succeeds only with an absolute result.
    guard isFilesystemRoot(resolved) == false else {
        return .failure(.resolvedIsRoot)
    }
    guard URL(fileURLWithPath: resolved).lastPathComponent == IsolationBackends.isolationExecName else {
        return .failure(.resolvedWrongName)
    }
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory)
    guard exists else {
        return .failure(.doesNotExist)
    }
    guard isDirectory.boolValue == false else {
        return .failure(.isDirectory)
    }
    let canonicalWorkspace = posixRealpath(workspacePath) ?? workspacePath
    guard isFilesystemRoot(canonicalWorkspace) == false else {
        return .failure(.workspaceIsRoot)
    }
    guard isLookupInsideWorkspace(path, workspace: canonicalWorkspace) == false else {
        return .failure(.lookupInsideWorkspace)
    }
    guard isResolvedPath(resolved, atOrBeneath: canonicalWorkspace) == false else {
        return .failure(.resolvedInsideWorkspace)
    }
    return .success(resolved)
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
