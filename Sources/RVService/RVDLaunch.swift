import RVDomain
import RVPolicy

public struct RVDConfiguration: Sendable, Equatable {
    public var idleExitSeconds: Int
    public var printVersion: Bool
}

public enum RVDLaunchError: Error, Sendable, Equatable {
    case socketUnsupported
    case invalidIdleExit
    /// No absolute HOME: no `~/.config/rv`, so no policy and no
    /// `audit.jsonl` to record overrides and owner approvals in.
    case homeRequired
}

public enum RVDLaunch {
    #if RV_TEST_OWNER_PRESENCE
    /// A test-owner-presence build says so wherever rvd names its version.
    public static let versionLine = ProductVersion.semver + " (\(TestOwnerPresence.marker) build)"
    #else
    public static let versionLine = ProductVersion.semver
    #endif

    /// rvd serves only with a home: without one it would gate with none of
    /// the owner's policy and could record no override or approval. macOS
    /// already needed HOME for its socket path; Linux did not.
    public static func requireHome(environment: [String: String]) throws {
        guard validatedHome(environment: environment) != nil else { throw RVDLaunchError.homeRequired }
    }

    /// `HOME` from `environment` when it is absolute and NUL-free (the
    /// check `HomeDirectory.processValidatedHome()` applies); nil otherwise.
    /// Pure: never reads the process environment.
    public static func validatedHome(environment: [String: String]) -> String? {
        guard let home = environment["HOME"], HomeDirectory.configRoot(for: home) != nil else { return nil }
        return home
    }

    public static func parse(arguments: [String]) throws -> RVDConfiguration {
        if arguments.contains(where: { $0 == "--socket" || $0.hasPrefix("--socket=") }) {
            #if os(Linux)
            // Linux production transport is a pathname socket under $XDG_RUNTIME_DIR.
            // The path after `--socket=` is ignored; there is no /tmp fallback.
            #else
            throw RVDLaunchError.socketUnsupported
            #endif
        }
        var idle = IdleWatchdog.defaultSeconds
        var printVersion = false
        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "--version" {
                printVersion = true
            } else if arg == "--idle-exit-seconds" {
                let next = index + 1
                guard next < arguments.count, let value = Int(arguments[next]), value > 0 else {
                    throw RVDLaunchError.invalidIdleExit
                }
                idle = value
                index = next
            } else if arg.hasPrefix("--idle-exit-seconds=") {
                let raw = String(arg.dropFirst("--idle-exit-seconds=".count))
                guard let value = Int(raw), value > 0 else {
                    throw RVDLaunchError.invalidIdleExit
                }
                idle = value
            }
            index += 1
        }
        return RVDConfiguration(idleExitSeconds: idle, printVersion: printVersion)
    }
}
