import Foundation

protocol SystemctlApplying {
    func enableNow(unit: String) throws
    func disableNow(unit: String) throws
    /// `systemctl --user restart`; with `onlyIfStopped`, `systemctl --user start`.
    func restart(unit: String, onlyIfStopped: Bool) throws
    /// A systemd user manager answers `systemctl --user`. False with no
    /// systemctl, no user bus or no logind session (WSL without systemd,
    /// containers, OpenRC/runit).
    func userManagerReachable() -> Bool
}

enum SystemctlError: Error, Equatable {
    case nonZeroExit(Int32)
}

enum SystemctlAction: Equatable {
    case enable
    case disable
    case restart
}

struct ProcessSystemctl: SystemctlApplying {
    /// Merged-/usr distros ship `/usr/bin/systemctl`; others keep `/bin`.
    static let candidates = ["/usr/bin/systemctl", "/bin/systemctl"]

    var executableURL: URL

    init(executableURL: URL? = nil) {
        self.executableURL = executableURL ?? Self.locate()
    }

    /// The first candidate that is an executable file; the first candidate
    /// otherwise, which then fails to run (no systemctl means no user
    /// manager).
    static func locate(
        candidates: [String] = candidates,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL {
        URL(fileURLWithPath: candidates.first(where: isExecutable) ?? candidates[0])
    }

    func enableNow(unit: String) throws {
        try run(["daemon-reload"])
        try run(["enable", "--now", unit])
    }

    func disableNow(unit: String) throws {
        try run(
            ["disable", "--now", unit],
            okStatuses: [0, 1, 5]
        )
        try run(["daemon-reload"], okStatuses: [0, 1, 5])
    }

    func restart(unit: String, onlyIfStopped: Bool) throws {
        try run([onlyIfStopped ? "start" : "restart", unit])
    }

    func userManagerReachable() -> Bool {
        (try? run(["show-environment"])) != nil
    }

    private func run(_ arguments: [String], okStatuses: Set<Int32> = [0]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--user"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try runExecutable(process)
        process.waitUntilExit()
        let status = process.terminationStatus
        guard okStatuses.contains(status) else {
            throw SystemctlError.nonZeroExit(status)
        }
    }
}

struct SilentSystemctl: SystemctlApplying {
    func enableNow(unit _: String) throws {}
    func disableNow(unit _: String) throws {}
    func restart(unit _: String, onlyIfStopped _: Bool) throws {}
    func userManagerReachable() -> Bool { true }
}
