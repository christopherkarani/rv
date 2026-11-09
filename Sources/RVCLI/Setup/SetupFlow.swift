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
    /// `rv setup --observe`: store `guard.mode: observe` before wiring.
    var observe: Bool = false
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
                stderr: CommandContext.homeMissingText(command: intent.kind.failureCommand.rawValue),
                exitCode: 1
            )
        }
        // No owner prompt on this door: an observe install that would shed
        // oversight fails closed (`ownerAuthenticationRequired`).
        return run(intent, env: env, ownerAuthenticated: false, clock: clock, write: write)
    }

    /// The door for `rv setup`: when `--observe` would shed oversight (rv
    /// already enforces a wired host), `authenticate` runs first and a
    /// refusal changes nothing.
    func run(
        _ intent: SetupIntent,
        clock: any SetupCeremonyClock = ZeroSetupCeremonyClock(),
        write: ((String) -> Void)? = nil,
        authenticate: () async throws -> Void
    ) async -> SetupOutcome {
        guard let env = makeEnvironment() else {
            return SetupOutcome(
                stdout: "",
                stderr: CommandContext.homeMissingText(command: intent.kind.failureCommand.rawValue),
                exitCode: 1
            )
        }
        var ownerAuthenticated = false
        if intent.kind == .install, intent.observe {
            do {
                if try SetupRun.observeShedsOversight(env) {
                    do {
                        try await authenticate()
                    } catch {
                        throw SetupError.ownerAuthenticationRequired
                    }
                    ownerAuthenticated = true
                }
            } catch let error as SetupError {
                let output = setupFailureOutput(error, command: .setup)
                return SetupOutcome(stdout: "", stderr: output.stderr, exitCode: output.exitCode)
            } catch {
                return SetupOutcome(stdout: "", stderr: "rv setup failed: \(error)\n", exitCode: EX_SOFTWARE)
            }
        }
        return run(intent, env: env, ownerAuthenticated: ownerAuthenticated, clock: clock, write: write)
    }

    private func run(
        _ intent: SetupIntent,
        env: SetupEnvironment,
        ownerAuthenticated: Bool,
        clock: any SetupCeremonyClock,
        write: ((String) -> Void)?
    ) -> SetupOutcome {
        switch intent.kind {
        case .install:
            return SetupRun.setup(
                env,
                appearance: intent.appearance,
                ceremonyKind: intent.ceremonyKind,
                force: intent.force,
                guardRequest: intent.observe ? .observe(ownerAuthenticated: ownerAuthenticated) : .keep,
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
        environment: [String: String] = CLIProcess.environment()
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
        let companionPresence: any CompanionPresenceDetecting = FilesystemCompanionPresence(
            home: home.rawValue
        )
#endif
        var setup = SetupEnvironment(
            home: home,
            pathEntries: pathEntries,
            rvPath: resolveRv(home: home.rawValue),
            rvdPath: resolveRvd(home: home.rawValue),
            fileManager: fileManager,
            launchctl: ProcessLaunchctl(),
            systemctl: ProcessSystemctl(),
            touchLaunchd: touchLaunchd,
            touchSystemd: touchSystemd,
            supervisor: supervisor,
            installAnalytics: BlockingInstallAnalytics.live(home: home, environment: environment),
            companionPresence: companionPresence,
            runningExecutable: executable?.path
        )
        setup.daemonTrust = DaemonTrustProbe.live
        return setup
    }
}
