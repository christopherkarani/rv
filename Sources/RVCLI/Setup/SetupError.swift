import Foundation
import RVDomain
import RVHooks

/// Which command a setup-lifecycle failure belongs to. Selects the stderr
/// prefix only; the failure phrase and exit code come from the error case.
enum SetupFailureCommand: String {
    case setup
    case uninstall
    case serviceRestart = "service restart"
    case hostList = "host list"
    case hostMode = "host mode"
}

/// One launchctl step whose refusal setup/uninstall surfaces.
enum LaunchctlAction {
    case bootstrap
    case bootout
}

/// Closed taxonomy of setup/uninstall failures. Every reachable failure in
/// `perform` / `uninstall` is one of these cases; `setupFailureOutput` maps
/// each exhaustively to one failure line (plus optional fix lines) and one exit code. No other site may
/// format these errors.
///
/// Exit codes follow sysexits(3): 65 data error (embedded resource unusable),
/// 69 service unavailable (launchctl refused), 73 cannot create file,
/// 70 internal software error (post-condition violated, state unreadable).
enum SetupError: Error, Equatable, Sendable {
    /// Uninstall without device-owner authentication.
    case ownerAuthenticationRequired
    /// Embedded Host adapter template missing or lacks its placeholder.
    case adapterTemplateMissing(HookHost)
    /// Embedded launchd plist template missing or lacks its placeholder.
    case launchAgentTemplateMissing
    /// Embedded systemd user unit template missing or lacks its placeholder.
    case systemdUnitTemplateMissing
    /// Could not create the rv config directory.
    case configDirectoryCreateFailed
    /// Could not move an occupied owned hook aside during --force.
    case hostHookClearFailed(HookHost)
    /// Occupied hook refused without --force (merge-time guard, not the
    /// plan-level skip). The stderr line tells the user to rerun with --force.
    case hostHookOccupiedNeedsForce(HookHost)
    /// Could not write an owned hook payload.
    case hostHookWriteFailed(HookHost)
    /// An owned hook payload survived removal (`rv host mode <host> off`).
    case hostHookRemoveFailed(HookHost)
    /// Could not write the LaunchAgent plist.
    case launchAgentWriteFailed
    /// launchctl refused or failed the given step.
    case launchctlApplyFailed(LaunchctlAction)
    /// Could not write the systemd user unit.
    case systemdUnitWriteFailed
    /// systemctl --user refused or failed the given step.
    case systemdApplyFailed(SystemctlAction)
    /// Post-uninstall validation found an owned path that survived removal.
    case ownedPathStillExists
    /// Installed-adapter state could not be determined for an unexpected reason.
    case inspectionFailed
    /// Setup would load the real supervisor but runs from outside the hook's
    /// bin dir. Hooks pin `rvd` beside `~/.local/bin/rv`, so only the
    /// installed copy may wire them. Carries the running binary and the
    /// installed `rv` to run instead.
    case notInstalledCopy(running: String, installedRv: String)
    /// The `rvd` the service must run is missing (or not executable).
    case rvdMissing(String)
    /// Hooks would reject the installed `rvd` (trust manifest or sibling
    /// pin), so wiring them would deny every tool call.
    case daemonUntrusted(reason: String, fix: String)
    /// The service was started but rvd did not answer a health round-trip
    /// within `ServiceReadiness.deadline`.
    case serviceNotAnswering(EvaluateSupervisor)
    /// The service step failed, so setup wired no hooks: wired hooks with no
    /// answering rvd deny every agent tool call. `alreadyWired` names hosts
    /// wired before this run; they were left as they were.
    indirect case serviceDown(SetupError, alreadyWired: [HookHost])

    init(adapterResourceFailure error: HostAdapterResourceError) {
        switch error {
        case .missingTemplate(let host):
            self = .adapterTemplateMissing(host)
        }
    }
}

/// The single owner of failure output for setup/uninstall. Exhaustive over
/// `SetupError`; no default arm exists. Errors that leave the install in a
/// half-working state add a consequence line and a `fix:` line.
func setupFailureOutput(
    _ error: SetupError,
    command: SetupFailureCommand
) -> (stderr: String, exitCode: Int32) {
    let parts = setupFailureParts(error, command: command)
    let lines = ["rv \(command.rawValue) failed: \(parts.phrase)"] + parts.detail
    return (lines.joined(separator: "\n") + "\n", parts.exitCode)
}

private func setupFailureParts(
    _ error: SetupError,
    command: SetupFailureCommand
) -> (phrase: String, exitCode: Int32, detail: [String]) {
    let phrase: String
    let exitCode: Int32
    var detail: [String] = []
    switch error {
    case .ownerAuthenticationRequired:
        phrase = "device-owner authentication required"
        exitCode = EX_NOPERM
    case .adapterTemplateMissing(let host):
        phrase = "missing \(host.rawValue) adapter template"
        exitCode = EX_DATAERR
    case .launchAgentTemplateMissing:
        phrase = "missing LaunchAgent template"
        exitCode = EX_DATAERR
    case .systemdUnitTemplateMissing:
        phrase = "missing systemd unit template"
        exitCode = EX_DATAERR
    case .configDirectoryCreateFailed:
        phrase = "unable to create config directory"
        exitCode = EX_CANTCREAT
    case .hostHookClearFailed(let host):
        phrase = "unable to clear occupied \(host.rawValue) hook"
        exitCode = EX_CANTCREAT
    case .hostHookOccupiedNeedsForce(let host):
        phrase = "occupied \(host.rawValue) hook; rerun with --force"
        exitCode = EX_CANTCREAT
    case .hostHookWriteFailed(let host):
        phrase = "unable to write \(host.rawValue) hook"
        exitCode = EX_CANTCREAT
    case .hostHookRemoveFailed(let host):
        phrase = "unable to remove \(host.rawValue) hook"
        exitCode = EX_CANTCREAT
    case .launchAgentWriteFailed:
        phrase = "unable to write LaunchAgent"
        exitCode = EX_CANTCREAT
    case .launchctlApplyFailed(.bootstrap):
        phrase = "unable to load LaunchAgent"
        exitCode = EX_UNAVAILABLE
        detail.append(
            "fix: rv service restart from a logged-in desktop session (not SSH); rv doctor shows the cause"
        )
    case .launchctlApplyFailed(.bootout):
        phrase = "unable to unload LaunchAgent"
        exitCode = EX_UNAVAILABLE
    case .systemdUnitWriteFailed:
        phrase = "unable to write systemd unit"
        exitCode = EX_CANTCREAT
    case .systemdApplyFailed(.enable):
        phrase = "unable to enable systemd unit"
        exitCode = EX_UNAVAILABLE
        detail.append(
            "fix: systemctl --user enable --now \(SystemdUserTemplate.unitName) "
                + "from a login session with a user systemd manager; "
                + "journalctl --user -u \(SystemdUserTemplate.unitName) and rv doctor show the cause"
        )
    case .systemdApplyFailed(.disable):
        phrase = "unable to disable systemd unit"
        exitCode = EX_UNAVAILABLE
    case .ownedPathStillExists:
        phrase = "owned path still exists"
        exitCode = EX_SOFTWARE
    case .inspectionFailed:
        phrase = "unable to inspect Host adapters"
        exitCode = EX_SOFTWARE
    case .notInstalledCopy(let running, let installedRv):
        phrase = "\(running) is not the installed rv"
        exitCode = EX_USAGE
        detail.append("hooks only trust the rvd beside \(installedRv)")
        detail.append("fix: install this build first (install.sh), then run \(installedRv) setup")
    case .rvdMissing(let path):
        phrase = "rvd not found at \(path)"
        exitCode = EX_UNAVAILABLE
        detail.append("fix: \(SetupRun.reinstallHint)")
    case .daemonUntrusted(let reason, let fix):
        phrase = "hooks would reject the installed rvd: \(reason)"
        exitCode = EX_CONFIG
        detail.append("no hooks were wired: wired hooks would deny every agent tool call")
        detail.append("fix: \(fix)")
    case .serviceNotAnswering(let supervisor):
        phrase = "rvd did not answer within \(Int(ServiceReadiness.deadline)) seconds of starting the service"
        exitCode = EX_UNAVAILABLE
        switch supervisor {
        case .launchd:
            detail.append(
                "fix: rv service restart from a logged-in desktop session (not SSH); rv doctor shows the cause"
            )
        case .systemdUser:
            detail.append(
                "fix: systemctl --user restart \(SystemdUserTemplate.unitName); "
                    + "journalctl --user -u \(SystemdUserTemplate.unitName) and rv doctor show the cause"
            )
        }
    case .serviceDown(let cause, let alreadyWired):
        let inner = setupFailureParts(cause, command: command)
        phrase = inner.phrase
        exitCode = inner.exitCode
        detail.append(serviceDownConsequence(alreadyWired: alreadyWired))
        detail.append(contentsOf: inner.detail)
        detail.append("then rerun rv setup to wire agent hooks")
    }
    return (phrase, exitCode, detail)
}

/// What a failed service step left behind. Setup never wires a hook it
/// cannot prove rvd answers, but hooks from an earlier run stay put.
private func serviceDownConsequence(alreadyWired: [HookHost]) -> String {
    guard alreadyWired.isEmpty == false else {
        return "no hooks were wired: rv wires agent hooks only once rvd answers"
    }
    let names = alreadyWired.map(\.rawValue).joined(separator: ", ")
    return "no new hooks were wired; hooks already wired before this run (\(names)) were left in place, "
        + "so those agents are blocked until rvd answers"
}
