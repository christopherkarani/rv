import Foundation
import RVDomain
import RVHooks
import RVPresentation

/// Which command a setup-lifecycle failure belongs to. Selects the stderr
/// prefix only; the failure phrase and exit code come from the error case.
enum SetupFailureCommand: String {
    case setup
    case uninstall
}

/// One launchctl step whose refusal setup/uninstall surfaces.
enum LaunchctlAction {
    case bootstrap
    case bootout
}

/// Closed taxonomy of setup/uninstall failures. Every reachable failure in
/// `perform` / `uninstall` is one of these cases; `setupFailureOutput` maps
/// each exhaustively to one stderr line and one exit code. No other site may
/// format these errors.
///
/// Exit codes follow sysexits(3): 65 data error (embedded resource unusable),
/// 69 service unavailable (launchctl refused), 73 cannot create file,
/// 70 internal software error (post-condition violated, state unreadable).
enum SetupError: Error, Equatable, Sendable {
    /// Embedded Host adapter template missing or lacks its placeholder.
    case adapterTemplateMissing(SetupHostKind)
    /// Embedded launchd plist template missing or lacks its placeholder.
    case launchAgentTemplateMissing
    /// Could not create the rv config directory.
    case configDirectoryCreateFailed
    /// Could not move an occupied owned hook aside during --force.
    case hostHookClearFailed(SetupHostKind)
    /// Could not write an owned hook payload.
    case hostHookWriteFailed(SetupHostKind)
    /// Could not write the LaunchAgent plist.
    case launchAgentWriteFailed
    /// launchctl refused or failed the given step.
    case launchctlApplyFailed(LaunchctlAction)
    /// Post-uninstall validation found an owned path that survived removal.
    case ownedPathStillExists
    /// Installed-adapter state could not be determined for an unexpected reason.
    case inspectionFailed

    init(adapterResourceFailure error: HostAdapterResourceError) {
        switch error {
        case .missingTemplate(let host):
            self = .adapterTemplateMissing(SetupHostKind(hook: host))
        }
    }
}

extension SetupHostKind {
    init(hook host: HookHost) {
        switch host {
        case .grok: self = .grok
        case .pi: self = .pi
        case .opencode: self = .openCode
        case .claude:
            fatalError("CL-T4 owns SetupHostKind.claude")
        }
    }

    var failureLabel: String {
        switch self {
        case .grok: "grok"
        case .pi: "pi"
        case .openCode: "opencode"
        }
    }
}

/// The single owner of failure output for setup/uninstall. Exhaustive over
/// `SetupError`; no default arm exists.
func setupFailureOutput(
    _ error: SetupError,
    command: SetupFailureCommand
) -> (stderr: String, exitCode: Int32) {
    let phrase: String
    let exitCode: Int32
    switch error {
    case .adapterTemplateMissing(let host):
        phrase = "missing \(host.failureLabel) adapter template"
        exitCode = EX_DATAERR
    case .launchAgentTemplateMissing:
        phrase = "missing LaunchAgent template"
        exitCode = EX_DATAERR
    case .configDirectoryCreateFailed:
        phrase = "unable to create config directory"
        exitCode = EX_CANTCREAT
    case .hostHookClearFailed(let host):
        phrase = "unable to clear occupied \(host.failureLabel) hook"
        exitCode = EX_CANTCREAT
    case .hostHookWriteFailed(let host):
        phrase = "unable to write \(host.failureLabel) hook"
        exitCode = EX_CANTCREAT
    case .launchAgentWriteFailed:
        phrase = "unable to write LaunchAgent"
        exitCode = EX_CANTCREAT
    case .launchctlApplyFailed(.bootstrap):
        phrase = "unable to load LaunchAgent"
        exitCode = EX_UNAVAILABLE
    case .launchctlApplyFailed(.bootout):
        phrase = "unable to unload LaunchAgent"
        exitCode = EX_UNAVAILABLE
    case .ownedPathStillExists:
        phrase = "owned path still exists"
        exitCode = EX_SOFTWARE
    case .inspectionFailed:
        phrase = "unable to inspect Host adapters"
        exitCode = EX_SOFTWARE
    }
    return ("rv \(command.rawValue) failed: \(phrase)\n", exitCode)
}
