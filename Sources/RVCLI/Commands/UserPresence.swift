#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// What the person at the keyboard must prove when rv is about to sign.
enum PresenceChallenge: Sendable {
    /// Type a code that was not printed by this process. A pseudo-terminal
    /// cannot complete this: the caller could read and write the same pty.
    case printedCode(@Sendable (String) -> Bool)
    /// Touch ID or the login password. A code on this terminal is not accepted.
    case deviceOwner
}

enum PresenceOutcome: Sendable, Equatable {
    case confirmed(method: String)
    case refused(String)
}

/// Proof that a person, not an agent, is approving. macOS asks for Touch ID
/// or the login password. A controlling terminal is not that proof: the
/// agent can allocate a pseudo-terminal, read it, and answer it.
struct UserPresence: Sendable {
    var confirm: @Sendable (_ reason: String, _ challenge: PresenceChallenge) async -> PresenceOutcome

    static let deviceOwnerRefusal =
        "this needs device owner authentication (Touch ID or your password); a terminal is not enough"
    static let pseudoTerminalRefusal = "a pseudo-terminal is not proof you are present"
    static let noTerminalRefusal =
        "this needs you present: run it yourself in a terminal (this process has no terminal)"

    static let live = UserPresence { reason, challenge in
        switch challenge {
        case .printedCode(let check):
            // The code MAC is checked before Touch ID can return. A
            // pseudo-terminal still reaches device owner; it is not presence
            // by itself, and it does not skip that check.
            let prompt = readPrintedCode(reason, check: check)
            guard case .confirmed = prompt.outcome else { return prompt.outcome }
            #if canImport(LocalAuthentication)
            let owner = await deviceOwner(reason)
            return finishPrintedCode(
                ttyPath: prompt.ttyPath, codeVerified: true, deviceOwner: owner, deviceOwnerCanRun: true)
            #else
            return finishPrintedCode(
                ttyPath: prompt.ttyPath, codeVerified: true, deviceOwner: nil, deviceOwnerCanRun: false)
            #endif
        case .deviceOwner:
            #if canImport(LocalAuthentication)
            if let outcome = await deviceOwner(reason) { return outcome }
            #endif
            return terminal(reason, challenge)
        }
    }

    #if canImport(LocalAuthentication)
    /// Nil when LocalAuthentication cannot prompt here (no passcode, no GUI session).
    /// A cancelled prompt is a refusal and does not fall through.
    static func deviceOwner(_ reason: String) async -> PresenceOutcome? {
        let context = LAContext()
        var unavailable: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &unavailable) else { return nil }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
                return .refused("authentication failed")
            }
            return .confirmed(method: "device owner authentication")
        } catch let error as LAError where error.code == .notInteractive || error.code == .systemCancel {
            // The system could not prompt here (no GUI attach, another
            // authentication already running): the terminal challenge is
            // the documented fallback. A user pressing Cancel is .userCancel
            // and still refuses below.
            return nil
        } catch is CancellationError {
            return .refused("authentication was cancelled")
        } catch {
            return .refused("authentication was cancelled or failed")
        }
    }
    #endif

    /// Device-owner challenges stop here. A printed code is read from the
    /// terminal the person is using, including Terminal.app and `/dev/pts`.
    /// The expected code is never written.
    static func terminal(_ reason: String, _ challenge: PresenceChallenge) -> PresenceOutcome {
        switch challenge {
        case .deviceOwner:
            return .refused(deviceOwnerRefusal)
        case .printedCode(let check):
            return readPrintedCode(reason, check: check).outcome
        }
    }

    struct PrintedCodePrompt: Equatable, Sendable {
        var outcome: PresenceOutcome
        var ttyPath: String?
    }

    /// Reads the confirmation code. A pseudo-terminal is not refused here:
    /// device owner, when it can run, is required after the code verifies.
    static func readPrintedCode(_ reason: String, check: @Sendable (String) -> Bool) -> PrintedCodePrompt {
        let fd = open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard fd >= 0 else { return PrintedCodePrompt(outcome: .refused(noTerminalRefusal), ttyPath: nil) }
        defer { close(fd) }
        let path = ttyPath(fd)
        guard isatty(fd) == 1 else {
            return PrintedCodePrompt(outcome: .refused("this needs you present: /dev/tty is not a terminal"), ttyPath: path)
        }
        put(fd, "\(reason)\nType the confirmation code: ")
        guard let typed = line(fd), check(typed) else {
            return PrintedCodePrompt(outcome: .refused("wrong confirmation code"), ttyPath: path)
        }
        return PrintedCodePrompt(outcome: .confirmed(method: "terminal confirmation code"), ttyPath: path)
    }

    /// What approve does after the code has been checked. Device owner wins
    /// when it ran. A cancelled prompt stays a refusal. A pseudo-terminal is
    /// not presence when device owner can run and did not confirm. Linux has
    /// no device-owner prompt, so a verified code on `/dev/pts` stands.
    static func finishPrintedCode(
        ttyPath: String?, codeVerified: Bool, deviceOwner: PresenceOutcome?, deviceOwnerCanRun: Bool
    ) -> PresenceOutcome {
        guard codeVerified else { return .refused("wrong confirmation code") }
        if let deviceOwner { return deviceOwner }
        if deviceOwnerCanRun, let refused = refusalForPrintedCode(ttyPath: ttyPath) { return refused }
        return .confirmed(method: "terminal confirmation code")
    }

    /// Nil when this path can stand on a verified code. A missing path and a
    /// pseudo-terminal are not presence by themselves once device owner can run.
    static func refusalForPrintedCode(ttyPath: String?) -> PresenceOutcome? {
        guard let ttyPath, ttyPath.isEmpty == false else { return .refused(noTerminalRefusal) }
        if isCallerControlledTerminal(ttyPath) { return .refused(pseudoTerminalRefusal) }
        return nil
    }

    /// Paths a same-user process can allocate and then read back.
    static func isCallerControlledTerminal(_ path: String) -> Bool {
        if path == "/dev/tty" { return true }
        if path.hasPrefix("/dev/pts/") { return true }
        if path.hasPrefix("/dev/ttys") { return true }
        if path.hasPrefix("/dev/pty") { return true }
        return false
    }

    private static func ttyPath(_ fd: Int32) -> String? {
        guard let name = ttyname(fd) else { return nil }
        return String(cString: name)
    }

    private static func put(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// One line, at most 128 bytes, whitespace trimmed. Nil at EOF.
    private static func line(_ fd: Int32) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while bytes.count < 128 {
            let n = read(fd, &byte, 1)
            if n < 0, errno == EINTR { continue }
            guard n == 1 else { return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
            if byte == 0x0A { break }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum MCPCodeAlphabet {
    static let symbols = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
}
