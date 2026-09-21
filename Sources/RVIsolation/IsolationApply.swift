import Foundation
import RVDomain

public enum IsolationBackendFamily: Sendable, Equatable {
    case none
    case seatbelt
    case landlock
}

public enum IsolationApplyError: Error, Sendable, Equatable {
    case backendUnavailable
    case backendMismatch
    case workspaceMustBeAbsolute
    case workspaceDoesNotExist
    case workspacePathUnresolvable
    case workspacePathUnsafe
    case containedGuaranteesUnsupported
    case profileNotApplicable
    case processSpawnFailed
    case commandExecutableMustBeAbsolute
}

/// Absolute argv the backend starts (the inner command, not `sandbox-exec`).
/// Empty and relative executables are unrepresentable.
public struct IsolatedCommand: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]

    public init?(executable: String, arguments: [String] = []) {
        guard IsolatedCommand.isAbsoluteExecutable(executable) else {
            return nil
        }
        self.executable = executable
        self.arguments = arguments
    }

    public static func make(
        executable: String,
        arguments: [String] = []
    ) -> Result<IsolatedCommand, IsolationApplyError> {
        guard let command = IsolatedCommand(executable: executable, arguments: arguments) else {
            return .failure(.commandExecutableMustBeAbsolute)
        }
        return .success(command)
    }

    static func isAbsoluteExecutable(_ executable: String) -> Bool {
        executable.isEmpty == false && executable.hasPrefix("/")
    }
}

/// Prepared launch. Not established. Production construction is `prepare`.
public struct IsolatedLaunchRequest: Sendable, Equatable {
    enum Launch: Sendable, Equatable {
        case seatbelt(SeatbeltProfile)
        case landlock(LandlockRuleset)
        case unsandboxed
    }

    public let plan: IsolationPlan
    public let command: IsolatedCommand
    public let family: IsolationBackendFamily
    let launch: Launch

    var seatbeltProfile: SeatbeltProfile? {
        switch launch {
        case .seatbelt(let profile):
            return profile
        case .landlock, .unsandboxed:
            return nil
        }
    }

    var landlockRuleset: LandlockRuleset? {
        switch launch {
        case .landlock(let ruleset):
            return ruleset
        case .seatbelt, .unsandboxed:
            return nil
        }
    }

    init?(plan: IsolationPlan, command: IsolatedCommand, launch: Launch) {
        switch (launch, plan.mode) {
        case (.seatbelt, .contained):
            self.family = .seatbelt
        case (.landlock, .contained):
            self.family = .landlock
        case (.unsandboxed, .observed), (.unsandboxed, .mediated):
            self.family = .none
        case (.seatbelt, .observed), (.seatbelt, .mediated),
            (.landlock, .observed), (.landlock, .mediated),
            (.unsandboxed, .contained):
            return nil
        }
        self.plan = plan
        self.command = command
        self.launch = launch
    }

    /// Executable `run` will start. Observed / mediated never use a helper.
    /// Landlock's path is resolved at `run` to an absolute `rv-isolation-exec`
    /// outside the workspace; this is only the basename until then.
    var launchExecutable: String {
        switch launch {
        case .seatbelt:
            return IsolationBackends.sandboxExecPath
        case .landlock:
            return IsolationBackends.isolationExecName
        case .unsandboxed:
            return command.executable
        }
    }

    var launchArguments: [String] {
        switch launch {
        case .seatbelt(let profile):
            return ["-p", profile.source, command.executable] + command.arguments
        case .landlock(let ruleset):
            return ["--workspace", ruleset.workspacePath, "--", command.executable]
                + command.arguments
        case .unsandboxed:
            return command.arguments
        }
    }

    fileprivate var establishedIsolation: EstablishedIsolation? {
        EstablishedIsolation(mode: plan.mode, family: family)
    }
}

/// What was actually applied after a successful spawn. Factory rejects
/// contained+none and observed/mediated+seatbelt.
public struct EstablishedIsolation: Sendable, Equatable {
    public let mode: EnforcementMode
    public let family: IsolationBackendFamily

    init?(mode: EnforcementMode, family: IsolationBackendFamily) {
        switch (mode, family) {
        case (.contained, .seatbelt), (.contained, .landlock),
            (.observed, .none), (.mediated, .none):
            self.mode = mode
            self.family = family
        case (.contained, .none),
            (.observed, .seatbelt), (.mediated, .seatbelt),
            (.observed, .landlock), (.mediated, .landlock):
            return nil
        }
    }
}

public struct IsolatedRunResult: Sendable, Equatable {
    public let established: EstablishedIsolation
    public let exitStatus: Int32

    init(established: EstablishedIsolation, exitStatus: Int32) {
        self.established = established
        self.exitStatus = exitStatus
    }
}

public struct IsolationBackend: Sendable {
    public let family: IsolationBackendFamily
    public let prepare:
        @Sendable (IsolationPlan, IsolatedCommand) -> Result<IsolatedLaunchRequest, IsolationApplyError>
    public let run: @Sendable (IsolatedLaunchRequest) -> Result<IsolatedRunResult, IsolationApplyError>

    init(
        family: IsolationBackendFamily,
        prepare: @escaping @Sendable (IsolationPlan, IsolatedCommand) -> Result<
            IsolatedLaunchRequest, IsolationApplyError
        >,
        run: @escaping @Sendable (IsolatedLaunchRequest) -> Result<IsolatedRunResult, IsolationApplyError>
    ) {
        self.family = family
        self.prepare = prepare
        self.run = run
    }

    public func apply(
        _ plan: IsolationPlan,
        command: IsolatedCommand
    ) -> Result<IsolatedRunResult, IsolationApplyError> {
        prepare(plan, command).flatMap(run)
    }
}

public enum IsolationBackends {
    static let sandboxExecPath = "/usr/bin/sandbox-exec"
    static let isolationExecName = "rv-isolation-exec"
    /// Trampoline reserved exit: apply failed, inner was not exec'd.
    static let isolationExecCouldNotEstablishExit: Int32 = 125
    /// Trampoline reserved exit: Landlock applied, then `execve` failed.
    static let isolationExecExecFailedExit: Int32 = 126

    public static func seatbelt() -> IsolationBackend {
        IsolationBackend(
            family: .seatbelt,
            prepare: prepareSeatbelt,
            run: runSeatbelt
        )
    }

    public static func unavailable() -> IsolationBackend {
        IsolationBackend(
            family: .none,
            prepare: prepareUnavailable,
            run: runUnavailable
        )
    }

    public static func platform() -> IsolationBackend {
        #if os(macOS)
        seatbelt()
        #elseif os(Linux)
        landlock()
        #else
        unavailable()
        #endif
    }

    /// Production door. Observed / mediated always establish family `.none`
    /// without a sandbox helper. Contained uses `platform()` (Seatbelt on
    /// macOS, Landlock on Linux) and fails closed when that backend cannot
    /// establish it. `IsolationPlan.mode` is unchanged.
    public static func apply(
        _ plan: IsolationPlan,
        command: IsolatedCommand
    ) -> Result<IsolatedRunResult, IsolationApplyError> {
        switch plan.mode {
        case .observed, .mediated:
            return unavailable().apply(plan, command: command)
        case .contained:
            return platform().apply(plan, command: command)
        }
    }
}

func prepareSeatbelt(
    _ plan: IsolationPlan,
    _ command: IsolatedCommand
) -> Result<IsolatedLaunchRequest, IsolationApplyError> {
    switch plan.mode {
    case .observed, .mediated:
        return .failure(.profileNotApplicable)
    case .contained:
        switch compileSeatbeltProfile(plan) {
        case .failure(let error):
            return .failure(error)
        case .success(let profile):
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
                    launch: .seatbelt(profile)
                )
            else {
                return .failure(.containedGuaranteesUnsupported)
            }
            return .success(request)
        }
    }
}

func prepareUnavailable(
    _ plan: IsolationPlan,
    _ command: IsolatedCommand
) -> Result<IsolatedLaunchRequest, IsolationApplyError> {
    switch plan.mode {
    case .contained:
        return .failure(.backendUnavailable)
    case .observed, .mediated:
        guard
            let request = IsolatedLaunchRequest(
                plan: plan,
                command: command,
                launch: .unsandboxed
            )
        else {
            return .failure(.backendMismatch)
        }
        return .success(request)
    }
}

func runSeatbelt(
    _ request: IsolatedLaunchRequest
) -> Result<IsolatedRunResult, IsolationApplyError> {
    guard request.family == .seatbelt else {
        return .failure(.backendMismatch)
    }
    #if os(macOS)
    guard FileManager.default.isExecutableFile(atPath: IsolationBackends.sandboxExecPath) else {
        return .failure(.backendUnavailable)
    }
    return spawn(request)
    #else
    return .failure(.backendUnavailable)
    #endif
}

func runUnavailable(
    _ request: IsolatedLaunchRequest
) -> Result<IsolatedRunResult, IsolationApplyError> {
    guard request.family == .none else {
        return .failure(.backendMismatch)
    }
    switch request.plan.mode {
    case .contained:
        return .failure(.backendUnavailable)
    case .observed, .mediated:
        return spawn(request)
    }
}

/// Starts the process described by a prepared request, then returns
/// `EstablishedIsolation`. A spawn failure produces no established record.
/// A non-zero child exit is still success unless the Landlock trampoline
/// exits 125 (could not establish) or 126 (`execve` failed after apply).
/// Landlock never falls back to the inner command or an untyped absolute.
func spawn(
    _ request: IsolatedLaunchRequest,
    executablePath: String? = nil
) -> Result<IsolatedRunResult, IsolationApplyError> {
    guard let established = request.establishedIsolation else {
        return .failure(.backendMismatch)
    }
    let candidate = executablePath ?? request.launchExecutable
    let path: String
    switch request.family {
    case .landlock:
        guard let ruleset = request.landlockRuleset,
            let verified = usableIsolationExecPath(
                candidate,
                workspacePath: ruleset.workspacePath
            )
        else {
            return .failure(.backendUnavailable)
        }
        path = verified
    case .none, .seatbelt:
        guard IsolatedCommand.isAbsoluteExecutable(candidate) else {
            return .failure(.backendUnavailable)
        }
        path = candidate
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = request.launchArguments
    if let workspace = request.plan.workspace,
        let resolved = posixRealpath(workspace.rawValue)
    {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            process.currentDirectoryURL = URL(fileURLWithPath: resolved)
        }
    }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return .failure(.processSpawnFailed)
    }
    process.waitUntilExit()
    switch request.family {
    case .landlock:
        return interpretIsolationExecExit(process.terminationStatus, established: established)
    case .none, .seatbelt:
        return .success(
            IsolatedRunResult(established: established, exitStatus: process.terminationStatus)
        )
    }
}
