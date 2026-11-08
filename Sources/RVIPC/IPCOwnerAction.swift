import Foundation

/// Proof that the device owner is present for one owner action.
///
/// On macOS the genuine, code-pinned CLI proves presence itself with
/// LocalAuthentication (Touch ID or the login password) before it asks, and
/// rvd recognises it by its `.cli` component role, so no proof travels. On
/// Linux there is no such role, so the CLI reads the owner's login password
/// from the controlling terminal and rvd checks it with the system's
/// `unix_chkpwd`. A coding agent running as the same user does not know the
/// password, which is what makes this a presence check rather than a
/// same-user formality.
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
        /// No usable proof for this caller (Linux without a password, or a
        /// macOS caller that is not the genuine CLI).
        case proofRequired
        case wrongPassword
        /// Too many wrong passwords recently; try again later.
        case lockedOut
        /// Another owner check is already waiting.
        case busy
        /// This system cannot check passwords (no `unix_chkpwd`).
        case unavailable
    }

    public var outcome: Outcome
    /// Seconds until a lockout ends, when `outcome == .lockedOut`.
    public var retryAfterSeconds: Int?

    public init(outcome: Outcome, retryAfterSeconds: Int? = nil) {
        self.outcome = outcome
        self.retryAfterSeconds = retryAfterSeconds
    }
}
