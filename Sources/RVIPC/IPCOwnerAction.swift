import Foundation

/// Proof that the device owner is present for one owner action.
///
/// On macOS no proof travels: rvd shows the LocalAuthentication prompt
/// (Touch ID or the login password) itself. On Linux the CLI reads the
/// owner's login password from the controlling terminal and rvd checks it
/// with the system's `unix_chkpwd`; allow-once redeem carries it the same
/// way. A coding agent running as the same user has no finger and does not
/// know the password, which is what makes this a presence check rather than
/// a same-user formality.
public struct OwnerProof: Sendable, Equatable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    public var password: String?

    public init(password: String? = nil) {
        self.password = password
    }

    /// Never print the secret, including in logs and test failures.
    public var description: String { password == nil ? "OwnerProof(none)" : "OwnerProof(password: <redacted>)" }
    public var debugDescription: String { description }
}

/// Ask rvd to confirm that the device owner approves `summary`.
///
/// `summary` is the human wording of the action ("enable packs cloud.aws").
/// rvd audits it with the outcome. On approval the CLI performs the action.
public struct ConfirmOwnerActionParams: Sendable, Equatable, Codable {
    public static let maxSummaryBytes = 512

    public var summary: String
    public var proof: OwnerProof?
    public var clientSemver: String

    public init(summary: String, proof: OwnerProof?, clientSemver: String) {
        self.summary = summary
        self.proof = proof
        self.clientSemver = clientSemver
    }
}

public struct ConfirmOwnerActionReply: Sendable, Equatable, Codable {
    public enum Outcome: String, Sendable, Equatable, Codable {
        case approved
        /// No usable proof for this caller (an unauthenticated peer, or
        /// Linux without a password).
        case proofRequired
        case wrongPassword
        /// macOS: the owner cancelled or failed rvd's prompt, or let it time out.
        case declined
        /// Too many wrong passwords or declined prompts recently; try again later.
        case lockedOut
        /// Another owner check is already waiting.
        case busy
        /// This system cannot check the owner: no `unix_chkpwd` on Linux, or
        /// no Touch ID or passcode prompt available to rvd on macOS.
        case unavailable
    }

    /// How rvd checked the owner for an `.approved` outcome.
    public enum Presence: String, Sendable, Equatable, Codable {
        /// rvd showed its own LocalAuthentication prompt (macOS).
        case daemonPrompt
        /// rvd verified the login password the CLI sent (Linux).
        case password
    }

    public var outcome: Outcome
    /// Seconds until a lockout ends, when `outcome == .lockedOut`.
    public var retryAfterSeconds: Int?
    /// Set with `.approved` by an rvd that checks the owner itself. An older
    /// rvd approved a pinned CLI with no check and omits it, so a CLI must
    /// refuse an approval without it.
    public var presence: Presence?

    public init(outcome: Outcome, retryAfterSeconds: Int? = nil, presence: Presence? = nil) {
        self.outcome = outcome
        self.retryAfterSeconds = retryAfterSeconds
        self.presence = presence
    }
}
