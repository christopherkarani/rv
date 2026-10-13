#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// CONNECT policy for the filtering egress proxy.
///
/// Contained processes reach only loopback sockets (seatbelt `localhost`
/// rule). Runtimes talk to a loopback proxy that dials external
/// destinations and resolves names itself; clients never supply IPs.
/// External names must be valid multi-label DNS names (no IP literals, no
/// userinfo), and the proxy dials only addresses that pass the
/// public-unicast filter — loopback, private, link-local (including the
/// cloud metadata endpoint), multicast, and reserved ranges never relay,
/// so DNS rebinding buys no lateral capability. Loopback targets are not
/// egress and are admitted separately so local gateways and loopback
/// servers keep working.
public struct EgressHostPolicy: Sendable, Equatable {
    public static let httpsPort = 443
    public static let httpPort = 80

    /// How external (non-loopback) destinations are admitted.
    public enum ExternalMode: Sendable, Equatable {
        /// Exact-host allowlist on one port. Legacy narrow mode.
        case allowlist
        /// Ordinary public development traffic: any valid public DNS name
        /// on the web ports, subject to the proxy's public-unicast dial
        /// filter. No per-host RV patch when a registry, forge, or agent
        /// provider uses another hostname.
        case publicHTTPS
    }

    /// Agent API defaults, each observed from a real agent run: claude and
    /// codex via api.anthropic.com / api.openai.com, ChatGPT-plan codex via
    /// chatgpt.com (backend) and auth.openai.com (OAuth refresh), muse via
    /// api.meta.ai with OAuth at auth.meta.com, opencode via opencode.ai
    /// with its model catalog at models.opencode.ai. Narrow legacy mode;
    /// Standard workspaces use `publicHTTPS`.
    public static let agentAPIs = EgressHostPolicy(
        allowedHosts: [
            "api.anthropic.com", "api.openai.com", "chatgpt.com",
            "auth.openai.com", "api.meta.ai", "auth.meta.com",
            "opencode.ai", "models.opencode.ai",
        ]
    )

    /// Standard-workspace default: generic public web egress.
    public static let publicHTTPS = EgressHostPolicy(
        allowedHosts: [],
        mode: .publicHTTPS
    )

    /// Exact-host allowlist. Allowlist mode only; ignored in
    /// `.publicHTTPS`, which admits any valid public DNS name.
    public var allowedHosts: Set<String>
    /// Single admitted port. Allowlist mode only; ignored in
    /// `.publicHTTPS`, which admits the web ports (80/443).
    public var allowedPort: Int
    public var mode: ExternalMode

    public init(
        allowedHosts: Set<String>,
        allowedPort: Int = httpsPort,
        mode: ExternalMode = .allowlist
    ) {
        self.allowedHosts = allowedHosts
        self.allowedPort = allowedPort
        self.mode = mode
    }

    public func allows(host: String, port: Int) -> Bool {
        switch mode {
        case .allowlist:
            guard port == allowedPort else { return false }
            guard let name = canonicalEgressDNSName(host) else { return false }
            return allowedHosts.contains(name)
        case .publicHTTPS:
            guard port == Self.httpsPort || port == Self.httpPort else { return false }
            return canonicalEgressDNSName(host) != nil
        }
    }

    /// Loopback CONNECT targets on any port. The cage reaches loopback
    /// directly, so proxying there grants no new capability; it only keeps
    /// proxied clients (agents with HTTPS_PROXY set and no NO_PROXY) able
    /// to use local gateways and loopback MCP servers.
    public func allowsLoopbackTarget(host: String, port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        guard let name = canonicalEgressLoopbackName(host) else { return false }
        return name == "localhost" || isEgressLoopbackIPv4(name)
    }
}

/// Canonical absolute path of one admitted egress binary.
///
/// Strict: must start with `/`, contain no NUL, no empty segments (no
/// `//`), no `.`/`..` segments, and no trailing slash. Case is
/// preserved: matching is byte-exact. Symlink resolution is separate
/// (`EgressBinaryAdmission.resolve`): a rule holds the resolved path so
/// a swapped link cannot smuggle a new target under an admitted name.
public struct EgressBinaryRule: Sendable, Equatable, Hashable, Comparable {
    public var path: String

    public init?(canonicalPath path: String) {
        guard Self.isCanonical(path) else { return nil }
        self.path = path
    }

    public static func < (lhs: EgressBinaryRule, rhs: EgressBinaryRule) -> Bool {
        lhs.path < rhs.path
    }

    fileprivate static func isCanonical(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.contains("\0") == false else { return false }
        guard path != "/" else { return true }
        guard path.hasSuffix("/") == false else { return false }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.first == "" else { return false }
        for segment in segments.dropFirst() {
            guard segment.isEmpty == false, segment != ".", segment != ".." else { return false }
        }
        return true
    }
}

/// Binary scope for egress: the OpenShell `binary_allowed` half of
/// `network_policy_for_request = endpoint_allowed + binary_allowed`.
///
/// Empty `rules` means host-level rules only: the proxy evaluates the
/// endpoint policy exactly as before and ignores attribution, so the
/// legacy shared per-workspace-host instance is unaffected. A non-empty
/// set requires the proxy to be bound to one admitted binary resolved at
/// admission; unattributed instances fail closed.
public struct EgressBinaryPolicy: Sendable, Equatable {
    public var rules: Set<EgressBinaryRule>

    public init(rules: Set<EgressBinaryRule> = []) {
        self.rules = rules
    }

    /// Admit exactly these canonical paths, dropping any that are not
    /// canonical (a misconfigured path must not widen scope by accident).
    public init(canonicalPaths paths: [String]) {
        rules = Set(paths.compactMap(EgressBinaryRule.init(canonicalPath:)))
    }

    public var isBinaryScoped: Bool { rules.isEmpty == false }

    /// Deterministic audit order: the matched rule is the minimum, so
    /// logs never depend on set iteration order.
    public var sortedRules: [EgressBinaryRule] { rules.sorted() }

    /// The single matching rule for an observed binary path, if any.
    /// Nil (unattributed peer) never matches.
    public func match(forBinaryPath path: String?) -> EgressBinaryRule? {
        guard let path, let rule = EgressBinaryRule(canonicalPath: path) else { return nil }
        return rules.contains(rule) ? rule : nil
    }

    public func allows(binaryPath path: String?) -> Bool {
        guard isBinaryScoped else { return true }
        return match(forBinaryPath: path) != nil
    }
}

/// Absolute-path resolution for binary rules, applied once at admission.
///
/// Standardizes the path and resolves symlinks exactly like the exec
/// path that later consumes the measurement, so the stored rule names
/// the real executable rather than a link an attacker could swing.
/// Pure path resolution: existence and content binding are the pin
/// cache's job (`EgressBinaryPinCache` fails closed on unreadable).
public enum EgressBinaryAdmission {
    public static func resolve(path raw: String) -> String? {
        guard raw.hasPrefix("/"), raw.contains("\0") == false else { return nil }
        let resolved = (raw as NSString).standardizingPath
        let url = URL(fileURLWithPath: resolved).resolvingSymlinksInPath()
        guard EgressBinaryRule.isCanonical(url.path) else { return nil }
        return url.path
    }
}

/// `stat` identity for one binary: size plus mtime/ctime plus
/// device/inode, mirroring the OpenShell binary fingerprint. A changed
/// fingerprint rehashes; an unchanged fingerprint skips the hash, so the
/// steady-state per-request cost is one `stat`.
public struct EgressBinaryFingerprint: Sendable, Equatable {
    public var size: UInt64
    public var mtimeSeconds: Int64
    public var mtimeNanoseconds: Int64
    public var ctimeSeconds: Int64
    public var ctimeNanoseconds: Int64
    public var device: UInt64
    public var inode: UInt64

    public init(
        size: UInt64,
        mtimeSeconds: Int64,
        mtimeNanoseconds: Int64,
        ctimeSeconds: Int64,
        ctimeNanoseconds: Int64,
        device: UInt64,
        inode: UInt64
    ) {
        self.size = size
        self.mtimeSeconds = mtimeSeconds
        self.mtimeNanoseconds = mtimeNanoseconds
        self.ctimeSeconds = ctimeSeconds
        self.ctimeNanoseconds = ctimeNanoseconds
        self.device = device
        self.inode = inode
    }

    /// Nil when the path cannot be stated (missing, permission, race).
    public static func capture(path: String) -> EgressBinaryFingerprint? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        #if canImport(Darwin)
        let mtime = status.st_mtimespec
        let ctime = status.st_ctimespec
        let device = UInt64(bitPattern: Int64(status.st_dev))
        #else
        let mtime = status.st_mtim
        let ctime = status.st_ctim
        let device = UInt64(status.st_dev)
        #endif
        return EgressBinaryFingerprint(
            size: UInt64(bitPattern: Int64(status.st_size)),
            mtimeSeconds: Int64(mtime.tv_sec),
            mtimeNanoseconds: Int64(mtime.tv_nsec),
            ctimeSeconds: Int64(ctime.tv_sec),
            ctimeNanoseconds: Int64(ctime.tv_nsec),
            device: device,
            inode: UInt64(status.st_ino)
        )
    }
}

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

    /// Pin a policy-authored expected SHA-256 digest without hashing.
    ///
    /// Trust comes from policy authorship, not observation: the digest is
    /// stored as the golden and later bytes must match it. Returns false —
    /// pinning nothing — when the digest is not 64 lowercase-or-uppercase
    /// hex, the path cannot be stated, the path is already pinned, or the
    /// cache is full. A golden once pinned is never overwritten.
    public func pinExpected(canonicalPath path: String, sha256Hex: String) -> Bool {
        let digest = sha256Hex.lowercased()
        guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else { return false }
        guard let observed = capture(path) else { return false }
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

/// The runtime one proxy instance is bound to (per-runtime attribution).
///
/// TCP loopback carries no peer credentials, so attribution is the
/// instance, not the connection: this proxy serves exactly the runtime
/// whose admitted binary was resolved at admission. `binaryPath` must be
/// an `EgressBinaryAdmission.resolve` output; anything else fails the
/// policy match and denies.
public struct EgressRuntimeAttribution: Sendable, Equatable {
    public var binaryPath: String

    public init(binaryPath: String) {
        self.binaryPath = binaryPath
    }
}

/// Opaque identity one egress grant is issued to: the runtime session id or
/// the approval id that earned the rights, as minted by the supervisor. The
/// proxy maps a presented credential to the grant for this principal, so a
/// sibling runtime presenting its own credential is judged against its own
/// grant and never inherits another principal's rights.
public struct EgressPrincipal: Hashable, Sendable, Equatable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Rights granted to one principal: the host policy the proxy judges that
/// principal's requests against. A grant authorizes use of the proxy under
/// this policy only; holding a credential for one grant never widens, reads,
/// or spends another principal's grant.
public struct EgressGrant: Sendable, Equatable {
    public var principal: EgressPrincipal
    public var policy: EgressHostPolicy

    public init(principal: EgressPrincipal, policy: EgressHostPolicy) {
        self.principal = principal
        self.policy = policy
    }
}

/// `localhost` (any case, optional trailing dot) or a dotted quad in
/// 127.0.0.0/8. Bracketed IPv6 is rejected: proxied clients use IPv4
/// loopback, and the seatbelt rule admits the same.
private func canonicalEgressLoopbackName(_ raw: String) -> String? {
    var name = raw
    if name.hasSuffix(".") {
        name.removeLast()
    }
    guard name.isEmpty == false, name.utf8.count <= 253 else { return nil }
    guard name.allSatisfy({ $0.asciiValue != nil }) else { return nil }
    name = name.lowercased()
    if name == "localhost" {
        return name
    }
    let labels = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard labels.count == 4, labels.allSatisfy({ $0.isEmpty == false }) else { return nil }
    for label in labels {
        guard label.count <= 3, label.allSatisfy(isEgressASCIIDigit) else { return nil }
        guard let value = Int(label), value <= 255 else { return nil }
    }
    return name
}

private func isEgressLoopbackIPv4(_ name: String) -> Bool {
    name.split(separator: ".").first == "127"
}

private func canonicalEgressDNSName(_ raw: String) -> String? {
    var name = raw
    if name.hasSuffix(".") {
        name.removeLast()
    }
    guard name.isEmpty == false,
          name.hasPrefix(".") == false,
          name.hasSuffix(".") == false,
          name.contains("..") == false,
          name.utf8.count <= 253
    else { return nil }
    guard name.allSatisfy({ $0.asciiValue != nil }) else { return nil }
    name = name.lowercased()
    let labels = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard labels.count > 1, labels.allSatisfy({ $0.isEmpty == false }) else { return nil }
    for label in labels {
        guard label.count <= 63 else { return nil }
        guard label.first != "-", label.last != "-" else { return nil }
        guard label.allSatisfy(isEgressLDH) else { return nil }
        if label.hasPrefix("0x") { return nil }
        if label.count > 1, label.first == "0", label.allSatisfy(isEgressASCIIDigit) {
            return nil
        }
    }
    if labels.allSatisfy({ $0.allSatisfy(isEgressASCIIDigit) }) { return nil }
    return name
}

private func isEgressLDH(_ character: Character) -> Bool {
    guard let ascii = character.asciiValue else { return false }
    return isEgressASCIIDigit(character) || (ascii >= 97 && ascii <= 122) || ascii == 45
}

private func isEgressASCIIDigit(_ character: Character) -> Bool {
    guard let ascii = character.asciiValue else { return false }
    return ascii >= 48 && ascii <= 57
}
