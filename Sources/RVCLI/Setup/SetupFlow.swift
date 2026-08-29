import Foundation
import RVPolicy
import RVPresentation

/// Which lifecycle operation an intent asks for. Selects the orchestration
/// path and the failure-output prefix (`setup` vs `uninstall`).
enum SetupIntentKind: String {
    case install
    case uninstall

    var failureCommand: SetupFailureCommand {
        switch self {
        case .install: .setup
        case .uninstall: .uninstall
        }
    }
}

/// Everything a command decides before handing control to the flow door.
/// Defaults mirror `SetupRun.setup`; commands pass what they parsed.
struct SetupIntent {
    var kind: SetupIntentKind
    var force: Bool = false
    var appearance: CLIAppearance = .robot
    var animate: Bool = false
    var ceremonyKind: SetupCeremonyKind = .setup
}

/// The single deep entry into setup/uninstall. Owns environment construction;
/// commands build an intent and call `run`. The environment factory is
/// injectable so orchestration is provable without touching `$HOME`.
struct SetupFlow {
    var makeEnvironment: () -> SetupEnvironment?

    /// Production door; consults `SetupEnvironment.live`.
    static func live() -> SetupFlow {
        SetupFlow(makeEnvironment: { SetupEnvironment.live() })
    }

    func run(
        _ intent: SetupIntent,
        clock: any SetupCeremonyClock = ZeroSetupCeremonyClock(),
        write: ((String) -> Void)? = nil
    ) -> SetupOutcome {
        guard let env = makeEnvironment() else {
            return SetupOutcome(
                stdout: "",
                stderr: "rv \(intent.kind.failureCommand.rawValue): HOME is not set\n",
                exitCode: 1
            )
        }
        switch intent.kind {
        case .install:
            return SetupRun.setup(
                env,
                appearance: intent.appearance,
                ceremonyKind: intent.ceremonyKind,
                force: intent.force,
                clock: clock,
                animate: intent.animate,
                write: write
            )
        case .uninstall:
            return SetupRun.uninstall(
                env,
                appearance: intent.appearance,
                clock: clock,
                animate: intent.animate,
                write: write
            )
        }
    }
}

extension SetupEnvironment {
    /// Production construction, consulted by the flow door by default.
    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SetupEnvironment? {
        guard let home = HomeDirectory(validating: environment["HOME"] ?? "") else { return nil }
        let pathEntries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let executable = Bundle.main.executableURL
        let loginHome = LoginHome.matchesProcessHome(home.rawValue)
        let fileManager = FileManager.default
#if os(Linux)
        let supervisor = EvaluateSupervisor.systemdUser
        let touchLaunchd = false
        let touchSystemd = loginHome
        let companionPresence: any CompanionPresenceDetecting = FixedCompanionPresence(value: .absent)
#else
        let supervisor = EvaluateSupervisor.launchd
        let touchLaunchd = loginHome
        let touchSystemd = false
        // P2-1: inject fileManager via SetupEnvironment consistently.
        let companionPresence: any CompanionPresenceDetecting = FilesystemCompanionPresence(
            home: home.rawValue,
            fileManager: fileManager
        )
#endif
        return SetupEnvironment(
            home: home,
            pathEntries: pathEntries,
            rvPath: resolveRv(home: home.rawValue),
            rvdPath: resolveRvd(nextTo: executable?.path, home: home.rawValue, fileManager: fileManager)
                ?? (home.rawValue + "/.local/bin/rvd"),
            fileManager: fileManager,
            launchctl: ProcessLaunchctl(),
            systemctl: ProcessSystemctl(),
            touchLaunchd: touchLaunchd,
            touchSystemd: touchSystemd,
            supervisor: supervisor,
            installAnalytics: BlockingInstallAnalytics.live(home: home, environment: environment),
            companionPresence: companionPresence
        )
    }
}
