#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// `rv service restart`: bounce `rvd` so an upgraded binary or repaired
/// config takes effect, repairing the LaunchAgent registration if needed.
enum ServiceRestart {
    enum Action: Equatable {
        /// `launchctl kickstart -k` on a job already loaded in this domain.
        case kickstarted(domain: String)
        /// Plist rewritten and bootstrapped (job missing or stranded in `user/`).
        case reloaded(domain: String)
    }

    static func run(_ env: SetupEnvironment) -> SetupOutcome {
        switch env.supervisor {
        case .systemdUser:
            return SetupOutcome(
                stdout: "",
                stderr: "rv service restart: use systemctl --user restart \(SystemdUserTemplate.unitName)\n",
                exitCode: EX_USAGE
            )
        case .launchd:
            break
        }
        guard env.touchLaunchd else {
            return SetupOutcome(
                stdout: "",
                stderr: "rv service restart: HOME is not this user's login home; refusing to touch launchd\n",
                exitCode: EX_USAGE
            )
        }
        do {
            let line: String
            switch try perform(env) {
            case .kickstarted(let domain):
                line = "rv service restart: restarted \(SetupRun.launchAgentLabel) in \(domain)"
            case .reloaded(let domain):
                line = "rv service restart: reloaded \(SetupRun.launchAgentLabel) into \(domain)"
            }
            return SetupOutcome(stdout: line + "\n", exitCode: 0)
        } catch {
            let output = setupFailureOutput(error, command: .serviceRestart)
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
}
