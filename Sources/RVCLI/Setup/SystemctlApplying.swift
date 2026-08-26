import Foundation

protocol SystemctlApplying {
    func enableNow(unit: String) throws
    func disableNow(unit: String) throws
}

enum SystemctlError: Error, Equatable {
    case nonZeroExit(Int32)
}

enum SystemctlAction: Equatable {
    case enable
    case disable
}

struct ProcessSystemctl: SystemctlApplying {
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

    private func run(_ arguments: [String], okStatuses: Set<Int32> = [0]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/systemctl")
        process.arguments = ["--user"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
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
}
