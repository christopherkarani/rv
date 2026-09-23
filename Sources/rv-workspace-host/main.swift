#if os(macOS) && !arch(arm64)
#error("rv v1 is Apple Silicon only")
#endif

import Foundation

#if os(macOS)
import Darwin
import RVIsolation
#endif

@main
enum WorkspaceHostMain {
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
        signal(SIGHUP, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        Darwin.exit(WorkspaceHostProcess.run(workspace: arguments[1]))
        #endif
    }
}
