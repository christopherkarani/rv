import Foundation
import RVDomain

public enum IsolationBackendFamily: Sendable, Equatable {
    case none
    case seatbelt
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
public struct IsolatedCommand: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String] = []) {
        self.executable = executable
        self.arguments = arguments
    }
}

/// Prepared launch. Not established. Production construction is `prepare`.
public struct IsolatedLaunchRequest: Sendable, Equatable {
    public let plan: IsolationPlan
    public let command: IsolatedCommand
    public let family: IsolationBackendFamily
    let seatbeltProfile: SeatbeltProfile?

    init?(
        plan: IsolationPlan,
        command: IsolatedCommand,
        family: IsolationBackendFamily,
        seatbeltProfile: SeatbeltProfile?
    ) {
        switch (family, seatbeltProfile, plan.mode) {
        case (.seatbelt, .some, .contained):
            break
        case (.none, .none, .observed), (.none, .none, .mediated):
            break
        default:
            return nil
        }
        self.plan = plan
        self.command = command
        self.family = family
        self.seatbeltProfile = seatbeltProfile
    }

    /// Executable `run` will start. Observed / mediated never use `sandbox-exec`.
    var launchExecutable: String {
        switch family {
        case .seatbelt:
            return IsolationBackends.sandboxExecPath
        case .none:
            return command.executable
        }
    }

    var launchArguments: [String] {
        switch family {
        case .seatbelt:
            guard let profile = seatbeltProfile else {
                return command.arguments
            }
            return ["-p", profile.source, command.executable] + command.arguments
        case .none:
            return command.arguments
        }
    }
}

/// What was actually applied after a successful spawn. Factory rejects
/// contained+none and observed/mediated+seatbelt.
public struct EstablishedIsolation: Sendable, Equatable {
    public let mode: EnforcementMode
    public let family: IsolationBackendFamily

    init?(mode: EnforcementMode, family: IsolationBackendFamily) {
        switch (mode, family) {
        case (.contained, .seatbelt), (.observed, .none), (.mediated, .none):
            self.mode = mode
            self.family = family
        case (.contained, .none), (.observed, .seatbelt), (.mediated, .seatbelt):
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
}

public enum IsolationBackends {
    static let sandboxExecPath = "/usr/bin/sandbox-exec"

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
        #else
        unavailable()
        #endif
    }
}

private func requireAbsoluteCommand(
    _ command: IsolatedCommand
) -> IsolationApplyError? {
    if command.executable.isEmpty || command.executable.hasPrefix("/") == false {
        return .commandExecutableMustBeAbsolute
    }
    return nil
}

private func workspaceDirectoryExists(_ workspace: WorkingDirectory) -> Bool {
    let resolved = resolvedWorkspacePath(workspace)
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory)
    return exists && isDirectory.boolValue
}

func prepareSeatbelt(
    _ plan: IsolationPlan,
    _ command: IsolatedCommand
) -> Result<IsolatedLaunchRequest, IsolationApplyError> {
    if let error = requireAbsoluteCommand(command) {
        return .failure(error)
    }
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
            guard workspaceDirectoryExists(workspace) else {
                return .failure(.workspaceDoesNotExist)
            }
            guard
                let request = IsolatedLaunchRequest(
                    plan: plan,
                    command: command,
                    family: .seatbelt,
                    seatbeltProfile: profile
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
    if let error = requireAbsoluteCommand(command) {
        return .failure(error)
    }
    switch plan.mode {
    case .contained:
        return .failure(.backendUnavailable)
    case .observed, .mediated:
        guard
            let request = IsolatedLaunchRequest(
                plan: plan,
                command: command,
                family: .none,
                seatbeltProfile: nil
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
    guard let profile = request.seatbeltProfile else {
        return .failure(.backendMismatch)
    }
    guard FileManager.default.isExecutableFile(atPath: IsolationBackends.sandboxExecPath) else {
        return .failure(.backendUnavailable)
    }
    return spawn(
        executable: IsolationBackends.sandboxExecPath,
        arguments: ["-p", profile.source, request.command.executable] + request.command.arguments,
        workspace: request.plan.workspace,
        mode: request.plan.mode,
        family: .seatbelt
    )
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
        return spawn(
            executable: request.command.executable,
            arguments: request.command.arguments,
            workspace: request.plan.workspace,
            mode: request.plan.mode,
            family: .none
        )
    }
}

/// Starts the process, then mints `EstablishedIsolation`. A spawn failure
/// produces no established record. A non-zero child exit is still success.
func spawn(
    executable: String,
    arguments: [String],
    workspace: WorkingDirectory?,
    mode: EnforcementMode,
    family: IsolationBackendFamily
) -> Result<IsolatedRunResult, IsolationApplyError> {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let workspace, workspaceDirectoryExists(workspace) {
        process.currentDirectoryURL = URL(fileURLWithPath: resolvedWorkspacePath(workspace))
    }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return .failure(.processSpawnFailed)
    }
    guard let established = EstablishedIsolation(mode: mode, family: family) else {
        process.terminate()
        process.waitUntilExit()
        return .failure(.backendMismatch)
    }
    process.waitUntilExit()
    return .success(IsolatedRunResult(established: established, exitStatus: process.terminationStatus))
}
