#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVPolicy
import RVService

/// `rv service restart`: bounce `rvd` so an upgraded binary or repaired
/// config takes effect, repairing the LaunchAgent registration if needed.
enum ServiceRestart {
    enum Action: Equatable {
        /// `launchctl kickstart -k` on a job already loaded in this domain.
        case kickstarted(domain: String)
        /// Plist rewritten and bootstrapped (job missing or stranded in `user/`).
        case reloaded(domain: String)
    }

    /// `rv service restart` always bounces rvd; `rv service start`
    /// (`onlyIfStopped`) leaves an rvd that already answers alone, so a
    /// shell profile can run it at every login.
    static func run(_ env: SetupEnvironment, onlyIfStopped: Bool = false) -> SetupOutcome {
        let verb = onlyIfStopped ? "start" : "restart"
        switch env.supervisor {
        case .systemdUser:
            return runLinux(env, onlyIfStopped: onlyIfStopped)
        case .launchd:
            break
        }
        if onlyIfStopped, env.serviceAnswersNow() {
            return SetupOutcome(stdout: "rv service start: rvd is already running\n", exitCode: 0)
        }
        guard env.touchLaunchd else {
            return SetupOutcome(
                stdout: "",
                stderr: "rv service \(verb): HOME is not this user's login home; refusing to touch launchd\n",
                exitCode: EX_USAGE
            )
        }
        do {
            let line: String
            switch try perform(env) {
            case .kickstarted(let domain):
                line = "rv service \(verb): restarted \(SetupRun.launchAgentLabel) in \(domain)"
            case .reloaded(let domain):
                line = "rv service \(verb): reloaded \(SetupRun.launchAgentLabel) into \(domain)"
            }
            return SetupOutcome(stdout: line + "\n", exitCode: 0)
        } catch {
            let output = setupFailureOutput(error, command: onlyIfStopped ? .serviceStart : .serviceRestart)
            return SetupOutcome(stdout: "", stderr: output.stderr, exitCode: output.exitCode)
        }
    }

    /// Kickstarts the loaded job. A job loaded only in `user/` while an Aqua
    /// `gui/` domain exists is unreachable from desktop hosts, so it is
    /// reloaded into `gui/` instead; so is a missing job or a failed kickstart.
    static func perform(_ env: SetupEnvironment) throws(SetupError) -> Action {
        let uid = env.uid()
        let label = SetupRun.launchAgentLabel
        let gui = LaunchdDomain.gui(uid)
        let user = LaunchdDomain.user(uid)
        let target: String?
        if env.launchctl.isLoaded(domain: gui, label: label) {
            target = gui
        } else if env.launchctl.isLoaded(domain: user, label: label),
            env.launchctl.domainExists(gui) == false
        {
            target = user
        } else {
            target = nil
        }
        if let target, (try? env.launchctl.kickstart(domain: target, label: label)) != nil {
            return .kickstarted(domain: target)
        }
        return .reloaded(domain: try reload(env))
    }

    private static func reload(_ env: SetupEnvironment) throws(SetupError) -> String {
        guard env.fileManager.isExecutableFile(atPath: env.rvdPath) else {
            throw SetupError.rvdMissing(env.rvdPath)
        }
        let domain = try SetupRun.writeLaunchAgent(
            env: env,
            layout: OwnedPaths(home: env.home),
            files: FileOps(fileManager: env.fileManager),
            keepAlive: env.companionPresence.presence().keepAlive
        )
        guard let domain else {
            throw SetupError.launchctlApplyFailed(.bootstrap)
        }
        return domain
    }

    /// Linux: through the systemd user manager when one answers; otherwise
    /// rvd is run directly (`DirectRvd`), as `rv setup` does. Either way the
    /// command reports success only once rvd answers.
    private static func runLinux(_ env: SetupEnvironment, onlyIfStopped: Bool) -> SetupOutcome {
        let command: SetupFailureCommand = onlyIfStopped ? .serviceStart : .serviceRestart
        guard env.touchSystemd else {
            return SetupOutcome(
                stdout: "",
                stderr: "rv \(command.rawValue): HOME is not this user's login home; refusing to touch the service\n",
                exitCode: EX_USAGE
            )
        }
        do throws(SetupError) {
            if env.systemctl.userManagerReachable() {
                do {
                    try env.systemctl.restart(unit: SystemdUserTemplate.unitName, onlyIfStopped: onlyIfStopped)
                } catch {
                    throw SetupError.systemdApplyFailed(.restart)
                }
                guard env.serviceAnswers() else { throw SetupError.serviceNotAnswering(.systemdUser) }
                let did = onlyIfStopped ? "started" : "restarted"
                return SetupOutcome(
                    stdout: "rv \(command.rawValue): \(did) \(SystemdUserTemplate.unitName) (systemctl --user)\n",
                    exitCode: 0
                )
            }
            if onlyIfStopped, env.serviceAnswersNow() {
                return SetupOutcome(stdout: "rv service start: rvd is already running\n", exitCode: 0)
            }
            try SetupRun.startDirectRvd(env: env, onlyIfStopped: false)
            guard env.serviceAnswers() else {
                throw SetupError.directRvdNotAnswering(
                    rvdPath: env.rvdPath, logPath: RVDLogFile.path(home: env.home.rawValue))
            }
            let observing = JudgeRuntime.configuredGuardMode(home: env.home) == .observe
            return SetupOutcome(
                stdout: "rv \(command.rawValue): rvd is running\n",
                stderr: DirectRvd.notice(
                    command: command.rawValue, rvPath: env.rvPath, rvdPath: env.rvdPath, observing: observing),
                exitCode: 0
            )
        } catch {
            let output = setupFailureOutput(error, command: command)
            return SetupOutcome(stdout: "", stderr: output.stderr, exitCode: output.exitCode)
        }
    }
}
