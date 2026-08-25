import Foundation

enum LaunchAgentProbe {
    static func isLoaded(label: String, userID: uid_t = getuid()) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", LaunchdDomain.agentPrintTarget(uid: userID, label: label)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
