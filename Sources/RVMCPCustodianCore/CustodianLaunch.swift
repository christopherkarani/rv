import RVDomain

public struct CustodianConfiguration: Sendable, Equatable {
    public var idleExitSeconds: Int
    public var printVersion: Bool
}

public enum CustodianLaunchError: Error, Sendable, Equatable {
    case invalidIdleExit
}

/// Argument parsing mirroring `RVDLaunch`: `--version` and
/// `--idle-exit-seconds`, nothing else. Unknown arguments are ignored,
/// as launchd may add its own.
public enum CustodianLaunch {
    public static let versionLine = ProductVersion.semver

    public static func parse(arguments: [String]) throws -> CustodianConfiguration {
        var idle = CustodianIdleWatchdog.defaultSeconds
        var printVersion = false
        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "--version" {
                printVersion = true
            } else if arg == "--idle-exit-seconds" {
                let next = index + 1
                guard next < arguments.count, let value = Int(arguments[next]), value > 0 else {
                    throw CustodianLaunchError.invalidIdleExit
                }
                idle = value
                index = next
            } else if arg.hasPrefix("--idle-exit-seconds=") {
                let raw = String(arg.dropFirst("--idle-exit-seconds=".count))
                guard let value = Int(raw), value > 0 else {
                    throw CustodianLaunchError.invalidIdleExit
                }
                idle = value
            }
            index += 1
        }
        return CustodianConfiguration(idleExitSeconds: idle, printVersion: printVersion)
    }
}
