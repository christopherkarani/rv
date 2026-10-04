import Foundation
import RVDomain

/// Step 8B.1 TTY attestation: the genuine pinned CLI proved a human typed
/// this code, reviewed this exact row (fingerprint bound pre-LA and
/// re-checked under the redeem lock), and passed device-owner
/// LocalAuthentication. The daemon plants one memory grant.
///
/// Trust anchor: `.cli` component role (manifest-pinned code identity +
/// hardened runtime + in-binary ceremony order). Same-user code cannot mint
/// the identity; driving the genuine binary forces the human through LA.
/// The daemon still re-validates every field and enforces per-epoch code
/// single-use, so a buggy caller cannot plant garbage or doubles.
///
/// The CLI sends the action DIGEST, never the view: pending rows store
/// fingerprints (views would leak secret-bearing commands into a
/// same-user-readable file). Spend matches the same digest.
public struct AttestTTYRedemptionParams: Sendable, Equatable, Codable {
    /// `commandFingerprint` of the reviewed pending row.
    public var fingerprint: String
    public var cwd: WorkingDirectory
    /// sha256 hex of the redeemed unlock code. Dedupe key only; the code
    /// itself never crosses IPC.
    public var codeHash: String
    public var clientSemver: String

    public init(
        fingerprint: String,
        cwd: WorkingDirectory,
        codeHash: String,
        clientSemver: String
    ) {
        self.fingerprint = fingerprint
        self.cwd = cwd
        self.codeHash = codeHash
        self.clientSemver = clientSemver
    }
}

public struct AttestTTYRedemptionReply: Sendable, Equatable, Codable {
    /// False when this ceremony already planted this epoch (no second grant).
    public var planted: Bool
    /// Issuing table epoch (audit correlation).
    public var epoch: String

    public init(planted: Bool, epoch: String) {
        self.planted = planted
        self.epoch = epoch
    }
}
