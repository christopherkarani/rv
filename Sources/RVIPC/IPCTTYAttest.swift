import Foundation
import RVDomain

/// Allow-once redeem: asks rvd to plant one memory grant for a pending
/// code. The caller is an authenticated same-user peer and gets no
/// authority from its role: rvd plants only after the device owner
/// approves, on macOS in rvd's own LocalAuthentication prompt naming the
/// code rvd issued, on Linux with the login password in `ownerProof`
/// (see `ServiceRuntime.attestTTYRedemption`). rvd re-validates every field
/// and enforces per-epoch code single-use, so a buggy caller cannot plant
/// garbage or doubles.
///
/// The CLI sends the action DIGEST, never the view: pending rows store
/// fingerprints (views would leak secret-bearing commands into a
/// same-user-readable file). Spend matches the same digest.
public struct AttestTTYRedemptionParams: Sendable, Equatable, Codable {
    /// Grant fingerprint (`commandFingerprint` row field, B1-folded) of
    /// the reviewed pending row. Decode rejects non-64-hex bytes.
    public var fingerprint: GrantFingerprint
    public var cwd: WorkingDirectory
    /// sha256 hex of the redeemed unlock code. Dedupe key only; the code
    /// itself never crosses IPC.
    public var codeHash: CodeHash
    public var clientSemver: String
    /// M-07 content digest of the reviewed row's masked payload, when the
    /// row carried one. A digest only — exact segments never cross IPC.
    /// Nil (legacy rows and old clients) plants unbound, which fails
    /// closed on masked spends. Optional for wire compatibility: older
    /// clients omit the key and decode to nil. Decode rejects
    /// non-64-hex bytes.
    public var payloadDigest: ContentPayloadDigest?
    /// Linux: the owner's login password, which rvd verifies before
    /// planting. macOS sends none (rvd prompts itself). Optional for wire
    /// compatibility.
    public var ownerProof: OwnerProof?

    public init(
        fingerprint: GrantFingerprint,
        cwd: WorkingDirectory,
        codeHash: CodeHash,
        clientSemver: String,
        payloadDigest: ContentPayloadDigest? = nil,
        ownerProof: OwnerProof? = nil
    ) {
        self.fingerprint = fingerprint
        self.cwd = cwd
        self.codeHash = codeHash
        self.clientSemver = clientSemver
        self.payloadDigest = payloadDigest
        self.ownerProof = ownerProof
    }
}

public struct AttestTTYRedemptionReply: Sendable, Equatable, Codable {
    /// False when this ceremony already planted this epoch (no second
    /// grant), or when `ownerCheck` says the owner did not approve.
    public var planted: Bool
    /// Issuing table epoch (audit correlation).
    public var epoch: String
    /// Set only when the owner check refused (declined or failed prompt,
    /// wrong password, lockout, a prompt already open, no prompt
    /// possible); nothing was planted. Nil on a plant or an
    /// already-planted retry.
    public var ownerCheck: ConfirmOwnerActionReply?
    /// True with an `unavailable` owner check when rvd refused to prompt
    /// because it cannot show the whole command and cwd (too long once
    /// escaped). rvd never shows a shortened command for approval.
    public var notShowable: Bool?

    public init(
        planted: Bool, epoch: String, ownerCheck: ConfirmOwnerActionReply? = nil, notShowable: Bool? = nil
    ) {
        self.planted = planted
        self.epoch = epoch
        self.ownerCheck = ownerCheck
        self.notShowable = notShowable
    }
}
