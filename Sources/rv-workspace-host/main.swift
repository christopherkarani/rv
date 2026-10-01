#if os(macOS) && !arch(arm64)
#error("rv v1 is Apple Silicon only")
#endif

import Foundation

#if os(macOS)
import Darwin
import RVIsolation
import RVService
#endif

@main
enum WorkspaceHostMain {
    #if os(macOS)
    /// The daemon owns its signal mask. `rv` spawns the host from a Swift
    /// cooperative thread, where SIGTERM/SIGINT arrive blocked, and
    /// `posix_spawn` inherits the spawner's mask. Without this reset the
    /// host ignores SIGTERM despite the default disposition, so kill-based
    /// supervision and crash recovery never trigger.
    private static func resetHostSignalMask() {
        var empty = sigset_t()
        sigemptyset(&empty)
        _ = pthread_sigmask(SIG_SETMASK, &empty, nil)
    }
    #endif

    static func main() {
        #if !os(macOS)
        FileHandle.standardError.write(
            Data("rv-workspace-host: contained workspace host is unavailable\n".utf8)
        )
        Foundation.exit(2)
        #else
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2,
            arguments[0] == "--workspace",
            arguments[1].isEmpty == false,
            arguments[1].contains("\0") == false
        else {
            FileHandle.standardError.write(
                Data("rv-workspace-host: usage: rv-workspace-host --workspace <path>\n".utf8)
            )
            Darwin.exit(WorkspaceHostExit.unsupported)
        }
        _ = setsid()
        // The creating terminal may close. A client disconnect must not kill the host.
        // SIGTERM and SIGINT keep the default terminate action so the lock drops
        // and the next start recovers.
        resetHostSignalMask()
        signal(SIGHUP, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        let principalBridge = WorkspaceHostBridgeClient()
        Darwin.exit(
            WorkspaceHostProcess.run(
                workspace: arguments[1],
                admission: HostRuntimeAdmission.configuration(bridge: principalBridge),
                principalBridge: { authority in
                    Task {
                        do { try await principalBridge.connect(authority) }
                        catch {
                            FileHandle.standardError.write(Data("rv-workspace-host: principal bridge unavailable\n".utf8))
                        }
                    }
                }
            )
        )
        #endif
    }
}
