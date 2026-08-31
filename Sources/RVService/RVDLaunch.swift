import RVDomain

public struct RVDConfiguration: Sendable, Equatable {
    public var idleExitSeconds: Int
    public var printVersion: Bool
}

public enum RVDLaunchError: Error, Sendable, Equatable {
    case socketUnsupported
    case invalidIdleExit
}

public enum RVDLaunch {
    public static let versionLine = ProductVersion.semver

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
