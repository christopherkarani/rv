import ArgumentParser
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVIPC
#if RV_TEST_OWNER_PRESENCE
import RVService
#endif

/// Owner-presence gate for commands that change rv's own guard (packs
/// off, safety, allowlist, policy, egress review, workspace abandon).
///
/// Turning packs on is not gated (G6): `rv protect <tool>` and
/// `rv packs enable` only tighten, so anyone, agents included, may add
/// protection. Every way to turn a pack off (`rv protect <tool> off`,
/// `rv packs disable`/`off`) goes through `packsOffAuthorization`, which
/// calls `require` here.
///
/// The command runs only after rvd confirms the device owner approved it:
/// - macOS: rvd itself shows the LocalAuthentication prompt (Touch ID or the
///   login password) with this summary. The CLI sends no proof and shows no
///   prompt of its own, so no peer-trust manifest is needed.
/// - Linux: the owner types their login password at the controlling
///   terminal; rvd verifies it with `unix_chkpwd`.
///
/// A coding agent running as the same user cannot pass either check: it has
/// no finger and does not know the password, and the hook guard refuses its
/// attempts to run these commands in the first place.
enum OwnerConfirmation {
    /// The owner check refused or could not run. `message` is the whole
    /// stderr line, without its newline.
    struct Refused: Error, CustomStringConvertible, Equatable {
        let message: String
        var description: String { message }

        init(_ message: String) {
            self.message = message
        }
    }

    /// sysexits(3) EX_NOPERM: every owner-check refusal exits with it, with
    /// one stderr line and no usage banner.
    static let refusalExitCode = EX_NOPERM

    /// How a passed check is recorded on the change it authorized
    /// (`authorized_by`, bound through `ConfigChangeAudit.authorization`).
    #if canImport(LocalAuthentication)
    static let authorization = "owner (Touch ID or password at rvd's prompt)"
    #else
    static let authorization = "owner (login password, checked by rvd)"
    #endif
    /// Tests: the `.authenticated` seam stood in for the owner.
    static let testAuthorization = "owner (test seam)"

    /// Runs the owner check. A refusal prints its line on stderr and throws
    /// `ExitCode(EX_NOPERM)`, so every command it gates exits the same way.
    /// Returns how the owner was checked, for the change's audit event.
    @discardableResult
    static func require(_ summary: String, client: ServiceClient? = nil) async throws -> String {
        do {
            return try await check(summary, client: client)
        } catch let refused as Refused {
            CommandContext.writeStderr(refused.message + "\n")
            throw ExitCode(refusalExitCode)
        }
    }

    /// The owner check itself; throws `Refused` (callers that word the
    /// refusal themselves use this). Returns `authorization`.
    @discardableResult
    static func check(_ summary: String, client: ServiceClient? = nil) async throws -> String {
        if let context = CLIProcess.context {
            // Tests: an explicit `.authenticated` seam stands in for the
            // human; anything else fails closed and never prompts.
            guard context.ownerAuthOutcome == .authenticated else {
                throw Refused("rv: \(summary) needs owner authentication, which was not given")
            }
            return testAuthorization
        }
        #if canImport(LocalAuthentication)
        CommandContext.writeStderr("rv: approve \"\(summary)\" with Touch ID or your password\n")
        try await confirm(summary, proof: nil, client: client)
        return authorization
        #else
        // A locked or empty password can never match: say so instead of
        // prompting for a check that only adds a lockout strike.
        if let locked = refusalIfAccountLocked() {
            throw Refused("rv: \(summary) was not done: \(locked)")
        }
        guard let password = ownerPasswordForRvd(prompt: "rv: \(summary)\nPassword for \(UserName.current ?? "your account"): ") else {
            throw Refused("rv: \(summary) needs your login password at an interactive terminal")
        }
        try await confirm(summary, proof: OwnerProof(password: password), client: client)
        return authorization
        #endif
    }

    private static func confirm(_ summary: String, proof: OwnerProof?, client: ServiceClient?) async throws {
        let service = client ?? OwnerConfirmation.defaultClient()
        let reply = await service.confirmOwnerAction(ConfirmOwnerActionParams(
            summary: summary, proof: proof, clientSemver: ProtocolVersion.serviceSemver))
        try accept(reply, summary: summary)
    }

    /// How this platform's rvd checks the owner (`OwnerPresence.confirm`).
    #if canImport(LocalAuthentication)
    static let expectedPresence = ConfirmOwnerActionReply.Presence.daemonPrompt
    #else
    static let expectedPresence = ConfirmOwnerActionReply.Presence.password
    #endif

    /// The owner approved, but rvd could not record the approval in its
    /// audit log, so it gave none. `result` says what did not happen.
    static func auditUnwritableMessage(_ result: String) -> String {
        "rvd could not write your approval to its audit log (~/.config/rv/audit.jsonl), so \(result). "
            + "Check that ~/.config/rv and audit.jsonl are yours and writable and that the disk is not full, "
            + "then run `rv audit verify` and try again"
    }

    /// Returns only when rvd approved and said it checked the owner the way
    /// this platform's rvd does. An older rvd approves a pinned CLI with no
    /// check and omits `presence`: refused, fail closed.
    static func accept(
        _ reply: Result<ConfirmOwnerActionReply, ServiceClient.ServiceCommandError>, summary: String
    ) throws {
        switch reply {
        case .success(let answer):
            switch answer.outcome {
            case .approved:
                guard answer.presence == expectedPresence else {
                    throw Refused(
                        "rv: rvd approved \(summary) without saying it checked the owner "
                            + "(an older rvd still running after an upgrade?); nothing was done. "
                            + "Run rv service restart and try again.")
                }
                return
            case .wrongPassword:
                throw Refused("rv: wrong password; \(summary) was not done")
            case .declined:
                throw Refused(
                    "rv: \(summary) was not approved (the prompt was cancelled, failed or timed out)")
            case .lockedOut:
                let wait = answer.retryAfterSeconds.map { " Try again in \($0 / 60 + 1) min." } ?? ""
                throw Refused("rv: too many failed owner checks; owner actions are locked.\(wait)")
            case .busy:
                throw Refused("rv: another owner approval is in progress; try again when it finishes")
            case .proofRequired:
                throw Refused("rv: rvd could not identify this caller, so \(summary) was not done")
            case .unavailable:
                #if canImport(LocalAuthentication)
                throw Refused(
                    "rv: rvd cannot show a Touch ID or password prompt here (no passcode set or no login session)")
                #else
                throw Refused("rv: rvd could not check your login password (unix_chkpwd missing or not answering, or this account has no local password, such as an SSSD, LDAP or systemd-homed account)")
                #endif
            case .auditUnwritable:
                throw Refused("rv: " + auditUnwritableMessage("\(summary) was not done"))
            }
        case .failure(let error):
            switch error {
            case .noTransport, .transport:
                throw Refused("rv: rvd is not reachable, so \(summary) cannot be approved. Run rv doctor.")
            case .service:
                throw Refused("rv: rvd refused \(summary)")
            }
        }
    }

    /// rvd over XPC on macOS; over its Unix socket on Linux.
    static func defaultClient() -> ServiceClient {
        ServiceClient()
    }

    /// The password rvd is to check: read from the controlling terminal.
    /// A test-owner-presence build (never a release; TestOwnerPresence.swift
    /// in RVService) sends the harness's password from this process's
    /// environment instead, when it names one. rvd still decides.
    static func ownerPasswordForRvd(prompt: String) -> String? {
        #if RV_TEST_OWNER_PRESENCE
        if let password = TestOwnerPresence.password(in: CLIProcess.environment()) { return password }
        #endif
        return readOwnerPassword(prompt: prompt)
    }

    /// `OwnerAccountPassword.refusalIfLocked`. A test-owner-presence build
    /// given the harness's password skips it: that rvd does not check this
    /// account's password, so a locked one (root in a container) is no
    /// reason to refuse.
    static func refusalIfAccountLocked() -> String? {
        #if RV_TEST_OWNER_PRESENCE
        if TestOwnerPresence.password(in: CLIProcess.environment()) != nil { return nil }
        #endif
        return OwnerAccountPassword.refusalIfLocked()
    }

    /// Reads a password from the controlling terminal with echo off. nil
    /// when there is no terminal (an agent's pipe) or input is empty.
    static func readOwnerPassword(prompt: String) -> String? {
        let fd = open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var original = termios()
        guard tcgetattr(fd, &original) == 0 else { return nil }
        var silent = original
        silent.c_lflag &= ~tcflag_t(ECHO)
        silent.c_lflag |= tcflag_t(ECHONL)
        _ = prompt.withCString { write(fd, $0, strlen($0)) }
        guard tcsetattr(fd, TCSAFLUSH, &silent) == 0 else { return nil }
        defer { _ = tcsetattr(fd, TCSAFLUSH, &original) }
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") { break }
            bytes.append(byte)
            if bytes.count > 1024 { return nil }
        }
        let password = String(decoding: bytes, as: UTF8.self)
        return password.isEmpty ? nil : password
    }
}

enum UserName {
    static var current: String? {
        guard let entry = getpwuid(getuid()), let name = entry.pointee.pw_name else { return nil }
        return String(cString: name)
    }
}
