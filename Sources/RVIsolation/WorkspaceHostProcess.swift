#if os(macOS)
import Darwin
import Foundation
import RVDomain
import RVIPC
import RVPolicy

/// `rvd` is the user-wide hook and policy service. It does not
/// own a workspace volume, owner lock, or runtime process group. A workspace
/// host is a separate process whose lifetime is one `WorkspaceSession`.
public enum WorkspaceHostProcess {
    public static func run(
        workspace: String,
        admission: RuntimeAdmissionConfiguration,
        principalBridge: @Sendable (WorkspacePrincipalAuthority) -> Void = { _ in },
        prepareBridge: (@Sendable (@escaping HostPrepareHandler) -> Void)? = nil,
        redeemBridge: (@Sendable (@escaping HostRedeemHandler) -> Void)? = nil
    ) -> Int32 {
        guard workspace.contains("\0") == false,
            let directory = WorkingDirectory(validating: workspace),
            let configuration = WorkspaceHostLocation.configurationDirectory()
        else {
            complain("workspace host failed")
            return WorkspaceHostExit.failed
        }
        let resourcePolicy: RuntimeResourcePolicy
        guard let passwd = getpwuid(getuid()), let homePointer = passwd.pointee.pw_dir else {
            complain("runtime resource policy home unavailable")
            return WorkspaceHostExit.failed
        }
        let resourceConfiguration = URL(fileURLWithPath: String(cString: homePointer), isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("rv", isDirectory: true)
        switch RuntimeResourcePolicyStore.load(from: resourceConfiguration) {
        case .failure:
            complain("runtime resource policy invalid or unsafe")
            return WorkspaceHostExit.failed
        case .success(let loaded):
            resourcePolicy = loaded
        }
        let agentDefinitions: AgentDefinitionSet
        switch AgentDefinitionStore.load(from: resourceConfiguration, resourcePolicy: resourcePolicy) {
        case .failure:
            complain("agent definitions invalid or unsafe")
            return WorkspaceHostExit.failed
        case .success(let loaded):
            agentDefinitions = loaded
        }
        let supervisor: WorkspaceSessionSupervisor
        switch WorkspaceSessionSupervisor.open(directory) {
        case .failure(let error):
            return exitCode(error)
        case .success(let opened):
            supervisor = opened
        }
        let runtime = WorkspaceHostLocation.runtimeLog(in: configuration)
        switch WorkspaceHostServer.start(
            supervisor: supervisor,
            configurationDirectory: configuration,
            sessionStore: .file(runtime),
            resourcePolicy: resourcePolicy,
            agentDefinitions: agentDefinitions,
            admission: admission
        ) {
        case .failure:
            _ = supervisor.close()
            complain("workspace host failed")
            return WorkspaceHostExit.failed
        case .success(let server):
            principalBridge(server.principalAuthority)
            prepareBridge?(server.makePrepareHandler())
            redeemBridge?(server.makeRedeemHandler())
            server.waitForClose()
            return WorkspaceHostExit.closed
        }
    }

    private static func exitCode(_ error: WorkspaceSessionError) -> Int32 {
        switch error {
        case .ownedByLiveProcess, .recoveryInProgress:
            complain("workspace host lost the ownership race")
            return WorkspaceHostExit.liveOwner
        case .unresolvedWorkspace:
            complain("workspace recovery is blocked")
            return WorkspaceHostExit.recoveryBlocked
        default:
            complain("workspace host failed")
            return WorkspaceHostExit.failed
        }
    }

    private static func complain(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

enum WorkspaceRootPolicy {
    static func isHomeDirectory(project: String, homeDirectory: String) -> Bool {
        func canonicalPath(_ path: String) -> String {
            URL(fileURLWithPath: path, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
        }
        return canonicalPath(project) == canonicalPath(homeDirectory)
    }
}

public enum WorkspaceHostExecutable {
    public static func currentSibling() -> URL? {
        let base = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        let sibling = base.deletingLastPathComponent().appendingPathComponent("rv-workspace-host")
        guard FileManager.default.isExecutableFile(atPath: sibling.path) else { return nil }
        return sibling
    }
}

public enum WorkspaceHostLauncher {
    public static func spawn(executable: URL, workspace: String) -> Result<pid_t, WorkspaceHostFailure> {
        guard executable.path.hasPrefix("/"),
            workspace.contains("\0") == false,
            FileManager.default.isExecutableFile(atPath: executable.path)
        else {
            return .failure(.hostBinaryMissing)
        }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return .failure(.spawnFailed) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let null = open("/dev/null", O_RDWR | O_CLOEXEC)
        guard null >= 0 else { return .failure(.spawnFailed) }
        defer { close(null) }
        guard posix_spawn_file_actions_adddup2(&actions, null, STDIN_FILENO) == 0,
            posix_spawn_file_actions_adddup2(&actions, null, STDOUT_FILENO) == 0,
            posix_spawn_file_actions_adddup2(&actions, null, STDERR_FILENO) == 0,
            posix_spawn_file_actions_addclose(&actions, null) == 0
        else {
            return .failure(.spawnFailed)
        }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return .failure(.spawnFailed) }
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(POSIX_SPAWN_SETSID)
        guard posix_spawnattr_setflags(&attributes, flags) == 0 else { return .failure(.spawnFailed) }
        let arguments = [executable.path, "--workspace", workspace]
        var copied: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        copied.append(nil)
        defer { copied.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = copied.withUnsafeMutableBufferPointer { buffer in
            executable.path.withCString { path in
                posix_spawn(&pid, path, &actions, &attributes, buffer.baseAddress, environ)
            }
        }
        guard spawned == 0, pid > 0 else { return .failure(.spawnFailed) }
        return .success(pid)
    }
}

public enum WorkspaceHosts {
    public static func inspect(project: String) -> WorkspaceAttachment {
        guard let directory = WorkspaceHostLocation.configurationDirectory() else {
            return .blocked(WorkspaceRecoveryBlock(workspace: nil, reason: .corrupt))
        }
        return WorkspaceDiscovery.inspect(project: project, configurationDirectory: directory)
    }

    /// Abandon the blocked workspace for this project, if one exists. Refusals
    /// leave the workspace untouched; only an explicit abandon call runs this.
    public static func abandon(project: String) -> WorkspaceAbandonOutcome {
        guard let configuration = WorkspaceHostLocation.configurationDirectory() else {
            return .refused(.configurationUnavailable)
        }
        guard let directory = WorkingDirectory(validating: project) else {
            return .refused(.unsafeReason(.corrupt))
        }
        return WorkspaceRecovery.abandon(
            directory,
            lifecycleLog: WorkspaceHostLocation.lifecycleLog(in: configuration),
            runtimeLog: WorkspaceHostLocation.runtimeLog(in: configuration)
        )
    }

    /// How long a host that published a live endpoint may leave it
    /// unanswered before `ensure` gives up. Mounting and recovery before the
    /// endpoint exists are bounded by `ensure`'s overall timeout instead. A
    /// host that publishes always gets this whole window, even past a
    /// shorter overall timeout.
    public static let readinessTimeout: TimeInterval = 15

    /// Writes a line for the user; the CLI default is stderr, the TUI's
    /// raw-mode reconnect passes a silent one.
    public typealias Report = @Sendable (String) -> Void

    public static let standardErrorReport: Report = { line in
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Starts a host when this project has none, or returns the live endpoint.
    /// A lost creation race attaches to the winner instead of mounting again.
    /// A failure stops the host this call spawned unless it was still
    /// mounting or recovering at the deadline (`.stillStarting`): that one
    /// keeps running in the background, recorded so `close` can stop it.
    public static func ensure(
        project: String,
        executable: URL,
        timeout: TimeInterval = 90,
        report: @escaping Report = standardErrorReport
    ) -> Result<WorkspaceEndpoint, WorkspaceHostFailure> {
        var seams = EnsureSeams()
        seams.report = report
        return ensure(
            project: project,
            executable: executable,
            timeout: timeout,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            seams: seams
        )
    }

    /// The process and connection effects `ensure` drives; tests replace them.
    struct EnsureSeams {
        var inspect: (String) -> WorkspaceAttachment = WorkspaceHosts.inspect
        /// Connect, describe, detach: whether the workspace is usable now.
        var probe: (WorkspaceEndpoint) -> Result<Bool, WorkspaceClientFailure> = WorkspaceHosts.probe
        var spawn: (URL, String) -> Result<pid_t, WorkspaceHostFailure> = WorkspaceHostLauncher.spawn
        /// Nil while the child runs; its wait status once reaped.
        var reap: (pid_t) -> Int32? = WorkspaceHosts.reap
        /// False when the child outlived SIGKILL's grace.
        var terminate: (pid_t) -> Bool = { WorkspaceHosts.terminateChild($0) }
        var report: (String) -> Void = WorkspaceHosts.standardErrorReport
        /// Remember the spawned host so `close` can stop it later.
        /// Arguments: pid, canonical path.
        var recordLaunch: (pid_t, String) -> Void = WorkspaceHostLaunchRecord.record
        /// The canonical project path an endpoint would carry; nil if unusable.
        var canonicalize: (String) -> String? = WorkspaceHostLaunchRecord.canonicalPath
        var now: () -> Date = Date.init
        var pause: () -> Void = { usleep(50_000) }
    }

    /// What `ensureLoop` learned about the host this call spawned.
    struct EnsureProgress {
        /// The unreaped child, or -1.
        var child: pid_t = -1
        /// The last state seen was `.starting` or `.recovering`.
        var lastSeenMounting = false
        var launchRecorded = false
    }

    static func ensure(
        project: String,
        executable: URL,
        timeout: TimeInterval = 90,
        homeDirectory: String,
        seams: EnsureSeams = EnsureSeams()
    ) -> Result<WorkspaceEndpoint, WorkspaceHostFailure> {
        var progress = EnsureProgress()
        let result = ensureLoop(
            project: project, executable: executable, timeout: timeout,
            homeDirectory: homeDirectory, seams: seams, progress: &progress
        )
        guard case .failure(let error) = result, progress.child > 0 else { return result }
        let child = progress.child
        if error == .timedOut, progress.lastSeenMounting {
            // Our child is unreaped, so its pid is still ours to record.
            if progress.launchRecorded == false, let canonical = seams.canonicalize(project) {
                seams.recordLaunch(child, canonical)
            }
            return .failure(.stillStarting)
        }
        guard stopsSpawnedHost(error) else { return result }
        if seams.terminate(child) == false {
            seams.report("rv: the workspace host this start launched (pid \(child)) did not exit after SIGKILL")
        }
        return error == .timedOut ? .failure(.timedOutAndStopped) : result
    }

    /// Failures that leave the spawned host running with nobody able to use
    /// it: refused by peer trust, silent after publishing, or not ready at
    /// the deadline in any state but mounting or recovering (which `ensure`
    /// turns into `.stillStarting` first). A recovery block or a refused
    /// start ends with the host exiting on its own.
    static func stopsSpawnedHost(_ error: WorkspaceHostFailure) -> Bool {
        switch error {
        case .notAnswering, .control(.unauthorizedClient), .timedOut:
            true
        default:
            false
        }
    }

    private static func ensureLoop(
        project: String,
        executable: URL,
        timeout: TimeInterval,
        homeDirectory: String,
        seams: EnsureSeams,
        progress: inout EnsureProgress
    ) -> Result<WorkspaceEndpoint, WorkspaceHostFailure> {
        let deadline = seams.now().addingTimeInterval(timeout)
        var spawned = false
        // The readiness clock belongs to one endpoint seen continuously live
        // and unanswered; any other state or a new endpoint restarts it.
        // While it runs it outlasts the overall deadline: the failed-probe
        // branch ends the loop as `.notAnswering` once it passes. It never
        // runs past `hardStop`, so endpoints that change on every poll
        // cannot keep re-arming it.
        let hardStop = deadline.addingTimeInterval(readinessTimeout)
        var answerDeadline: Date?
        var answerEndpoint: WorkspaceEndpoint?
        while seams.now() < deadline || answerDeadline != nil {
            let attachment = seams.inspect(project)
            switch attachment {
            case .starting, .recovering:
                progress.lastSeenMounting = true
            default:
                progress.lastSeenMounting = false
            }
            if case .live(let endpoint) = attachment, endpoint == answerEndpoint {
                // Same endpoint: keep its clock.
            } else {
                answerDeadline = nil
                answerEndpoint = nil
            }
            switch attachment {
            case .live(let endpoint):
                if progress.child > 0, progress.launchRecorded == false, endpoint.hostPID == progress.child {
                    seams.recordLaunch(progress.child, endpoint.canonicalPath)
                    progress.launchRecorded = true
                }
                switch seams.probe(endpoint) {
                case .success(true):
                    return .success(endpoint)
                case .success(false):
                    // A live endpoint with a closing workspace is not
                    // usable. Keep polling: the close retires the endpoint
                    // and this loop then starts (or attaches to) the next
                    // host. No new sleep; this is the existing poll loop.
                    // It answered, so its readiness clock starts over.
                    answerDeadline = nil
                    answerEndpoint = nil
                case .failure(.incompatibleProtocol):
                    // A live owner may still have active PTYs. Replacing it
                    // would destroy those runtimes, so require a deliberate
                    // compatible-host restart instead of retrying until timeout.
                    return .failure(.control(.incompatibleProtocol))
                case .failure(.unauthorizedClient):
                    // Code identity does not change between attempts: the
                    // host lacks the workspaceHost role (or refuses ours).
                    return .failure(.control(.unauthorizedClient))
                case .failure:
                    let limit = min(answerDeadline ?? seams.now().addingTimeInterval(readinessTimeout), hardStop)
                    answerDeadline = limit
                    answerEndpoint = endpoint
                    if seams.now() >= limit {
                        return .failure(.notAnswering)
                    }
                }
            case .blocked(let block):
                return .failure(.recoveryBlocked(block))
            case .unsupported:
                return .failure(.unsupported)
            case .absent:
                guard WorkspaceRootPolicy.isHomeDirectory(
                    project: project,
                    homeDirectory: homeDirectory
                ) == false else {
                    return .failure(.homeDirectory)
                }
                fallthrough
            case .orphaned:
                // Past the overall deadline (a readiness clock still
                // running) a vanished host is not replaced.
                if spawned == false, seams.now() < deadline {
                    switch seams.spawn(executable, project) {
                    case .failure(let error):
                        return .failure(error)
                    case .success(let pid):
                        progress.child = pid
                        spawned = true
                    }
                }
            case .starting, .recovering, .staleEndpoint:
                break
            }
            if progress.child > 0, let status = seams.reap(progress.child) {
                progress.child = -1
                let code = exitedCode(status)
                if code == WorkspaceHostExit.recoveryBlocked {
                    continue
                }
                if code == WorkspaceHostExit.liveOwner {
                    continue
                }
                if code != nil {
                    return .failure(.hostExited(code ?? 1))
                }
            }
            seams.pause()
        }
        return .failure(.timedOut)
    }

    static func probe(_ endpoint: WorkspaceEndpoint) -> Result<Bool, WorkspaceClientFailure> {
        switch WorkspaceClient.connect(endpoint) {
        case .failure(let error):
            return .failure(error)
        case .success(let client):
            let usable: Bool
            switch client.describe() {
            case .success(let description):
                usable = description.phase == .active
            case .failure:
                usable = false
            }
            _ = client.detach()
            return .success(usable)
        }
    }

    static func reap(_ child: pid_t) -> Int32? {
        var status: Int32 = 0
        return waitpid(child, &status, WNOHANG) == child ? status : nil
    }

    /// Grace before SIGKILL for a host this process spawned and stops.
    static let terminateGraceSeconds: TimeInterval = 2

    /// The kernel effects `terminateChild` drives; tests replace them.
    struct TerminateSeams {
        var signal: (pid_t, Int32) -> Void = { _ = kill($0, $1) }
        var reap: (pid_t) -> Int32? = WorkspaceHosts.reap
        var now: () -> Date = Date.init
        var pause: () -> Void = { usleep(50_000) }
        var grace: TimeInterval = WorkspaceHosts.terminateGraceSeconds
    }

    /// Stop and reap a host this process spawned. Unreaped, the pid cannot
    /// belong to anyone else, so signalling it is safe. The host keeps
    /// SIGTERM's default action; the next start recovers what it left.
    /// Both waits are bounded: false means the child outlived SIGKILL's
    /// grace (stuck in the kernel) and was left for the caller to report.
    @discardableResult
    static func terminateChild(_ child: pid_t, seams: TerminateSeams = TerminateSeams()) -> Bool {
        guard child > 0 else { return true }
        for signal in [SIGTERM, SIGKILL] {
            seams.signal(child, signal)
            let deadline = seams.now().addingTimeInterval(seams.grace)
            while true {
                if seams.reap(child) != nil { return true }
                if seams.now() >= deadline { break }
                seams.pause()
            }
        }
        return false
    }

    private static func exitedCode(_ status: Int32) -> Int32? {
        guard status & 0x7f == 0 else { return nil }
        return (status >> 8) & 0xff
    }
}
#endif
