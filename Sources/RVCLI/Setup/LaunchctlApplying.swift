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
    /// Whether `launchctl print <domain>` succeeds. `gui/<uid>` is absent in
    /// SSH / Background sessions with no Aqua login.
    func domainExists(_ domain: String) -> Bool
    /// `launchctl kickstart -k <domain>/<label>`: kill and restart the job.
    func kickstart(domain: String, label: String) throws
    /// Whether this process runs in the Aqua (desktop) session, whose Mach
    /// namespace reaches jobs in `gui/<uid>`. An SSH login is Background.
    func sessionIsAqua() -> Bool
    /// What `launchctl print <domain>/<label>` says about the job's process.
    /// Works from SSH, where rvd's Mach service is out of reach.
    func jobProcess(domain: String, label: String) -> LaunchdJobProcess
}

enum LaunchdJobProcess: Equatable {
    case running(pid: Int32)
    case notRunning
    /// `launchctl print` failed or said neither.
    case unknown

    /// Parses `launchctl print` output: the job's own `state` and `pid`
    /// lines are indented by one tab; nested sections use more.
    static func parse(_ output: String) -> LaunchdJobProcess {
        var state: String?
        var pid: Int32?
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("\t"), line.dropFirst().hasPrefix("\t") == false else { continue }
            let field = line.dropFirst()
            if field.hasPrefix("state = ") {
                state = String(field.dropFirst("state = ".count))
            } else if field.hasPrefix("pid = ") {
                pid = Int32(field.dropFirst("pid = ".count))
            }
        }
        switch state {
        case "running":
            guard let pid, pid > 0 else { return .unknown }
            return .running(pid: pid)
        case .some:
            return .notRunning
        case nil:
            return .unknown
        }
    }
}

extension LaunchctlApplying {
    func isLoaded(domain _: String, label _: String) -> Bool { false }
    func domainExists(_: String) -> Bool { true }
    func kickstart(domain _: String, label _: String) throws {}
    func sessionIsAqua() -> Bool { true }
    func jobProcess(domain _: String, label _: String) -> LaunchdJobProcess { .unknown }
}

enum LaunchctlError: Error, Equatable {
    case nonZeroExit(Int32)
}

/// `posix_spawn` returns ETXTBSY when a just-written script is still open for
/// write. The process did not start, so the same `Process` can be launched again.
func runExecutable(_ process: Process) throws {
    for _ in 0..<50 {
        do {
            try process.run()
            return
        } catch {
            guard isTextFileBusy(error) else { throw error }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }
    try process.run()
}

private func isTextFileBusy(_ error: Error) -> Bool {
    let ns = error as NSError
    guard ns.domain == NSCocoaErrorDomain,
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
        underlying.domain == NSPOSIXErrorDomain
    else { return false }
    return underlying.code == Int(POSIXErrorCode.ETXTBSY.rawValue)
}

struct ProcessLaunchctl: LaunchctlApplying {
    var executableURL: URL

    init(executableURL: URL = URL(fileURLWithPath: "/bin/launchctl")) {
        self.executableURL = executableURL
    }

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

    func domainExists(_ domain: String) -> Bool {
        do {
            try run(["print", domain])
            return true
        } catch {
            return false
        }
    }

    func kickstart(domain: String, label: String) throws {
        try run(["kickstart", "-k", "\(domain)/\(label)"])
    }

    /// `launchctl managername` prints `Aqua` in a desktop session and
    /// `Background` over SSH. Anything else counts as Aqua, so a failed
    /// probe only keeps the readiness check (and its failure) as before.
    func sessionIsAqua() -> Bool {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["managername"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? runExecutable(process)) != nil else { return true }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let name = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return name != "Background"
    }

    func jobProcess(domain: String, label: String) -> LaunchdJobProcess {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["print", "\(domain)/\(label)"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? runExecutable(process)) != nil else { return .unknown }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return .unknown }
        return LaunchdJobProcess.parse(String(decoding: data, as: UTF8.self))
    }

    private func run(_ arguments: [String], okStatuses: Set<Int32> = [0]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try runExecutable(process)
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
