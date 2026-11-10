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
/// When rvd does not answer a bounded probe, the human confirms locally:
/// 1. stdin AND stdout must both be a terminal, or this refuses;
/// 2. the owner check runs without rvd where the platform has one
///    (macOS: LocalAuthentication; Linux: `unix_chkpwd` on the caller's own
///    login password, read from /dev/tty with echo off);
/// 3. where no local check is possible (no passcode, no `unix_chkpwd`, an
///    account without a password), the human types an exact phrase at
///    /dev/tty instead.
/// When rvd answers, the existing rvd-backed path runs unchanged.
///
/// SECURITY: an agent must not be able to use this path.
/// - The hook gate denies agents running `rv uninstall` / `rv host mode … off`
///   while rvd is up, and this path is never taken while rvd is up.
/// - With rvd down the hook fails closed: it denies every agent tool call (or,
///   for hosts with a native ask, puts the exact command in front of the
///   human), so no agent tool call reaches this code unattended.
/// - It requires a real TTY on stdin AND stdout and reads the answer only
///   from /dev/tty. An agent's tool call runs with piped stdio and cannot
///   satisfy that. The confirmation is never read from a stdin pipe, an
///   argument, or an environment variable.
struct DaemonDownOwnerConfirmation: Sendable {
    /// What the human is confirming, and the phrase they type when no local
    /// owner check is available.
    struct Action: Sendable, Equatable {
        let summary: String
        let phrase: String

        static let uninstall = Action(summary: "uninstall rv", phrase: "uninstall rv")

        static func hostMode(_ mode: HostMode, host: HookHost) -> Action {
            let phrase = mode == .off
                ? "turn off rv for \(host.rawValue)"
                : "set rv to \(mode.rawValue) for \(host.rawValue)"
            return Action(summary: phrase, phrase: phrase)
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
        var rvdReachable: @Sendable () async -> Bool
        var stdinIsTTY: @Sendable () -> Bool
        var stdoutIsTTY: @Sendable () -> Bool
        /// The platform's daemon-free owner check; the argument is the reason.
        var localOwnerCheck: @Sendable (String) async -> LocalCheck
        /// One line from /dev/tty (echo on) after writing the prompt there;
        /// nil when there is no controlling terminal.
        var readTTYLine: @Sendable (String) -> String?
        /// One line of explanation for the human (stderr).
        var notice: @Sendable (String) -> Void
    }

    static let daemonDownNotice =
        "rv: rvd is not answering, so your password cannot be checked by rvd. Confirming locally instead."

    static let noLocalVerifierNotice =
        "rv: this account's password cannot be checked on this system without rvd."

    static func notATerminalMessage(_ action: Action) -> String {
        "rv: \(action.summary) needs you at an interactive terminal while rvd is down "
            + "(stdin and stdout must both be a terminal). Run it yourself in a terminal, "
            + "or repair rvd with `rv setup`."
    }

    static func rejectedMessage(_ action: Action) -> String {
        "rv: owner check failed or was cancelled; \(action.summary) was not done."
    }

    static func phrasePrompt(_ action: Action) -> String {
        "Type \"\(action.phrase)\" to confirm: "
    }

    static func phraseMismatchMessage(_ action: Action) -> String {
        "rv: confirmation did not match \"\(action.phrase)\"; \(action.summary) was not done."
    }

    static func decide(_ action: Action, reason: String, seams: Seams) async -> Decision {
        guard await seams.rvdReachable() == false else {
            return .useDaemonPath
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
            seams.notice(noLocalVerifierNotice)
            let typed = seams.readTTYLine(phrasePrompt(action))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard typed == action.phrase else {
                return .refused(phraseMismatchMessage(action))
            }
            return .proceed
        }
    }
}

extension DaemonDownOwnerConfirmation.Seams {
    /// Real process: one bounded rvd probe (the hook's own consult
    /// transport), isatty, and /dev/tty.
    static func live() -> Self {
        Self(
            rvdReachable: {
                await ServiceClient.probing(home: CLIProcess.home()).verifyHookService(attempts: 1)
            },
            stdinIsTTY: { isatty(STDIN_FILENO) != 0 },
            stdoutIsTTY: { isatty(STDOUT_FILENO) != 0 },
            localOwnerCheck: { reason in await DaemonDownOwnerConfirmation.liveLocalCheck(reason: reason) },
            readTTYLine: { prompt in DaemonDownOwnerConfirmation.readTTYLine(prompt: prompt) },
            notice: { line in FileHandle.standardError.write(Data("\(line)\n".utf8)) }
        )
    }

    /// Seamed test contexts that set no fallback seams: rvd counts as
    /// reachable, so the existing `ownerAuthOutcome` seam decides and
    /// nothing local is consulted.
    static let daemonAssumedReachable = Self(
        rvdReachable: { true },
        stdinIsTTY: { false },
        stdoutIsTTY: { false },
        localOwnerCheck: { _ in .rejected },
        readTTYLine: { _ in nil },
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
        return unixChkpwdCheck(reason: reason)
        #else
        return .unavailable
        #endif
    }

    /// Linux: the caller's own login password, read from /dev/tty with echo
    /// off and checked by `unix_chkpwd` here, without rvd. Compiled on every
    /// platform so it type-checks; only Linux calls it.
    static func unixChkpwdCheck(reason: String, checker: UnixChkpwdChecker = UnixChkpwdChecker()) -> LocalCheck {
        guard checker.helpers.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return .unavailable
        }
        // Empty input: the account has no password to check (key-only
        // logins); the caller falls through to the typed phrase. So the
        // password is a check on the human, not the boundary: the boundary
        // is the fail-closed hook plus the TTY requirement (see the type doc).
        guard let password = OwnerConfirmation.readOwnerPassword(
            prompt: "\(reason)\nPassword for \(UserName.current ?? "your account") "
                + "(press Return if this account has no password): ")
        else { return .unavailable }
        switch checker.check(password) {
        case .some(true): return .verified
        case .some(false): return .rejected
        case .none: return .unavailable
        }
    }

    /// Reads one line from the controlling terminal (echo on). nil when
    /// there is no terminal. Never reads stdin, which an agent can pipe.
    static func readTTYLine(prompt: String) -> String? {
        let fd = open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = prompt.withCString { write(fd, $0, strlen($0)) }
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") { break }
            bytes.append(byte)
            if bytes.count > 1024 { return nil }
        }
        return String(decoding: bytes, as: UTF8.self)
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
