#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
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
        SetupRun.clearStartupBackoff(env)
        do throws(SetupError) {
            let line: String
            let domain: String
            switch try perform(env) {
            case .kickstarted(let target):
                domain = target
                line = "rv service \(verb): restarted \(SetupRun.launchAgentLabel) in \(domain)"
            case .reloaded(let target):
                domain = target
                line = "rv service \(verb): reloaded \(SetupRun.launchAgentLabel) into \(domain)"
            }
            // An SSH session cannot look up a gui/ job's Mach service, so a
            // probe from here would fail against a healthy rvd. launchd can
            // still say whether rvd's process is up and stays up.
            if domain.hasPrefix("gui/"), env.launchctl.sessionIsAqua() == false {
                return try outsideTheDesktopSession(env, verb: verb, domain: domain, line: line)
            }
            // launchctl accepting the job is not rvd answering: a crash on
            // start or an untrusted binary must fail here, as setup does.
            guard env.serviceAnswers() else { throw SetupError.serviceNotAnswering(.launchd) }
            return SetupOutcome(stdout: line + "\n", exitCode: 0)
        } catch {
            let output = setupFailureOutput(error, command: onlyIfStopped ? .serviceStart : .serviceRestart)
            return SetupOutcome(stdout: "", stderr: output.stderr, exitCode: output.exitCode)
        }
    }

    /// From SSH: success only once launchd reports rvd running with the
    /// same pid across `stableFor` (it did not crash on start). Anything
    /// else fails: print failing (job not found), print showing no state
    /// (rv cannot verify rvd started), or rvd not staying up.
    private static func outsideTheDesktopSession(
        _ env: SetupEnvironment,
        verb: String,
        domain: String,
        line: String
    ) throws(SetupError) -> SetupOutcome {
        let unreachable = "rv service \(verb): this session (SSH or another non-desktop login) cannot reach "
            + "rvd in \(domain); run rv doctor from the desktop session to check that it answers, "
            + "or read \(RVDLogFile.launchdPath(home: "~"))\n"
        switch launchdKeepsRvdRunning(env, domain: domain) {
        case .running(let pid):
            return SetupOutcome(
                stdout: line + "\n",
                stderr: "rv service \(verb): launchd reports rvd running (pid \(pid)); " + unreachable,
                exitCode: 0
            )
        case .unknown:
            return SetupOutcome(
                stdout: "",
                stderr: "rv service \(verb): launchctl print \(domain)/\(SetupRun.launchAgentLabel) showed no "
                    + "state; could not verify rvd started; " + unreachable,
                exitCode: EX_UNAVAILABLE
            )
        case .printFailed:
            return SetupOutcome(
                stdout: "",
                stderr: "rv service \(verb): launchctl print \(domain)/\(SetupRun.launchAgentLabel) failed "
                    + "(launchd job not found or print failed); " + unreachable,
                exitCode: EX_UNAVAILABLE
            )
        case .notRunning:
            throw SetupError.serviceNotAnswering(.launchd)
        }
    }

    static let stableFor: TimeInterval = 2

    /// Polls `launchctl print` until rvd runs with one pid for `stableFor`,
    /// up to `ServiceReadiness.deadline`. `.unknown` or `.printFailed` as
    /// soon as print cannot tell; `.notRunning` when the deadline passes.
    private static func launchdKeepsRvdRunning(_ env: SetupEnvironment, domain: String) -> LaunchdJobProcess {
        var waited: TimeInterval = 0
        while waited < ServiceReadiness.deadline {
            let process = env.launchctl.jobProcess(domain: domain, label: SetupRun.launchAgentLabel)
            switch process {
            case .unknown, .printFailed:
                return process
            case .running(let pid):
                env.sleep(stableFor)
                waited += stableFor
                if env.launchctl.jobProcess(domain: domain, label: SetupRun.launchAgentLabel) == .running(pid: pid) {
                    return .running(pid: pid)
                }
            case .notRunning:
                env.sleep(ServiceReadiness.pollInterval)
                waited += ServiceReadiness.pollInterval
            }
        }
        return .notRunning
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
            files: FileOps(fileManager: env.fileManager)
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
        if onlyIfStopped, env.serviceAnswersNow() {
            return SetupOutcome(stdout: "rv service start: rvd is already running\n", exitCode: 0)
        }
        // Only now does a start or restart happen: an operator's own start
        // must not wait out rvd's crash-loop backoff.
        SetupRun.clearStartupBackoff(env)
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
            try SetupRun.startDirectRvd(env: env, onlyIfStopped: false)
            guard env.serviceAnswers() else {
                throw SetupError.directRvdNotAnswering(
                    rvdPath: env.rvdPath, logPath: RVDLogFile.path(home: env.home.rawValue))
            }
            let observing = GuardConfig.read(home: env.home).machineMode == .observe
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
