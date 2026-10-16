import Foundation
import RVDomain

/// Trust-on-first-use SHA-256 pin for admitted binaries, a la OpenShell
/// `BinaryIdentityCache`: first use pins the golden hash, a changed hash
/// denies without updating the pin, and an identical rewrite only
/// refreshes the fingerprint. One cache per proxy instance: pins live as
/// long as the runtime they are bound to.
///
/// Bound proxies must not TOFU-pin at first CONNECT: the golden is
/// established at a trustworthy moment instead — `admit(canonicalPath:)`
/// at admission, or `pinExpected(canonicalPath:sha256Hex:)` from a
/// policy-authored digest — and `verifyAdmitted(canonicalPath:)` denies
/// unknown paths without pinning (REQ-1-1, SEC-1-2).
///
/// Restart semantics (CON-1-4): explicit re-pin-on-restart. Pins are
/// memory-only per cache instance; a fresh cache starts empty and every
/// binding re-admits its binary. No persistence, no cross-instance goldens.
///
/// Borrowed patterns and their primary sources: fingerprint-gated rehash
/// with mismatch-without-update, and the memory-only per-instance cache,
/// follow OpenShell `BinaryIdentityCache::verify_or_cache`
/// (https://raw.githubusercontent.com/NVIDIA/OpenShell/f88aecfd92e02cb1b5388041f09930d78065979a/crates/navigator-sandbox/src/identity.rs;
/// current per-resolver cache at
/// https://raw.githubusercontent.com/NVIDIA/OpenShell/main/crates/openshell-binary-identity/src/lib.rs).
/// TOFU-at-first-connection is kept for `verify` per
/// https://docs.nvidia.com/openshell/latest/how-it-works/policies/network-rules
/// ("records a hash of each executable the first time it takes part in a
/// connection"). Trust fixed at creation/startup is the admission-time
/// principle per
/// https://docs.nvidia.com/openshell/latest/how-it-works/policies/manage-policies
/// ("Filesystem, Landlock, and process settings take effect only when the
/// sandbox starts"). OpenShell network rules carry binary paths only, with
/// hashes recorded at first connection — there is no upstream
/// policy-authored-digest field; `pinExpected` implements the SEC-1-2
/// alternative with the same borrowed compare/update semantics.
///
/// Stat/hash window close (SEC-1-3): after hashing, the path is
/// re-stated and the digest is trusted only when the fingerprint
/// still matches — a swap mid-hash denies as `.unreadable` without
/// pinning, so no stored pair ever binds a digest to bytes it did
/// not measure. Validate-after-measure follows current OpenShell
/// `validate_process_snapshot` (digests reach the cache only after
/// every snapshot validates):
/// https://raw.githubusercontent.com/NVIDIA/OpenShell/main/crates/openshell-binary-identity/src/lib.rs
/// The unchanged-fingerprint fast-path is kept per upstream
/// (`unchanged_fingerprint_skips_rehash` in the pinned identity.rs):
/// every stored pair is proven self-consistent at trust time, so a
/// later fingerprint match only skips re-measuring bytes whose
/// kernel-maintained stat identity still matches the measured pair.
/// Relay-path hashes are bounded (CON-1-5) via `maxHashBytes`.
public final class EgressBinaryPinCache: @unchecked Sendable {
    public enum Verdict: Sendable, Equatable {
        /// First observation: the golden hash is now pinned.
        case pinned
        /// Fingerprint unchanged, or rehash matched the golden hash.
        case match
        /// Rehash differs from the golden hash. The pin is unchanged:
        /// only a fresh cache (a new runtime binding) can pin again.
        case mismatch(expected: String, observed: String)
        /// `stat` or hash failed, the post-hash re-stat moved, the
        /// file exceeds `maxHashBytes`, the cache is full, or (via
        /// `verifyAdmitted`) the path was never pinned: fail closed.
        case unreadable
    }

    private struct Pin: Sendable, Equatable {
        var sha256Hex: String
        var fingerprint: EgressBinaryFingerprint
    }

    /// Process-style bound from OpenShell (4096 paths): past the cap,
    /// new paths refuse to pin and verify as `.unreadable`.
    public static let maxEntries = 4096

    /// Relay-path bound on hashed bytes (CON-1-5): 256 MiB clears the
    /// largest executables observed on the dev host (224 MiB node,
    /// 173 MiB swift-frontend), while a swapped-in huge file refuses
    /// before reading a byte instead of stalling a relay thread to EOF.
    public static let maxHashBytes: UInt64 = 256 * 1024 * 1024

    /// Default `hashFile`: size-gated bounded hash. The path is stated
    /// for its size, sizes past `maxHashBytes` refuse without opening,
    /// and the hash reads at most the stated size — mid-read growth
    /// over-reads the cap and refuses. Same `maxBytes` shape as
    /// `RVDigest.sha256HexOfFile`; mid-read shrink yields a short
    /// digest the post-hash re-stat rejects as `.unreadable`.
    public static func boundedHashOfFile(atPath path: String) -> String? {
        guard let size = EgressBinaryFingerprint.capture(path: path)?.size else { return nil }
        guard size <= maxHashBytes else { return nil }
        return RVDigest.sha256HexOfFile(atPath: path, maxBytes: size)
    }

    private let lock = NSLock()
    private var pins: [String: Pin] = [:]
    private let capture: @Sendable (String) -> EgressBinaryFingerprint?
    private let hashFile: @Sendable (String) -> String?

    public init(
        fingerprint: @escaping @Sendable (String) -> EgressBinaryFingerprint? = EgressBinaryFingerprint.capture,
        hashFile: @escaping @Sendable (String) -> String? = {
            EgressBinaryPinCache.boundedHashOfFile(atPath: $0)
        }
    ) {
        self.capture = fingerprint
        self.hashFile = hashFile
    }

    /// Verify one canonical binary path against its TOFU pin.
    ///
    /// Legacy entry point: an unknown path pins the observed hash and
    /// reports `.pinned`. Bound proxies must call `verifyAdmitted` instead
    /// so a first sighting never both creates the golden and admits the
    /// creating request (REQ-1-1).
    public func verify(canonicalPath path: String) -> Verdict {
        resolve(canonicalPath: path, pinning: true)
    }

    /// Establish the golden pin at admission, before first network use.
    ///
    /// Same outcomes as `verify`: `.pinned` when the golden is established
    /// now, `.match`/`.mismatch` against an existing pin, `.unreadable`
    /// when the path cannot be measured or the cache is full. Admits no
    /// traffic by itself; the bound proxy later calls `verifyAdmitted`,
    /// which denies anything not pinned here (or via `pinExpected`).
    /// A swap between this call and first CONNECT denies as `.mismatch`:
    /// only the admission-time digest can match.
    public func admit(canonicalPath path: String) -> Verdict {
        resolve(canonicalPath: path, pinning: true)
    }

    /// Verify one canonical binary path against its admission-time pin.
    ///
    /// Strict entry point for bound proxies: unknown paths deny as
    /// `.unreadable` WITHOUT creating a golden and without hashing.
    /// Pinned paths behave exactly like `verify` (fingerprint fast-path,
    /// rehash on change, mismatch preserves the golden).
    public func verifyAdmitted(canonicalPath path: String) -> Verdict {
        resolve(canonicalPath: path, pinning: false)
    }

    /// Pin a policy-authored expected SHA-256 digest.
    ///
    /// Trust comes from policy authorship, not observation, but the stored
    /// pair must still be proven self-consistent at trust time: the current
    /// bytes are hashed and must equal the authored digest (with the same
    /// double-stat as `resolve`), so pinning the correct digest over an
    /// already-swapped binary refuses instead of admitting the swapped
    /// file on fingerprint equality alone. Returns false — pinning
    /// nothing — when the digest is not 64 lowercase-or-uppercase hex, the
    /// path cannot be stated or hashed, the bytes do not match the digest,
    /// the path is already pinned, or the cache is full. A golden once
    /// pinned is never overwritten.
    public func pinExpected(canonicalPath path: String, sha256Hex: String) -> Bool {
        let digest = sha256Hex.lowercased()
        guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else { return false }
        guard let observed = capture(path) else { return false }
        guard let actual = hashFile(path), actual == digest else { return false }
        guard let reobserved = capture(path), reobserved == observed else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard pins[path] == nil else { return false }
        guard pins.count < Self.maxEntries else { return false }
        pins[path] = Pin(sha256Hex: digest, fingerprint: observed)
        return true
    }

    /// Shared verify core. When `pinning`, an unknown path pins the
    /// observed hash (TOFU); otherwise unknown paths deny as `.unreadable`
    /// before any hash. Pinned paths always compare, never update on
    /// mismatch — the OpenShell `verify_or_cache` shape. A post-hash
    /// re-stat must still match the pre-hash fingerprint, else the
    /// digest is discarded as `.unreadable` (SEC-1-3 double-stat).
    private func resolve(canonicalPath path: String, pinning: Bool) -> Verdict {
        guard let observed = capture(path) else { return .unreadable }
        lock.lock()
        let existing = pins[path]
        lock.unlock()
        if let existing, existing.fingerprint == observed {
            return .match
        }
        if existing == nil, pinning == false {
            return .unreadable
        }
        guard let digest = hashFile(path) else { return .unreadable }
        // Double-stat (SEC-1-3): the digest is trusted only when the
        // path still fingerprints as it did before the hash. A swap
        // mid-hash denies as `.unreadable` — nothing is pinned, the
        // golden is preserved — instead of pinning mixed bytes against
        // a stale fingerprint.
        guard let reobserved = capture(path), reobserved == observed else { return .unreadable }
        lock.lock()
        defer { lock.unlock() }
        if let current = pins[path] {
            if current.sha256Hex == digest {
                pins[path] = Pin(sha256Hex: digest, fingerprint: observed)
                return .match
            }
            return .mismatch(expected: current.sha256Hex, observed: digest)
        }
        guard pinning, pins.count < Self.maxEntries else { return .unreadable }
        pins[path] = Pin(sha256Hex: digest, fingerprint: observed)
        return .pinned
    }
}
