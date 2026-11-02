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
    /// Injected so launchctl polling and retry backoff run instantly in tests.
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    /// The `rv-cli` binary running this setup (nil when unknown). Setup that
    /// touches the real supervisor must run from the installed bin dir.
    var runningExecutable: String? = nil

    /// Curl install copies `rv` (C hook), `rv-cli`, and `rvd`.
    /// Adapters bake `$HOME/.local/bin/rv`, not `rv-cli`. Do not walk PATH.
    static func resolveRv(home: String) -> String {
        home + "/.local/bin/rv"
    }

    /// The hook client `rv` only trusts the `rvd` beside it, so the service
    /// must run that exact binary: `$HOME/.local/bin/rvd`, never the `rvd`
    /// beside whichever `rv-cli` happens to run setup (e.g. `.build/`).
    static func resolveRvd(home: String) -> String {
        (resolveRv(home: home) as NSString).deletingLastPathComponent + "/rvd"
    }
}
