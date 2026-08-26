#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Aqua/GUI session domain. Hosts (Pi, Grok, OpenCode) run here — not `user/<uid>`.
enum LaunchdDomain {
    static func gui(_ uid: uid_t) -> String { "gui/\(uid)" }
    static func user(_ uid: uid_t) -> String { "user/\(uid)" }

    /// Unload leftovers in `user/` before `gui/` so a stale Mach name cannot block Aqua.
    static func bootoutOrder(uid: uid_t) -> [String] { [user(uid), gui(uid)] }

    /// Prefer `gui/` so Aqua hosts resolve the Mach service; `user/` is the no-Aqua fallback.
    static func bootstrapOrder(uid: uid_t) -> [String] { [gui(uid), user(uid)] }

    /// `launchctl print` target for the live agent (gui session).
    static func agentPrintTarget(uid: uid_t, label: String) -> String {
        "\(gui(uid))/\(label)"
    }
}

protocol LaunchctlApplying {
    func bootstrap(domain: String, plist: URL) throws
    func bootout(domain: String, label: String) throws
    func isLoaded(domain: String, label: String) -> Bool
}

extension LaunchctlApplying {
    func isLoaded(domain _: String, label _: String) -> Bool { false }
}

enum LaunchctlError: Error, Equatable {
    case nonZeroExit(Int32)
}

struct ProcessLaunchctl: LaunchctlApplying {
    func bootstrap(domain: String, plist: URL) throws {
        try run(["bootstrap", domain, plist.path])
    }

    func bootout(domain: String, label: String) throws {
        // Already unloaded is success for idempotent uninstall / re-bootstrap.
        try run(
            ["bootout", "\(domain)/\(label)"],
            okStatuses: [0, 3, 5, 113]
        )
    }

    func isLoaded(domain: String, label: String) -> Bool {
        do {
            try run(["print", "\(domain)/\(label)"])
            return true
        } catch {
            return false
        }
    }

    private func run(_ arguments: [String], okStatuses: Set<Int32> = [0]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let status = process.terminationStatus
        guard okStatuses.contains(status) else {
            throw LaunchctlError.nonZeroExit(status)
        }
    }
}

enum LoginHome {
    static func path() -> String? {
        guard let password = getpwuid(getuid()) else { return nil }
        return String(cString: password.pointee.pw_dir)
    }

    static func matchesProcessHome(_ home: String) -> Bool {
        guard let login = path() else { return false }
        return (home as NSString).standardizingPath == (login as NSString).standardizingPath
    }
}
