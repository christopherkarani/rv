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
    /// A regular file inside the workspace shares its inode with another name.
    /// Seatbelt authorizes the path, so that alias can mutate the other file.
    /// Refuse the launch before the command runs.
    case workspaceContainsInodeAlias
    /// The workspace is not mounted on a filesystem that rejects hard links to
    /// outside inodes, or publishing results would write an unexpected inode.
    /// When this is returned before spawn, the command was not executed.
    case workspaceInodeBoundaryFailed
    case containedGuaranteesUnsupported
    case profileNotApplicable
    case processSpawnFailed
    case commandExecutableMustBeAbsolute
    case commandContainsNUL
    /// The session record was not written. The contained command was not started.
    case sessionRecordFailed
    /// The Seatbelt profile was not shown to be in force before the inner command.
    case seatbeltNotEstablished
    /// The owned process group could not be created or was not empty at return.
    case lifetimeBoundaryFailed
    /// The caller cancelled. The owned process group was signalled before return.
    case cancelled
    /// This project still has an unresolved protected workspace.
    /// No second workspace was created and no host file was overwritten.
    case workspaceUnresolved(String)
}

/// Child stdio. The workspace host chooses this. It is not inferred from
/// whether the caller has a terminal or from whether a client is attached.
///
/// `discard` is `/dev/null` (apply / perform / probes).
/// `inherit` is the in-process host-launch door.
/// `pseudoTerminal` is a PTY the workspace host creates and keeps. The child
/// receives the slave as stdin, stdout, and stderr. Rows and columns are the
/// initial window.
public enum IsolatedIO: Sendable, Equatable {
    case discard
    case inherit
    case pseudoTerminal(rows: Int, columns: Int)
}

/// Absolute argv the backend starts (the inner command, not `sandbox-exec`).
/// Empty and relative executables are unrepresentable.
public struct IsolatedCommand: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]

    public init?(executable: String, arguments: [String] = []) {
        guard IsolatedCommand.isAbsoluteExecutable(executable),
            !executable.contains("\0"), !arguments.contains(where: { $0.contains("\0") })
        else {
            return nil
        }
        self.executable = executable
        self.arguments = arguments
    }

    public static func make(
        executable: String,
        arguments: [String] = []
    ) -> Result<IsolatedCommand, IsolationApplyError> {
        guard !executable.contains("\0"), !arguments.contains(where: { $0.contains("\0") }) else {
            return .failure(.commandContainsNUL)
        }
        guard let command = IsolatedCommand(executable: executable, arguments: arguments) else {
            return .failure(.commandExecutableMustBeAbsolute)
        }
        return .success(command)
    }

    static func isAbsoluteExecutable(_ executable: String) -> Bool {
        executable.isEmpty == false && executable.hasPrefix("/")
    }
}

/// Where a PTY launch is forced to fail. Production leaves this unset.
enum RuntimeSpawnFault: Equatable, Sendable {
    case openpt
    case grant
    case unlock
    case slave
    case spawn
    case register
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
    let io: IsolatedIO
    /// Test-only. Production launches leave this nil. A fault fails the
    /// launch before the payload is reported running.
    let spawnFault: RuntimeSpawnFault?

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

    /// Canonical path used by the prepared OS rules, never a second grant
    /// derived from a retargeted caller path.
    var containedWorkspacePath: String? {
        switch launch {
        case .seatbelt(let profile): profile.workspacePath
        case .landlock(let ruleset): ruleset.workspacePath
        case .unsandboxed: nil
        }
    }

    init?(
        plan: IsolationPlan,
        command: IsolatedCommand,
        launch: Launch,
        io: IsolatedIO = .discard,
        spawnFault: RuntimeSpawnFault? = nil
    ) {
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
        self.io = io
        self.spawnFault = spawnFault
    }

    func withIO(_ io: IsolatedIO) -> IsolatedLaunchRequest {
        IsolatedLaunchRequest(copying: self, io: io, spawnFault: spawnFault)
    }

    func withSpawnFault(_ fault: RuntimeSpawnFault) -> IsolatedLaunchRequest {
        IsolatedLaunchRequest(copying: self, io: io, spawnFault: fault)
    }

    private init(
        copying request: IsolatedLaunchRequest,
        io: IsolatedIO,
        spawnFault: RuntimeSpawnFault?
    ) {
        self.plan = request.plan
        self.command = request.command
        self.family = request.family
        self.launch = request.launch
        self.io = io
        self.spawnFault = spawnFault
    }

    public static func == (lhs: IsolatedLaunchRequest, rhs: IsolatedLaunchRequest) -> Bool {
        lhs.plan == rhs.plan
            && lhs.command == rhs.command
            && lhs.family == rhs.family
            && lhs.launch == rhs.launch
            && lhs.io == rhs.io
            && lhs.spawnFault == rhs.spawnFault
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

    /// Observed and mediated unsandboxed launches. Seatbelt success is built
    /// in `superviseSeatbelt`. Landlock stays a prepared request.
    fileprivate var establishedIsolation: EstablishedIsolation? {
        switch launch {
        case .unsandboxed:
            switch plan.mode {
            case .observed:
                return .observed
            case .mediated:
                return .mediated
            case .contained:
                return nil
            }
        case .seatbelt, .landlock:
            return nil
        }
    }
}

/// What a successful run established. Seatbelt carries the runtime session
/// that reached establishment. Observed and mediated do not. Landlock is not
/// an establishment.
public enum EstablishedIsolation: Sendable, Equatable {
    case observed
    case mediated
    case seatbelt(RuntimeSession)
}

public struct IsolatedRunResult: Sendable, Equatable {
    public let established: EstablishedIsolation
    public let exitStatus: Int32

    /// The session carried by `.seatbelt`. Observed and mediated runs have none.
    public var session: RuntimeSession? {
        if case .seatbelt(let session) = established { return session }
        return nil
    }

    init(established: EstablishedIsolation, exitStatus: Int32) {
        if case .seatbelt(let session) = established {
            precondition(
                session.backend == .seatbelt,
                "Seatbelt establishment requires a seatbelt runtime session"
            )
        }
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
        command: IsolatedCommand,
        io: IsolatedIO = .discard
    ) -> Result<IsolatedRunResult, IsolationApplyError> {
        prepare(plan, command).flatMap { request in
            run(request.withIO(io))
        }
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
        command: IsolatedCommand,
        io: IsolatedIO = .discard,
        admission: RuntimeAdmissionConfiguration = .failClosed
    ) -> Result<IsolatedRunResult, IsolationApplyError> {
        applyLaunch(
            plan,
            command: command,
            io: io,
            host: nil,
            sessionStore: .production,
            admission: admission
        )
    }

    static func applyLaunch(
        _ plan: IsolationPlan,
        command: IsolatedCommand,
        io: IsolatedIO,
        host: HookHost?,
        sessionStore: RuntimeSessionStore,
        admission: RuntimeAdmissionConfiguration = .failClosed
    ) -> Result<IsolatedRunResult, IsolationApplyError> {
        switch plan.mode {
        case .observed, .mediated:
            return unavailable().apply(plan, command: command, io: io)
        case .contained:
            switch platform().prepare(plan, command) {
            case .failure(let error):
                return .failure(error)
            case .success(let request):
                let prepared = request.withIO(io)
                switch prepared.family {
                case .seatbelt:
                    return runSeatbeltLaunch(
                        prepared,
                        host: host,
                        sessionStore: sessionStore,
                        admission: admission
                    )
                case .landlock:
                    return runLandlock(prepared, executable: nil)
                case .none:
                    return .failure(.backendMismatch)
                }
            }
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
        case .success(let compiled):
            let profile = compiled.allowingExecutable(command.executable)
            guard let workspace = plan.workspace else {
                return .failure(.containedGuaranteesUnsupported)
            }
            switch existingResolvedWorkspacePath(workspace) {
            case .failure(let error):
                return .failure(error)
            case .success(let resolved):
                guard profile.workspacePath == resolved else {
                    return .failure(.workspacePathUnresolvable)
                }
                switch rejectWorkspaceInodeAlias(resolved) {
                case .failure(let error):
                    return .failure(error)
                case .success:
                    break
                }
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
    runSeatbeltLaunch(request, host: nil, sessionStore: .production)
}

func runSeatbeltLaunch(
    _ request: IsolatedLaunchRequest,
    host: HookHost?,
    sessionStore: RuntimeSessionStore,
    admission: RuntimeAdmissionConfiguration = .failClosed
) -> Result<IsolatedRunResult, IsolationApplyError> {
    guard request.family == .seatbelt else {
        return .failure(.backendMismatch)
    }
    #if os(macOS)
    guard FileManager.default.isExecutableFile(atPath: IsolationBackends.sandboxExecPath) else {
        return .failure(.backendUnavailable)
    }
    return spawn(request, host: host, sessionStore: sessionStore, admission: admission)
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

/// Starts the process described by a prepared request.
/// Seatbelt calls `superviseSeatbelt` and does not treat spawn itself as
/// establishment. Observed and mediated runs wait for the immediate child.
/// Landlock is refused before exec: a helper exit is not contained establishment.
func spawn(
    _ request: IsolatedLaunchRequest,
    executablePath: String? = nil,
    host: HookHost? = nil,
    sessionStore: RuntimeSessionStore = .production,
    admission: RuntimeAdmissionConfiguration = .failClosed
) -> Result<IsolatedRunResult, IsolationApplyError> {
    if request.family == .seatbelt {
        #if os(macOS)
        return superviseSeatbelt(
            request,
            host: host,
            sessionStore: sessionStore,
            admission: admission
        )
        #else
        return .failure(.backendUnavailable)
        #endif
    }
    if request.family == .landlock {
        return refuseLandlockSpawn(request, executablePath: executablePath)
    }
    guard let established = request.establishedIsolation else {
        return .failure(.backendMismatch)
    }
    let candidate = executablePath ?? request.launchExecutable
    guard IsolatedCommand.isAbsoluteExecutable(candidate) else {
        return .failure(.backendUnavailable)
    }
    let path = candidate
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = request.launchArguments
    if let preparedPath = request.containedWorkspacePath {
        guard let workspace = request.plan.workspace else {
            return .failure(.containedGuaranteesUnsupported)
        }
        switch existingResolvedWorkspacePath(workspace) {
        case .failure(let error):
            return .failure(error)
        case .success(let resolved):
            guard resolved == preparedPath else {
                return .failure(.workspacePathUnresolvable)
            }
        }
        process.currentDirectoryURL = URL(fileURLWithPath: preparedPath)
        // The security helper's loader runs before its main/apply function.
        // Never forward ambient credentials, loader/interpreter hooks, sockets,
        // or a caller-controlled search path across that pre-isolation boundary.
        process.environment = [
            "PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C",
            "HOME": preparedPath, "TMPDIR": preparedPath,
        ]
    } else if let workspace = request.plan.workspace,
        let resolved = posixRealpath(workspace.rawValue)
    {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            process.currentDirectoryURL = URL(fileURLWithPath: resolved)
        }
    }
    switch request.io {
    case .discard:
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    case .inherit:
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
    case .pseudoTerminal:
        // A host-owned PTY exists only on the contained Seatbelt path.
        return .failure(.processSpawnFailed)
    }
    do {
        try process.run()
    } catch {
        return .failure(.processSpawnFailed)
    }
    process.waitUntilExit()
    switch request.family {
    case .none:
        return .success(
            IsolatedRunResult(established: established, exitStatus: process.terminationStatus)
        )
    case .landlock, .seatbelt:
        return .failure(.backendMismatch)
    }
}

/// Regular files with more than one link can point at an inode outside the
/// workspace while their path stays inside the Seatbelt write allow.
/// Directories have a link count above one without being aliases.
/// Symlink entries are not followed. A scan failure refuses the launch.
func rejectWorkspaceInodeAlias(_ root: String) -> Result<Void, IsolationApplyError> {
    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    // FileManager calls this handler synchronously on the scanning thread.
    let scan = InodeAliasScan()
    guard
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .linkCountKey],
            options: [],
            errorHandler: { _, _ in
                scan.failed = true
                return false
            }
        )
    else {
        return .failure(.workspaceContainsInodeAlias)
    }
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .linkCountKey]
    for case let url as URL in enumerator {
        if scan.failed {
            return .failure(.workspaceContainsInodeAlias)
        }
        do {
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                continue
            }
            if values.isRegularFile == true, let count = values.linkCount, count > 1 {
                return .failure(.workspaceContainsInodeAlias)
            }
        } catch {
            return .failure(.workspaceContainsInodeAlias)
        }
    }
    if scan.failed {
        return .failure(.workspaceContainsInodeAlias)
    }
    return .success(())
}

/// Mutable flag for `rejectWorkspaceInodeAlias`. The directory walk is synchronous.
private final class InodeAliasScan: @unchecked Sendable {
    var failed = false
}
