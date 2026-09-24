#if os(macOS)
import Darwin
import Foundation
import RVDomain

/// `rvd` is the user-wide hook and policy service. It idle-exits and does not
/// own a workspace volume, owner lock, or runtime process group. A workspace
/// host is a separate process whose lifetime is one `WorkspaceSession`.
public enum WorkspaceHostProcess {
    public static func run(workspace: String) -> Int32 {
        guard workspace.contains("\0") == false,
            let directory = WorkingDirectory(validating: workspace),
            let configuration = WorkspaceHostLocation.configurationDirectory()
        else {
            complain("workspace host failed")
            return WorkspaceHostExit.failed
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
            sessionStore: .file(runtime)
        ) {
        case .failure:
            _ = supervisor.close()
            complain("workspace host failed")
            return WorkspaceHostExit.failed
        case .success(let server):
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

    /// Starts a host when this project has none, or returns the live endpoint.
    /// A lost creation race attaches to the winner instead of mounting again.
    public static func ensure(
        project: String,
        executable: URL,
        timeout: TimeInterval = 90
    ) -> Result<WorkspaceEndpoint, WorkspaceHostFailure> {
        ensure(
            project: project,
            executable: executable,
            timeout: timeout,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    static func ensure(
        project: String,
        executable: URL,
        timeout: TimeInterval = 90,
        homeDirectory: String
    ) -> Result<WorkspaceEndpoint, WorkspaceHostFailure> {
        let deadline = Date().addingTimeInterval(timeout)
        var child: pid_t = -1
        var spawned = false
        while Date() < deadline {
            switch inspect(project: project) {
            case .live(let endpoint):
                switch WorkspaceClient.connect(endpoint) {
                case .success(let client):
                    _ = client.detach()
                    return .success(endpoint)
                case .failure:
                    break
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
                if spawned == false {
                    switch WorkspaceHostLauncher.spawn(executable: executable, workspace: project) {
                    case .failure(let error):
                        return .failure(error)
                    case .success(let pid):
                        child = pid
                        spawned = true
                    }
                }
            case .starting, .recovering, .staleEndpoint:
                break
            }
            if child > 0 {
                var status: Int32 = 0
                let waited = waitpid(child, &status, WNOHANG)
                if waited == child {
                    child = -1
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
            }
            usleep(50_000)
        }
        return .failure(.timedOut)
    }

    private static func exitedCode(_ status: Int32) -> Int32? {
        guard status & 0x7f == 0 else { return nil }
        return (status >> 8) & 0xff
    }
}
#endif
