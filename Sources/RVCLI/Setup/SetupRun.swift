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

enum SetupRun {
    static let launchAgentLabel = "dev.rv.evaluate"
    /// One-line repair when installed binaries (rvd, pack bundle) are missing.
    static let reinstallHint = "reinstall rv (curl -fsSL https://rykanv.com/install | sh)"

    static func setup(
        _ env: SetupEnvironment,
        appearance: CLIAppearance = .robot,
        ceremonyKind: SetupCeremonyKind = .setup,
        force: Bool = false,
        clock: any SetupCeremonyClock = ZeroSetupCeremonyClock(),
        animate: Bool = false,
        write: ((String) -> Void)? = nil
    ) -> SetupOutcome {
        do {
            let report = try perform(env, force: force)
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
                stderr: serviceWarning(report),
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

    /// Setup that loads the real supervisor must run from the hook's bin dir:
    /// the plist names `rvd` there, and a different build's `rv-cli` would
    /// wire hooks for binaries that were never installed.
    private static func requireInstalledCopy(_ env: SetupEnvironment) throws(SetupError) {
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

    private static func perform(_ env: SetupEnvironment, force: Bool) throws(SetupError) -> SetupReport {
        try requireInstalledCopy(env)
        let files = FileOps(fileManager: env.fileManager)
        let layout = OwnedPaths(home: env.home)
        let installations = try inspectInstallations(layout: layout, env: env)
        let plan = SetupWorkPlanBuilder.make(
            installations: installations,
            layout: layout,
            force: force,
            rvdIsExecutable: env.fileManager.isExecutableFile(atPath: env.rvdPath)
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

