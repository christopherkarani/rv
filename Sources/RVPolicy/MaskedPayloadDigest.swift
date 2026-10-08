import Foundation
import RVDomain

/// M-07 masked-payload digests. Grants bind the masked view plus a digest of
/// the exact lexemes masking replaced, so same-view commands with different
/// hidden payloads do not share authority.
///
/// Two constructions, one join:
///
/// - Salted (ephemeral memory grants): `sha256(salt || NUL-joined segments)`
///   with a per-table (per-daemon-boot) random salt. Computed inside
///   `EphemeralAllowOnceTable`, which never exposes the salt or the segments.
/// - Content (durable file rows and allowlist entries): `sha256` of the same
///   NUL-joined segments with no salt. Durable records must verify across
///   reboots, so no boot salt can apply; the brute-force profile matches the
///   existing unsalted `commandFingerprint` precedent.
///
/// Only digests are stored or transmitted. Exact segments stay in-process at
/// the mint/spend boundary that already holds the exact command text.
public func maskedPayloadContentDigest(_ segments: [String]) -> String {
    RVDigest.sha256Hex(maskedPayloadJoinedBytes(segments))
}

/// `salt || NUL-joined segments` digest for one ephemeral table.
func maskedPayloadSaltedDigest(_ segments: [String], salt: [UInt8]) -> String {
    RVDigest.sha256Hex(salt + maskedPayloadJoinedBytes(segments))
}

/// NUL-joins segment bytes. Exec argv cannot contain NUL, so the join is
/// exact (same discipline as the git `pushUnparsed` fingerprint).
private func maskedPayloadJoinedBytes(_ segments: [String]) -> [UInt8] {
    var bytes: [UInt8] = []
    for (index, segment) in segments.enumerated() {
        if index > 0 {
            bytes.append(0)
        }
        bytes.append(contentsOf: segment.utf8)
    }
    return bytes
}
