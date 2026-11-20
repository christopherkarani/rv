#if os(macOS) && !arch(arm64)
#error("rv v1 is Apple Silicon only")
#endif

import Foundation
import RVService

@main
enum RVD {
    static let homeRequired =
        "rvd: HOME is required, as an absolute path (rvd keeps its policy and audit log in ~/.config/rv)\n"

    static func main() {
        // A write to a closed stdout or stderr pipe fails with EPIPE instead
        // of killing rvd. On Darwin this is per open file, so the children
        // rvd spawns keep SIGPIPE at its default; a closed descriptor
        // (EBADF) cannot raise SIGPIPE, so the result is ignored. Linux has
        // no per-file flag: ignore SIGPIPE process-wide. systemd already did
        // for its unit; a direct start (DirectRvd) gives rvd the default.
        // Sockets and helper pipes already expect EPIPE.
        #if canImport(Darwin)
        _ = fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1)
        _ = fcntl(STDERR_FILENO, F_SETNOSIGPIPE, 1)
        #else
        signal(SIGPIPE, SIG_IGN)
        #endif
        // launchd hands rvd /dev/null; keep failures visible in the log
        // (a regular file, which cannot raise SIGPIPE).
        RVDLogFile.captureDiscardedStderr()
        do {
            let configuration = try RVDLaunch.parse(arguments: ProcessInfo.processInfo.arguments)
            if configuration.printVersion {
                do {
                    try FileHandle.standardOutput.write(contentsOf: Data((RVDLaunch.versionLine + "\n").utf8))
                } catch {
                    Foundation.exit(1)
                }
                return
            }
            try RVDProcess.run(configuration: configuration)
        } catch RVDLaunchError.socketUnsupported {
            try? FileHandle.standardError.write(contentsOf:
                Data("rvd: production transport is XPC; --socket is not supported\n".utf8)
            )
            Foundation.exit(2)
        } catch RVDLaunchError.homeRequired {
            try? FileHandle.standardError.write(contentsOf: Data(homeRequired.utf8))
            exitOnConfigurationError()
        } catch UnixSocketPathError.runtimeDirectoryMissing {
            #if os(Linux)
            let message = "rvd: XDG_RUNTIME_DIR is set but empty; unset it (rvd then uses /run/user/\(getuid())) "
                + "or set it to a directory only you can access\n"
            #else
            // macOS: the socket path is under HOME, so this is the same refusal.
            let message = homeRequired
            #endif
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            exitOnConfigurationError()
        } catch UnixSocketPathError.userRuntimeDirectoryUnavailable(let directory) {
            // No login manager made the runtime directory (containers, WSL,
            // logins without logind) and rvd could not make it either.
            let message = "rvd: XDG_RUNTIME_DIR is unset and \(directory) is missing, could not be created, "
                + "or is not a directory only you can access (yours, mode 0700)\n"
                + "rvd: fix: as root, mkdir -p -m 0700 \(directory) && chown \(getuid()) \(directory); "
                + "or set XDG_RUNTIME_DIR to a directory only you can access, for rvd and for your agents\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            exitOnConfigurationError()
        } catch UnixSocketPathError.permission {
            let socket = (try? UnixSocketPath.production())?.path ?? "the socket path"
            let message = "rvd: refusing to listen at \(socket): the directories above it must be yours "
                + "and not writable by group or others, and only a socket may sit at that path\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            exitOnConfigurationError()
        } catch {
            try? FileHandle.standardError.write(contentsOf:
                Data(RVDLogFile.line("rvd: launch failed: \(RVDLogFile.describe(error))").utf8)
            )
            Foundation.exit(1)
        }
    }

    /// These errors fail the same way on every start until the owner fixes
    /// the configuration. Under launchd or systemd, which relaunch rvd at
    /// once, wait first so the loop runs once a minute, not every few
    /// seconds. Run by hand, exit at once.
    static func exitOnConfigurationError() -> Never {
        if StartupBackoff.isSupervised(environment: ProcessInfo.processInfo.environment) {
            Thread.sleep(forTimeInterval: Double(StartupBackoff.configErrorPause.components.seconds))
        }
        Foundation.exit(1)
    }
}
