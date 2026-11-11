#if os(macOS) && !arch(arm64)
#error("rv v1 is Apple Silicon only")
#endif

import Foundation
import RVService

@main
enum RVD {
    static func main() {
        // launchd hands rvd /dev/null; keep failures visible in the log.
        RVDLogFile.captureDiscardedStderr()
        do {
            let configuration = try RVDLaunch.parse(arguments: ProcessInfo.processInfo.arguments)
            if configuration.printVersion {
                FileHandle.standardOutput.write(Data((RVDLaunch.versionLine + "\n").utf8))
                return
            }
            try RVDProcess.run(configuration: configuration)
        } catch RVDLaunchError.socketUnsupported {
            FileHandle.standardError.write(
                Data("rvd: production transport is XPC; --socket is not supported\n".utf8)
            )
            Foundation.exit(2)
        } catch UnixSocketPathError.runtimeDirectoryMissing {
            #if os(Linux)
            let message = "rvd: XDG_RUNTIME_DIR is set but empty; unset it (rvd then uses /run/user/\(getuid())) "
                + "or set it to a directory only you can access\n"
            #else
            let message = "rvd: HOME is required\n"
            #endif
            FileHandle.standardError.write(Data(message.utf8))
            Foundation.exit(1)
        } catch UnixSocketPathError.userRuntimeDirectoryUnavailable(let directory) {
            // No login manager made the runtime directory (containers, WSL,
            // logins without logind) and rvd could not make it either.
            let message = "rvd: XDG_RUNTIME_DIR is unset and \(directory) is missing, could not be created, "
                + "or is not a directory only you can access (yours, mode 0700)\n"
                + "rvd: fix: as root, mkdir -p -m 0700 \(directory) && chown \(getuid()) \(directory); "
                + "or set XDG_RUNTIME_DIR to a directory only you can access, for rvd and for your agents\n"
            FileHandle.standardError.write(Data(message.utf8))
            Foundation.exit(1)
        } catch UnixSocketPathError.permission {
            let socket = (try? UnixSocketPath.production())?.path ?? "the socket path"
            let message = "rvd: refusing to listen at \(socket): the directories above it must be yours "
                + "and not writable by group or others, and only a socket may sit at that path\n"
            FileHandle.standardError.write(Data(message.utf8))
            Foundation.exit(1)
        } catch {
            FileHandle.standardError.write(
                Data(RVDLogFile.line("rvd: launch failed: \(RVDLogFile.describe(error))").utf8)
            )
            Foundation.exit(1)
        }
    }
}
