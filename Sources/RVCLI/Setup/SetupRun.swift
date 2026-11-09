#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVAnalytics
import RVDomain
import RVHistory
import RVHooks
import RVPolicy
import RVPresentation
import RVService

/// What setup does with the machine-wide `guard.mode`.
enum SetupGuardRequest: Equatable {
    /// Plain `rv setup`: `guard.mode` is never touched.
    case keep
    /// `rv setup --observe`. `ownerAuthenticated` records whether the owner
    /// was checked; it must be true when `observeShedsOversight` holds.
    case observe(ownerAuthenticated: Bool)
}

enum SetupRun {
    static let launchAgentLabel = "dev.rv.evaluate"
    static let custodianLaunchAgentLabel = "dev.rv.mcp-custodian"
    /// One-line repair when installed binaries (rvd, pack bundle) are missing.
    static let reinstallHint = "reinstall rv (curl -fsSL https://rykanv.com/install | sh)"

    static func setup(
        _ env: SetupEnvironment,
        appearance: CLIAppearance = .robot,
        ceremonyKind: SetupCeremonyKind = .setup,
        force: Bool = false,
        guardRequest: SetupGuardRequest = .keep,
        clock: any SetupCeremonyClock = ZeroSetupCeremonyClock(),
        animate: Bool = false,
        write: ((String) -> Void)? = nil
    ) -> SetupOutcome {
        do {
            let report = try perform(env, force: force, guardRequest: guardRequest)
            let formatted = SetupFormat.stdout(
                report: report,
                appearance: appearance,
                ceremonyKind: ceremonyKind,
                clock: clock,
                animate: animate,
                write: write
            )
            return SetupOutcome(
                stdout: formatted.text,
                stderr: observeNotice(guardRequest, env: env) + serviceWarning(report),
                exitCode: 0,
                emitted: formatted.emitted
            )
        } catch {
            return failureOutcome(error, command: .setup)
        }
    }

    /// Hooks wired with no service behind them deny every tool call; say so.
    private static func serviceWarning(_ report: SetupReport) -> String {
        guard let missing = report.serviceSkippedMissingRvd else { return "" }
        return """
            rv setup: rvd not found at \(missing); the service was not installed, so hooks will deny tool calls
            fix: \(reinstallHint)

            """
    }

    /// Confirms observe mode and names hosts whose stored `block` entry
    /// still outranks it.
    private static func observeNotice(_ request: SetupGuardRequest, env: SetupEnvironment) -> String {
        guard case .observe = request else { return "" }
        let pinned = hostModeStore(env).load()
            .filter { $0.value == .block }
            .keys.map(\.rawValue).sorted()
        var line = "rv setup: observe mode on: rv logs what it would block instead of blocking (rv blocks lists them)"
        for host in pinned {
            line += "; \(host) stays block (rv host mode \(host) observe to change)"
        }
        return line + "\n"
    }

    /// True when `--observe` would shed oversight: the configured
    /// machine-wide mode (never `RV_GUARD_MODE`) is enforce and some host
    /// is wired. A fresh install only adds oversight. Throws
    /// `observePinnedByOrganization` under an organization gate.
    static func observeShedsOversight(_ env: SetupEnvironment) throws(SetupError) -> Bool {
        if env.managedEnforce(env.home) { throw .observePinnedByOrganization }
        guard JudgeRuntime.configuredGuardMode(home: env.home) == .enforce else { return false }
        let installations = try inspectInstallations(layout: OwnedPaths(home: env.home), env: env)
        return HookHost.allCases.contains { installations.state(for: $0) == .wired }
    }

    /// Stores `guard.mode: observe` before any hook is attached, after the
    /// owner check when the change sheds oversight.
    private static func applyGuardRequest(_ request: SetupGuardRequest, env: SetupEnvironment) throws(SetupError) {
        guard case .observe(let ownerAuthenticated) = request else { return }
        if try observeShedsOversight(env), ownerAuthenticated == false {
            throw .ownerAuthenticationRequired
        }
        do {
            try hostModeStore(env).saveGlobalObserve()
        } catch {
            throw .guardModeWriteFailed
        }
    }

    private static func hostModeStore(_ env: SetupEnvironment) -> HostModeStore {
        HostModeStore(configDirectory: RVPolicyPaths.configDirectory(home: env.home))
    }

    /// Setup that loads the real supervisor must run from the hook's bin dir:
    /// the plist names `rvd` there, and a different build's `rv-cli` would
    /// wire hooks for binaries that were never installed.
    static func requireInstalledCopy(_ env: SetupEnvironment) throws(SetupError) {
        guard env.touchLaunchd || env.touchSystemd, let running = env.runningExecutable else { return }
        let runningDirectory = canonicalDirectory(of: running)
        let installedDirectory = canonicalDirectory(of: env.rvPath)
        guard runningDirectory != installedDirectory else { return }
        throw SetupError.notInstalledCopy(running: running, installedRv: env.rvPath)
    }

    private static func canonicalDirectory(of path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().path
    }

    private static func failureOutcome(
        _ error: SetupError,
        command: SetupFailureCommand
    ) -> SetupOutcome {
        let output = setupFailureOutput(error, command: command)
        return SetupOutcome(stdout: "", stderr: output.stderr, exitCode: output.exitCode)
    }

    /// Hooks fail closed on an rvd they cannot trust, so wiring them to one
    /// denies every tool call. Refuse before writing anything; `--force`
    /// replaces occupied hooks and cannot make the daemon trusted.
    static func requireTrustedDaemon(_ env: SetupEnvironment) throws(SetupError) {
        guard env.fileManager.isExecutableFile(atPath: env.rvdPath),
            let trust = env.daemonTrust(env.rvdPath),
            trust.satisfied == false
        else { return }
        throw SetupError.daemonUntrusted(
            reason: trust.reason ?? "untrusted", fix: DaemonTrustProbe.fix(trust)
        )
    }

    private static func perform(
        _ env: SetupEnvironment,
        force: Bool,
        guardRequest: SetupGuardRequest
    ) throws(SetupError) -> SetupReport {
        try requireInstalledCopy(env)
        try requireTrustedDaemon(env)
        try applyGuardRequest(guardRequest, env: env)
        let files = FileOps(fileManager: env.fileManager)
        let layout = OwnedPaths(home: env.home)
        let installations = try inspectInstallations(layout: layout, env: env)
        // An organization gate keeps every detected host wired: `off` would
        // drop the hook and with it the org policy.
        let offHosts: Set<HookHost> = env.managedEnforce(env.home) ? [] : Set(HostModeStore(
            configDirectory: URL(fileURLWithPath: layout.configDirectory, isDirectory: true)
        ).load().filter { $0.value == .off }.keys)
        let plan = SetupWorkPlanBuilder.make(
            installations: installations,
            layout: layout,
            force: force,
            rvdIsExecutable: env.fileManager.isExecutableFile(atPath: env.rvdPath),
            offHosts: offHosts
        )
        return try HostLifecycle.attach(plan, env: env, layout: layout, files: files)
    }

    static func inspectInstallations(
        layout: OwnedPaths,
        env: SetupEnvironment
    ) throws(SetupError) -> HostAdapterInstallationSnapshot {
        do {
            return try HostAdapterInstallation.inspect(
                paths: layout,
                pathEntries: env.pathEntries,
                fileManager: env.fileManager
            )
        } catch let error as HostAdapterResourceError {
            throw SetupError(adapterResourceFailure: error)
        } catch {
            throw SetupError.inspectionFailed
        }
    }

    static func uninstall(
        _ env: SetupEnvironment,
        appearance: CLIAppearance = .robot,
        clock: any SetupCeremonyClock = ZeroSetupCeremonyClock(),
        animate: Bool = false,
        write: ((String) -> Void)? = nil
    ) -> SetupOutcome {
        do {
            let formatted = try uninstallPerform(
                env,
                appearance: appearance,
                clock: clock,
                animate: animate,
                write: write
            )
            return SetupOutcome(
                stdout: formatted.text,
                exitCode: 0,
                emitted: formatted.emitted
            )
        } catch {
            return failureOutcome(error, command: .uninstall)
        }
    }
}

