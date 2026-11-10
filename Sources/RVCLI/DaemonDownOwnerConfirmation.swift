#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVPolicy
import RVService

/// Daemon-free owner confirmation for the commands that let a human take rv
/// back out when rvd is gone: `rv uninstall` and loosening `rv host mode`.
///
/// Owner actions normally confirm through rvd (Linux verifies the login
/// password there), so a dead rvd would lock the human out of removing rv.
/// When a bounded probe finds rvd positively absent (`.unreachable`: no
/// daemon registered or listening), the human confirms locally:
/// 1. stdin AND stdout must both be a terminal, or this refuses;
/// 2. the platform's owner check runs without rvd (macOS:
///    LocalAuthentication; Linux: `unix_chkpwd` on the caller's own login
///    password, read from /dev/tty with echo off);
/// 3. where no local check is possible (no passcode, no `unix_chkpwd`),
///    this refuses and says how to start rvd or remove rv by hand.
/// A busy, slow, dropped, untrusted or skewed rvd is not absent: this
/// refuses rather than confirm locally. When rvd answers, the existing
/// rvd-backed path runs unchanged.
///
/// SECURITY: an agent must not be able to use this path.
/// - The hook gate denies agents running `rv uninstall` / `rv host mode … off`
///   while rvd is up, and this path is never taken unless rvd is absent.
/// - With rvd absent an observe host's hook steps aside and allows every
///   call, so an agent CAN reach this code. The TTY check alone does not
///   stop it: `script`, `expect` or `unbuffer` give an agent both TTYs and
///   a pty it writes to. So only a real owner check (a password, passcode
///   or Touch ID the agent does not have) proceeds; nothing typed at the
///   terminal stands in for one. The confirmation is never read from a
///   stdin pipe, an argument, or an environment variable.
struct DaemonDownOwnerConfirmation: Sendable {
    /// What the human is confirming.
    struct Action: Sendable, Equatable {
        let summary: String

        static let uninstall = Action(summary: "uninstall rv")

        static func hostMode(_ mode: HostMode, host: HookHost) -> Action {
            Action(summary: mode == .off
                ? "turn off rv for \(host.rawValue)"
                : "set rv to \(mode.rawValue) for \(host.rawValue)")
        }
    }

    /// Result of the platform's daemon-free owner check.
    enum LocalCheck: Sendable, Equatable {
        case verified
        /// The owner check ran and said no (wrong password, cancelled).
        case rejected
        /// No local owner check on this account or system.
        case unavailable
    }

    enum Decision: Sendable, Equatable {
        /// rvd answered: run the existing rvd-backed owner check.
        case useDaemonPath
        case proceed
        case refused(String)
    }

    /// Every outside effect of the decision. Production uses `live()`;
    /// tests inject closures through `CLIProcess.Context` and never reach a
    /// live prompt, terminal, or rvd.
    struct Seams: Sendable {
        /// One bounded rvd probe: nil when rvd answered, otherwise how it
        /// missed (classified exactly as the hook classifies a miss).
        var probeRVD: @Sendable () async -> HookDaemonFailure?
        var stdinIsTTY: @Sendable () -> Bool
        var stdoutIsTTY: @Sendable () -> Bool
        /// The platform's daemon-free owner check; the argument is the reason.
        var localOwnerCheck: @Sendable (String) async -> LocalCheck
        /// One line of explanation for the human (stderr).
        var notice: @Sendable (String) -> Void
    }

    static let daemonDownNotice =
        "rv: rvd is not running, so your password cannot be checked by rvd. Confirming locally instead."

    static func notATerminalMessage(_ action: Action) -> String {
        "rv: \(action.summary) needs you at an interactive terminal while rvd is down "
            + "(stdin and stdout must both be a terminal). Run it yourself in a terminal, "
            + "or repair rvd with `rv setup`."
    }

    static func rejectedMessage(_ action: Action) -> String {
        "rv: owner check failed or was cancelled; \(action.summary) was not done."
    }

    static func notConfirmedDownMessage(_ action: Action) -> String {
        "rv: rvd did not answer but is not confirmed stopped (busy, slow, or failing its identity check), "
            + "so \(action.summary) cannot be confirmed without it and was not done. "
            + "Retry; if it persists run `rv doctor` or `rv service restart`."
    }

    static func noLocalVerifierMessage(_ action: Action) -> String {
        "rv: this account has no owner check that works without rvd (no login password or passcode, "
            + "or no unix_chkpwd), so \(action.summary) was not done. Start rvd with `rv setup` and retry, "
            + "or remove rv by hand: its hooks, `~/.config/rv`, its service, and the rv files in ~/.local/bin."
    }

    static func decide(_ action: Action, reason: String, seams: Seams) async -> Decision {
        switch await seams.probeRVD() {
        case nil:
            return .useDaemonPath
        case .unreachable?:
            break
        case .some:
            // Busy or slow is not absent: an agent can cause either.
            return .refused(notConfirmedDownMessage(action))
        }
        seams.notice(daemonDownNotice)
        // A piped tool call (an agent) never gets past this line.
        guard seams.stdinIsTTY(), seams.stdoutIsTTY() else {
            return .refused(notATerminalMessage(action))
        }
        switch await seams.localOwnerCheck(reason) {
        case .verified:
            return .proceed
        case .rejected:
            return .refused(rejectedMessage(action))
        case .unavailable:
            return .refused(noLocalVerifierMessage(action))
        }
    }
}

extension DaemonDownOwnerConfirmation.Seams {
    /// Real process: one bounded rvd probe (the hook's own consult
    /// transport and miss classification) and isatty.
    static func live() -> Self {
        Self(
            probeRVD: {
                await ServiceClient.probing(home: CLIProcess.home()).probeHookService()
            },
            stdinIsTTY: { isatty(STDIN_FILENO) != 0 },
            stdoutIsTTY: { isatty(STDOUT_FILENO) != 0 },
            localOwnerCheck: { reason in await DaemonDownOwnerConfirmation.liveLocalCheck(reason: reason) },
            notice: { line in FileHandle.standardError.write(Data("\(line)\n".utf8)) }
        )
    }

    /// Seamed test contexts that set no fallback seams: rvd counts as
    /// reachable, so the existing `ownerAuthOutcome` seam decides and
    /// nothing local is consulted.
    static let daemonAssumedReachable = Self(
        probeRVD: { nil },
        stdinIsTTY: { false },
        stdoutIsTTY: { false },
        localOwnerCheck: { _ in .rejected },
        notice: { _ in }
    )
}

extension DaemonDownOwnerConfirmation {
    static func liveLocalCheck(reason: String) async -> LocalCheck {
        #if canImport(LocalAuthentication)
        switch await CLIOwnerAuth.localDeviceOwnerOutcome(reason: reason) {
        case .authenticated: return .verified
        case .unavailable: return .unavailable
        case .cancelled, .failed, .invalidated, .timedOut: return .rejected
        }
        #elseif os(Linux)
        return await unixChkpwdCheck(reason: reason)
        #else
        return .unavailable
        #endif
    }

    /// Linux: the caller's own login password, read from /dev/tty with echo
    /// off and checked by `unix_chkpwd` here, without rvd. Compiled on every
    /// platform so it type-checks; only Linux calls it.
    static func unixChkpwdCheck(reason: String, checker: UnixChkpwdChecker = UnixChkpwdChecker()) async -> LocalCheck {
        guard checker.helpers.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return .unavailable
        }
        // The password is the boundary: an agent at a pty has the TTYs but
        // not the password (see the type doc). A key-only account's empty
        // answer fails `unix_chkpwd` and is refused.
        guard let password = OwnerConfirmation.readOwnerPassword(
            prompt: "\(reason)\nPassword for \(UserName.current ?? "your account"): ")
        else { return .unavailable }
        switch await checker.check(password) {
        case .some(true): return .verified
        case .some(false): return .rejected
        case .none: return .unavailable
        }
    }
}

extension CLIOwnerAuth {
    /// Owner approval for `rv uninstall` and loosening `rv host mode`: the
    /// existing check when rvd answers, `DaemonDownOwnerConfirmation` when it
    /// does not. Production probes the real rvd; a seamed test context uses
    /// its `daemonDownConfirmation` seams, or none (rvd assumed reachable,
    /// so `ownerAuthOutcome` alone decides and nothing prompts).
    static func requireAuthenticatedOrLocalWhenDaemonDown(
        reason: String, action: DaemonDownOwnerConfirmation.Action
    ) async throws {
        let seams: DaemonDownOwnerConfirmation.Seams
        if let context = CLIProcess.context {
            seams = context.daemonDownConfirmation ?? .daemonAssumedReachable
        } else {
            seams = .live()
        }
        switch await DaemonDownOwnerConfirmation.decide(action, reason: reason, seams: seams) {
        case .useDaemonPath:
            try await requireAuthenticated(reason: reason)
        case .proceed:
            return
        case .refused(let message):
            seams.notice(message)
            throw AllowOnceAuthError.required
        }
    }
}
