import ArgumentParser
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVIPC

/// Owner-presence gate for commands that change rv's own guard (packs,
/// safety, allowlist, policy, egress review, workspace abandon).
///
/// The command runs only after rvd confirms the device owner approved it:
/// - macOS: this genuine, code-pinned CLI runs LocalAuthentication (Touch ID
///   or the login password); rvd accepts it by its `.cli` role.
/// - Linux: the owner types their login password at the controlling
///   terminal; rvd verifies it with `unix_chkpwd`.
///
/// A coding agent running as the same user cannot pass either check: it has
/// no finger and does not know the password, and the hook guard refuses its
/// attempts to run these commands in the first place.
enum OwnerConfirmation {
    struct Refused: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    static func require(_ summary: String, client: ServiceClient? = nil) async throws {
        if let context = CLIProcess.context {
            // Tests: an explicit `.authenticated` seam stands in for the
            // human; anything else fails closed and never prompts.
            guard context.ownerAuthOutcome == .authenticated else {
                throw ValidationError("rv: \(summary) needs owner authentication, which was not given")
            }
            return
        }
        #if canImport(LocalAuthentication)
        do {
            try await CLIOwnerAuth.requireAuthenticated(reason: "rv wants to \(summary).")
        } catch {
            throw ValidationError("rv: \(summary) was not approved (owner authentication failed or was cancelled)")
        }
        try await confirm(summary, proof: nil, client: client)
        #else
        guard let password = readOwnerPassword(prompt: "rv: \(summary)\nPassword for \(UserName.current ?? "your account"): ") else {
            throw ValidationError("rv: \(summary) needs your login password at an interactive terminal")
        }
        try await confirm(summary, proof: OwnerProof(password: password), client: client)
        #endif
    }

    private static func confirm(_ summary: String, proof: OwnerProof?, client: ServiceClient?) async throws {
        let service = client ?? OwnerConfirmation.defaultClient()
        let reply = await service.confirmOwnerAction(ConfirmOwnerActionParams(
            summary: summary, proof: proof, clientSemver: ProtocolVersion.serviceSemver))
        switch reply {
        case .success(let answer):
            switch answer.outcome {
            case .approved:
                return
            case .wrongPassword:
                throw ValidationError("rv: wrong password; \(summary) was not done")
            case .lockedOut:
                let wait = answer.retryAfterSeconds.map { " Try again in \($0 / 60 + 1) min." } ?? ""
                throw ValidationError("rv: too many wrong passwords; owner actions are locked.\(wait)")
            case .busy:
                throw ValidationError("rv: another owner approval is in progress; try again when it finishes")
            case .proofRequired:
                throw ValidationError(
                    "rv: rvd did not accept this caller for owner actions (on macOS use the installed, signed rv)")
            case .unavailable:
                throw ValidationError("rv: rvd could not check the password (unix_chkpwd missing or not answering)")
            }
        case .failure(let error):
            switch error {
            case .noTransport, .transport:
                throw ValidationError("rv: rvd is not reachable, so \(summary) cannot be approved. Run rv doctor.")
            case .service:
                throw ValidationError("rv: rvd refused \(summary)")
            }
        }
    }

    /// rvd over XPC on macOS; over its Unix socket on Linux.
    static func defaultClient() -> ServiceClient {
        ServiceClient()
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
