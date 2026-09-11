#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVAnalytics
import RVDomain
import RVHooks
import RVPolicy
import RVPresentation

struct SetupOutcome: Equatable, Sendable {
    var stdout: String
    var stderr: String
    var exitCode: Int32
    /// Pretty ceremony already wrote to the live sink; caller must not reprint `stdout`.
    var emitted: Bool

    init(stdout: String, stderr: String = "", exitCode: Int32, emitted: Bool = false) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.emitted = emitted
    }

    static let ok = SetupOutcome(stdout: "", exitCode: 0)
}

extension HookHost {
    func adapterResource() throws -> HostAdapterResource {
        try HostAdapterResources.load(for: self)
    }
}

struct SetupEnvironment {
    var home: HomeDirectory
    var pathEntries: [String]
    var rvPath: String
    var rvdPath: String
    var fileManager: FileManager
    var launchctl: any LaunchctlApplying
    var systemctl: any SystemctlApplying
    var touchLaunchd: Bool
    var touchSystemd: Bool
    var supervisor: EvaluateSupervisor
    var installAnalytics: any InstallAnalyticsCapturing
    /// Injected so launchd domains are provable without the real uid.
    var uid: () -> uid_t = { getuid() }
    var companionPresence: any CompanionPresenceDetecting = FixedCompanionPresence(value: .absent)

    /// Curl install copies `rv` (C hook), `rv-cli`, and `rvd`.
    /// Adapters bake `$HOME/.local/bin/rv`, not `rv-cli`. Do not walk PATH.
    static func resolveRv(home: String) -> String {
        home + "/.local/bin/rv"
    }

    /// Prefer `rvd` next to the running `rv` / `rv-cli`, then `$HOME/.local/bin/rvd`.
    static func resolveRvd(
        nextTo rvExecutable: String?,
        home: String,
        fileManager: FileManager = .default
    ) -> String? {
        if let rvExecutable {
            let sibling = (rvExecutable as NSString).deletingLastPathComponent + "/rvd"
            if fileManager.isExecutableFile(atPath: sibling) {
                return sibling
            }
        }
        let local = home + "/.local/bin/rvd"
        if fileManager.isExecutableFile(atPath: local) {
            return local
        }
        return nil
    }
}

