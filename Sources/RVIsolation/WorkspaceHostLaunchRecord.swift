#if os(macOS)
import Darwin
import Foundation
import RVDomain

/// The host `WorkspaceHosts.ensure` spawned for a project, as the kernel
/// saw it right after the spawn. The start time is what a reused pid
/// changes, so `close` never signals a process that merely inherited it.
struct WorkspaceHostLaunch: Codable, Equatable, Sendable {
    static let version = 1

    var v: Int
    var pid: Int32
    var startSeconds: UInt64
    var startMicroseconds: UInt64
}

/// What `rv workspace close` did about a host that would not answer.
public enum WorkspaceHostStop: Equatable, Sendable {
    /// No host this rv launched is on record for the project.
    case noRecord
    /// The recorded host has already exited (its pid is gone or reused).
    case notRunning
    /// The recorded pid could not be proven to be rv's workspace host, so
    /// it was left alone. The text says why.
    case leftAlone(String)
    case stopped(Int32)
    /// SIGTERM and SIGKILL were sent but the process is still there.
    case stillRunning(Int32)
}

/// Records and stops hosts `ensure` launched. A host that never answers
/// (for example one the peer-trust manifest does not recognise) cannot be
/// closed over its socket; this is the only other way to stop it.
public enum WorkspaceHostLaunchRecord {
    static func file(in configurationDirectory: URL, canonicalPath: String) -> URL {
        configurationDirectory
            .appendingPathComponent(WorkspaceHostLocation.directoryName, isDirectory: true)
            .appendingPathComponent(WorkspaceHostLocation.digest(canonicalPath) + ".launch")
            .appendingPathExtension("json")
    }

    /// Best effort: a host without a record is simply not stoppable by close.
    static func record(pid: pid_t, project: String) {
        guard let configuration = WorkspaceHostLocation.configurationDirectory(),
              let directory = WorkingDirectory(validating: project),
              case .success(let canonical) = existingResolvedWorkspacePath(directory),
              case .found(let identity) = LibprocProcessTable().lookup(pid) else { return }
        let launch = WorkspaceHostLaunch(
            v: WorkspaceHostLaunch.version, pid: pid,
            startSeconds: identity.startSeconds, startMicroseconds: identity.startMicroseconds
        )
        guard let data = try? JSONEncoder().encode(launch) else { return }
        _ = WorkspaceEndpointStore.writeOwnerFile(data, to: file(in: configuration, canonicalPath: canonical))
    }

    static func load(from url: URL) -> WorkspaceHostLaunch? {
        guard let data = try? Data(contentsOf: url), data.count <= 4_096,
              let launch = try? JSONDecoder().decode(WorkspaceHostLaunch.self, from: data),
              launch.v == WorkspaceHostLaunch.version, launch.pid > 1 else { return nil }
        return launch
    }

    /// Stop the host rv launched for `canonicalPath` when it is still the
    /// same process and runs `installedHost`. The record is dropped once
    /// that host is gone.
    public static func stopUnanswered(canonicalPath: String, installedHost: URL) -> WorkspaceHostStop {
        guard let configuration = WorkspaceHostLocation.configurationDirectory() else { return .noRecord }
        let url = file(in: configuration, canonicalPath: canonicalPath)
        let outcome = stop(load(from: url), installedHost: installedHost.path, seams: StopSeams())
        switch outcome {
        case .stopped, .notRunning:
            _ = url.path.withCString { unlink($0) }
        case .noRecord, .leftAlone, .stillRunning:
            break
        }
        return outcome
    }

    struct StopSeams {
        var lookup: (pid_t) -> ProcessLookup = { LibprocProcessTable().lookup($0) }
        var executable: (pid_t) -> String? = { pid in
            if case .path(let path) = LibprocProcessTable().executable(pid) { return path }
            return nil
        }
        var resolve: (String) -> String? = posixRealpath
        var signal: (pid_t, Int32) -> Void = { _ = kill($0, $1) }
        var now: () -> Date = Date.init
        var pause: () -> Void = { usleep(50_000) }
        var grace: TimeInterval = WorkspaceHosts.terminateGraceSeconds
    }

    static func stop(_ launch: WorkspaceHostLaunch?, installedHost: String, seams: StopSeams) -> WorkspaceHostStop {
        guard let launch else { return .noRecord }
        let pid = pid_t(launch.pid)
        func isRecorded() -> Bool? {
            switch seams.lookup(pid) {
            case .found(let identity):
                identity.startSeconds == launch.startSeconds
                    && identity.startMicroseconds == launch.startMicroseconds
            case .absent:
                false
            case .unavailable:
                nil
            }
        }
        switch isRecorded() {
        case .none:
            return .leftAlone("could not read process \(pid)")
        case .some(false):
            return .notRunning
        case .some(true):
            break
        }
        guard let running = seams.executable(pid).flatMap(seams.resolve),
              let expected = seams.resolve(installedHost) else {
            return .leftAlone("could not confirm what process \(pid) runs")
        }
        guard running == expected else {
            return .leftAlone("process \(pid) runs \(running), not \(expected)")
        }
        func waitGone() -> Bool {
            let deadline = seams.now().addingTimeInterval(seams.grace)
            while true {
                if isRecorded() == false { return true }
                if seams.now() >= deadline { return false }
                seams.pause()
            }
        }
        seams.signal(pid, SIGTERM)
        if waitGone() { return .stopped(launch.pid) }
        // Re-prove identity before the uncatchable signal.
        guard isRecorded() == true else { return .stopped(launch.pid) }
        seams.signal(pid, SIGKILL)
        return waitGone() ? .stopped(launch.pid) : .stillRunning(launch.pid)
    }
}
#endif
