import Foundation

protocol LaunchctlApplying {
    func bootstrap(domain: String, plist: URL) throws
    func bootout(domain: String, label: String) throws
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
