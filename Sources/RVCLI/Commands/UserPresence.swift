#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// What the person at the keyboard must prove on a terminal when the OS
/// cannot ask them itself.
enum PresenceChallenge: Sendable {
    /// Type the code `rv mcp serve` printed on its stderr.
    case printedCode(@Sendable (String) -> Bool)
    /// rv shows a fresh code on the terminal and asks for it back. Stops
    /// piped input; a process that drives its own pseudo-terminal can read it.
    case echoCode
}

enum PresenceOutcome: Sendable, Equatable {
    case confirmed(method: String)
    case refused(String)
}

/// Proof that a person, not an agent, is approving. macOS asks for Touch ID
/// or the login password; otherwise the controlling terminal answers a
/// challenge. A caller with neither (an agent's shell) is refused.
struct UserPresence: Sendable {
    var confirm: @Sendable (_ reason: String, _ challenge: PresenceChallenge) async -> PresenceOutcome

    static let live = UserPresence { reason, challenge in
        #if canImport(LocalAuthentication)
        if let outcome = await deviceOwner(reason) { return outcome }
        #endif
        return terminal(reason, challenge)
    }

    #if canImport(LocalAuthentication)
    /// Nil when LocalAuthentication cannot prompt here (no passcode, no GUI session).
    static func deviceOwner(_ reason: String) async -> PresenceOutcome? {
        let context = LAContext()
        var unavailable: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &unavailable) else { return nil }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
                return .refused("authentication failed")
            }
            return .confirmed(method: "device owner authentication")
        } catch let error as LAError where error.code == .notInteractive {
            return nil
        } catch {
            return .refused("authentication was cancelled or failed")
        }
    }
    #endif

    static func terminal(_ reason: String, _ challenge: PresenceChallenge) -> PresenceOutcome {
        let fd = open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard fd >= 0 else {
            return .refused("this needs you present: run it yourself in a terminal (this process has no terminal)")
        }
        defer { close(fd) }
        guard isatty(fd) == 1 else { return .refused("this needs you present: /dev/tty is not a terminal") }
        switch challenge {
        case .printedCode(let check):
            put(fd, "\(reason)\nType the confirmation code `rv mcp serve` printed for this request: ")
            guard let typed = line(fd), check(typed) else { return .refused("wrong confirmation code") }
            return .confirmed(method: "terminal confirmation code")
        case .echoCode:
            let code = String(MCPCodeAlphabet.symbols.shuffled().prefix(6))
            put(fd, "\(reason)\nType \(code) to confirm: ")
            guard let typed = line(fd), typed.uppercased() == code else { return .refused("confirmation did not match") }
            return .confirmed(method: "terminal confirmation")
        }
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
