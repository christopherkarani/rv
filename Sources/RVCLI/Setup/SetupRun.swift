import Foundation
import RVAnalytics
import RVHooks
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

extension SetupHostKind {
    var occupiedLine: String {
        switch self {
        case .grok: "Skipped occupied grok hook."
        case .pi: "Skipped occupied pi hook."
        case .openCode: "Skipped occupied opencode hook."
        }
    }

    func adapterResource() throws -> HostAdapterResource {
        try HostAdapterResources.load(for: hookHost)
    }

    private var hookHost: HookHost {
        switch self {
        case .grok: .grok
        case .pi: .pi
        case .openCode: .opencode
        }
    }

}

struct SetupEnvironment {
    var home: String
    var pathEntries: [String]
    var rvPath: String
    var rvdPath: String
    var fileManager: FileManager
    var launchctl: any LaunchctlApplying
    var touchLaunchd: Bool
    var installAnalytics: any InstallAnalyticsCapturing

    static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> SetupEnvironment? {
        guard let home = environment["HOME"], home.isEmpty == false else { return nil }
        let pathEntries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let executable = Bundle.main.executableURL
        return SetupEnvironment(
            home: home,
            pathEntries: pathEntries,
            rvPath: resolveRv(home: home),
            rvdPath: resolveRvd(nextTo: executable?.path, home: home)
                ?? (home + "/.local/bin/rvd"),
            fileManager: .default,
            launchctl: ProcessLaunchctl(),
            touchLaunchd: LoginHome.matchesProcessHome(home),
            installAnalytics: BlockingInstallAnalytics.live(home: home, environment: environment)
        )
    }

    /// Curl install bakes `$HOME/.local/bin/rv`. Do not walk PATH.
    static func resolveRv(home: String) -> String {
        home + "/.local/bin/rv"
    }

    /// Prefer `rvd` next to the running `rv`, then `$HOME/.local/bin/rvd`.
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

enum SetupRun {
    static let hostlessLine = "Run rv setup after Pi, Grok, or OpenCode exists."
    static let robotCompleteLine = "Setup complete. Next  rv test 'git reset --hard'."
    static let uninstallCompleteLine = "Uninstall complete."
    static let uninstallAlreadyCleanLine = "Already clean."
    static let launchAgentLabel = "dev.rv.evaluate"

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
            let report = try SetupApply.setup(env, force: force)
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
                exitCode: 0,
                emitted: formatted.emitted
            )
        } catch {
            return SetupOutcome(stdout: "", stderr: "rv setup failed: \(error)\n", exitCode: 1)
        }
    }

    static func uninstall(
        _ env: SetupEnvironment,
        appearance: CLIAppearance = .robot,
        clock: any SetupCeremonyClock = ZeroSetupCeremonyClock(),
        animate: Bool = false,
        write: ((String) -> Void)? = nil
    ) -> SetupOutcome {
        let report: UninstallReport
        do {
            report = try SetupApply.uninstall(env)
        } catch {
            return SetupOutcome(stdout: "", stderr: error.stderr, exitCode: 1)
        }
        let formatted = SetupFormat.uninstallStdout(
            report: report,
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
    }
}
