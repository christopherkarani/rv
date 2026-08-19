import Foundation

protocol LaunchctlApplying {
    func bootstrap(domain: String, plist: URL) throws
    func bootout(domain: String, label: String) throws
}

struct ProcessLaunchctl: LaunchctlApplying {
    func bootstrap(domain: String, plist: URL) throws {
        try run(["bootstrap", domain, plist.path])
    }

    func bootout(domain: String, label: String) throws {
        try run(["bootout", "\(domain)/\(label)"])
    }

    private func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
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
