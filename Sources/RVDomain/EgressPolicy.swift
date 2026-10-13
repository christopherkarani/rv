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

    /// Exact-host allowlist, canonicalized at construction (entries that
    /// never canonicalize drop instead of silently never matching).
    /// Allowlist mode only; ignored in `.publicHTTPS`, which admits any
    /// valid public DNS name.
    public private(set) var allowedHosts: Set<String>
    /// Single admitted port. Allowlist mode only; ignored in
    /// `.publicHTTPS`, which admits the web ports (80/443).
    public private(set) var allowedPort: Int
    public private(set) var mode: ExternalMode

    public init(
        allowedHosts: Set<String>,
        allowedPort: Int = httpsPort,
        mode: ExternalMode = .allowlist
    ) {
        self.allowedHosts = Set(allowedHosts.compactMap(canonicalEgressDNSName))
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
    public private(set) var path: String

    public init?(canonicalPath path: String) {
        guard Self.isCanonical(path) else { return nil }
        self.path = path
    }

    public static func < (lhs: EgressBinaryRule, rhs: EgressBinaryRule) -> Bool {
        lhs.path < rhs.path
    }

    fileprivate static func isCanonical(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.contains("\0") == false else { return false }
        // The root directory is not a binary; it could never fingerprint
        // or verify, so it is unrepresentable rather than a dead rule.
        guard path != "/" else { return false }
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
    public private(set) var rules: Set<EgressBinaryRule>

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

    /// Nil when the path cannot be stated (missing, permission, race) or
    /// is not a regular file: a swapped-in FIFO or device must fail closed
    /// here instead of blocking the hashing thread on open/read.
    public static func capture(path: String) -> EgressBinaryFingerprint? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        guard status.st_mode & S_IFMT == S_IFREG else { return nil }
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
