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
import RVService

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
    /// True while an organization gate pins enforce. Injected so the
    /// managed-gate paths of `rv setup` / `rv host mode` are provable
    /// without a root-owned bundle.
    var managedEnforce: (HomeDirectory) -> Bool = { ManagedGate.pinsEnforce(home: $0) }
    /// Would hooks trust the `rvd` at a path? Nil skips the check (tests,
    /// Linux). Live: `DaemonTrustProbe.live`.
    var daemonTrust: (String) -> DoctorServiceTrust? = { _ in nil }
    /// Bounded wait for rvd to answer a health round-trip once the service
    /// is started. Setup wires no hook until it returns true. Blocking.
    /// Default true for isolated test HOMEs; live: `ServiceReadiness.live`.
    var serviceAnswers: () -> Bool = { true }
    /// One immediate health round-trip, no wait: does a trusted rvd answer
    /// right now? Default false; live: `ServiceReadiness.liveOnce`.
    var serviceAnswersNow: () -> Bool = { false }
    /// Starts and stops an unsupervised rvd when Linux has no systemd user
    /// manager. Default touches no process; live: `ProcessDirectRvd`.
    var directRvd: any DirectRvdLaunching = SilentDirectRvd()
    /// The absolute path of a runnable interpreter (`python3`), baked into
    /// the hook command; nil when none runs. Setup will not wire a host
    /// whose hook command needs one that does not. Default
    /// `/usr/bin/<name>` for tests; live: `AdapterRuntime.resolveRunnable`
    /// on this PATH.
    var resolveInterpreter: (String) -> String? = { "/usr/bin/" + $0 }

    /// This run loads the real launchd/systemd service, so it can (and
    /// must) prove rvd answers before wiring hooks.
    var managesService: Bool { touchLaunchd || touchSystemd }

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
