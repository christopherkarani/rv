#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import RVDomain
import RVFileStore
import RVPolicy
import Synchronization

/// Why one CONNECT was denied. Raw values are the `egress-denials.jsonl`
/// spellings: existing values are preserved, and the old catch-all
/// `dial-failed` now covers only connect failures (DNS and filter
/// refusals record precisely). `denied-credential` covers only credentialed
/// mode: a missing, malformed, or unknown proxy credential.
public enum EgressDenialReason: String, Sendable, Equatable, CaseIterable {
    case headerTooLarge = "header-too-large"
    case deniedPolicy = "denied-policy"
    case deniedCredential = "denied-credential"
    case malformed = "malformed"
    case dnsFailed = "dns-failed"
    case addressFiltered = "address-filtered"
    case dialFailed = "dial-failed"
    /// Binary-scoped policy: the bound runtime binary is not admitted or
    /// its admission-time pin no longer matches (hash changed, unreadable,
    /// never pinned, or the pin cache refused a new entry). Fail closed.
    case binaryMismatch = "binary-mismatch"
    /// Binary-scoped policy on an unattributed proxy instance: no runtime
    /// binding, so no peer can be attributed. Fail closed.
    case unattributedPeer = "unattributed-peer"
    /// The TLS ClientHello named a different server than the CONNECT
    /// authority (or was not TLS with an SNI at all) on a credentialed
    /// proxy, which binds each tunnel to the origin it dials.
    case sniMismatch = "sni-mismatch"
}

/// Unguessable token binding one proxy client to its grant.
///
/// The supervisor mints one credential per runtime (or per approval), maps it
/// to that principal's `EgressGrant`, and delivers the token to that runtime
/// alone over its private channel. Every request through a credentialed proxy
/// must present a mapped token; a sibling runtime holds a different token and
/// is judged against its own grant, so it cannot ride another grant's rights.
/// Equality is constant-time over equal lengths. The token is never written
/// to the denial log.
public struct EgressProxyCredential: Hashable, Sendable {
    public var rawValue: String

    /// Mints a fresh 256-bit token, lowercase hex.
    public init() {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }
        self.rawValue = bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Names a credential the supervisor already minted, for distribution and
    /// tests. Naming a token grants nothing by itself; the proxy maps it to
    /// a grant only when the supervisor configured that mapping.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func == (left: Self, right: Self) -> Bool {
        let a = Array(left.rawValue.utf8)
        let b = Array(right.rawValue.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) {
            diff |= x ^ y
        }
        return diff == 0
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }
}

/// One denied CONNECT, recorded for the allowlist learning loop.
public struct EgressProxyDenial: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var reason: EgressDenialReason
    public var recordedAt: Date
    /// Observed runtime binary for binary-scope denials; nil otherwise.
    public var binaryPath: String?

    public init(
        host: String,
        port: Int,
        reason: EgressDenialReason,
        recordedAt: Date,
        binaryPath: String? = nil
    ) {
        self.host = host
        self.port = port
        self.reason = reason
        self.recordedAt = recordedAt
        self.binaryPath = binaryPath
    }
}

/// Why the egress proxy could not bind. Carries the phase plus the errno
/// (or EAI code) observed there. Callers fail closed; the value exists for
/// diagnostics and tests.
public enum EgressStartError: Error, Sendable, Equatable {
    /// `getaddrinfo("127.0.0.1", "0")` failed; the code is the EAI result.
    case resolveLoopbackFailed(code: Int32)
    case socketFailed(errno: Int32)
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
    case addressFailed(errno: Int32)
}

/// One dial attempt's outcome. The proxy denies the CONNECT either way;
/// the cases exist so tests pin the filter and callers can tell DNS
/// failure from policy filtering from refused connections.
enum DialOutcome: Sendable, Equatable {
    case connected(Int32)
    /// No address resolved: lookup failure, empty answer, or a lookup
    /// that outlived `resolveTimeout` or the resolver budget.
    case dnsFailed
    /// Any resolved address failed the public-unicast filter (external
    /// verdict is consensus over the whole answer set: a mixed answer is
    /// refused without dialing, like the admission GET door).
    case addressFiltered
    /// Every resolved address passed the filter but socket or connect
    /// failed on all of them.
    case connectFailed
}

/// One resolved dial candidate: a copied sockaddr plus the socket parameters
/// `dial` needs. Internal so tests pin the admission verdict with synthetic
/// addresses instead of live DNS.
struct EgressDialCandidate: Sendable {
    var family: Int32
    var socktype: Int32
    var proto: Int32
    var address: sockaddr_storage
    var length: socklen_t
}

/// HTTP CONNECT proxy for contained agent runtimes.
///
/// Binds 127.0.0.1 on an ephemeral port; the cage reaches it through the
/// seatbelt `localhost` rule and can dial nothing else directly. Each
/// CONNECT is admitted by policy (generic public web hosts in Standard
/// mode, or loopback targets on any port) and resolved here, host-side:
/// clients never supply IPs. Resolution happens once per admission, bounded
/// by `resolveTimeout`, and the proxy dials exactly the filtered sockaddr
/// it resolved, so there is no check-to-use race and no pin cache a
/// poisoned first answer can persist in; external names whose answer set
/// is not entirely public-unicast are refused without dialing. Denials are
/// logged; allowed streams relay as opaque bytes. One proxy per runtime
/// (REQ-2-1); `stop` ends new accepts and lets in-flight relays drain.
///
/// Binary scope (per-runtime attribution): TCP loopback carries no peer
/// credentials, so there is deliberately no per-connection PID lookup —
/// attribution is the instance. A proxy bound to one runtime's admitted
/// binary enforces `EgressBinaryPolicy` plus the endpoint policy on every
/// request (OpenShell `endpoint_allowed + binary_allowed`); an unbound
/// instance under a binary-scoped policy fails closed.
///
/// Scope. The shared-loopback interface has no per-workspace isolation, so
/// the open mode below (`init(policy:)`) serves any local process that can
/// reach the port: it is host-loopback-reachable, not a workspace or runtime
/// boundary, and one open instance cannot give co-tenants different rights.
/// Workspace/runtime scoping requires credentialed mode (`init(grants:)`):
/// every request must present a supervisor-mapped credential and is judged
/// against that principal's grant only.
///
/// Residual. The relay is opaque bytes: the proxy cannot verify the origin's
/// TLS identity, so a resolver that controls every answer for a name can
/// still steer one connection to its own address. The backstop is end-to-end
/// TLS verification by the client, which a poisoned address cannot forge.
/// A client that skips hostname verification is exposed by its own choice.
public final class EgressProxy: @unchecked Sendable {
    /// Shared policy for open mode. Nil grants means open mode; non-nil
    /// (even empty, which denies everything) means credentialed mode.
    private let policy: EgressHostPolicy
    private let binaryPolicy: EgressBinaryPolicy
    private let attribution: EgressRuntimeAttribution?
    private let pins: EgressBinaryPinCache
    private let grants: [EgressProxyCredential: EgressGrant]?
    private let record: @Sendable (EgressProxyDenial) -> Void
    /// Resolves one admitted target to the candidate set `dial` checks and
    /// connects. Production is `boundedResolver(budget: resolverBudget)`;
    /// tests inject answers.
    let resolve: @Sendable (String, Int) -> [EgressDialCandidate]
    /// This instance's outstanding-lookup budget. Per proxy (one per
    /// runtime) so one runtime's hung lookups cannot starve another's;
    /// only `EgressResolverBudget.processCeiling` is shared.
    let resolverBudget: EgressResolverBudget
    private let lock = NSLock()
    /// Phase 4 live supplement: human-approved exact host/port rules loaded
    /// without restart. Additive to the startup policy; every admission
    /// still dials through the public-unicast filter, so a supplement
    /// cannot open loopback, LAN, or metadata endpoints.
    private var supplementRules: Set<LiveNetworkRule> = []
    private var supplementGeneration: UInt64 = 0
    private var listenFD: Int32 = -1
    private var running = false
    private let acceptQueue = DispatchQueue(label: "rv.egress.accept", qos: .userInitiated)
    private let relayQueue = DispatchQueue(
        label: "rv.egress.relay", qos: .userInitiated, attributes: .concurrent
    )

    /// Open mode: any local connector is judged against `policy`. This mode
    /// cannot scope rights per runtime or per workspace; prefer
    /// `init(grants:)` wherever co-tenants must not share rights.
    public convenience init(
        policy: EgressHostPolicy = .publicHTTPS,
        binaryPolicy: EgressBinaryPolicy = EgressBinaryPolicy(),
        attribution: EgressRuntimeAttribution? = nil,
        pins: EgressBinaryPinCache = EgressBinaryPinCache(),
        record: (@Sendable (EgressProxyDenial) -> Void)? = nil
    ) {
        self.init(
            policy: policy, grants: nil, binaryPolicy: binaryPolicy, attribution: attribution,
            pins: pins, record: record
        )
    }

    /// Credentialed mode: each request must present a mapped credential and
    /// is judged against that principal's grant only. Missing, malformed, or
    /// unknown credentials are denied with 407 (`denied-credential`) before
    /// policy runs, so an unauthenticated sibling cannot ride any grant.
    /// Binary scope composes: when `binaryPolicy` is scoped, the instance
    /// attribution gate runs before credential authentication in both modes.
    public convenience init(
        grants: [EgressProxyCredential: EgressGrant],
        binaryPolicy: EgressBinaryPolicy = EgressBinaryPolicy(),
        attribution: EgressRuntimeAttribution? = nil,
        pins: EgressBinaryPinCache = EgressBinaryPinCache(),
        record: (@Sendable (EgressProxyDenial) -> Void)? = nil
    ) {
        self.init(
            policy: .publicHTTPS, grants: grants, binaryPolicy: binaryPolicy, attribution: attribution,
            pins: pins, record: record
        )
    }

    /// Designated initializer behind both modes. `grants == nil` is open
    /// mode. Module-internal so tests can inject the resolver or budget;
    /// a nil `resolve` is production `getaddrinfo` under this instance's
    /// own budget.
    init(
        policy: EgressHostPolicy,
        grants: [EgressProxyCredential: EgressGrant]?,
        binaryPolicy: EgressBinaryPolicy = EgressBinaryPolicy(),
        attribution: EgressRuntimeAttribution? = nil,
        pins: EgressBinaryPinCache = EgressBinaryPinCache(),
        record: (@Sendable (EgressProxyDenial) -> Void)?,
        resolverBudget: EgressResolverBudget = EgressResolverBudget(
            limit: EgressResolverBudget.perProxyLimit, parent: .processCeiling
        ),
        resolve: (@Sendable (String, Int) -> [EgressDialCandidate])? = nil
    ) {
        self.policy = policy
        self.binaryPolicy = binaryPolicy
        self.attribution = attribution
        self.pins = pins
        self.grants = grants
        self.record = record ?? EgressProxy.productionDenialLog()
        self.resolverBudget = resolverBudget
        self.resolve = resolve ?? EgressProxy.boundedResolver(budget: resolverBudget)
        admitAttributionPin()
    }

    /// Single-credential spelling for the per-server MCP sandbox proxy:
    /// one principal, judged against `policy`. A nil credential is open
    /// mode. Clients present the token as the proxy URL's userinfo
    /// (`http://<token>@127.0.0.1:<port>`), the same convention the grants
    /// mode parses.
    public convenience init(
        policy: EgressHostPolicy = .publicHTTPS,
        record: (@Sendable (EgressProxyDenial) -> Void)? = nil,
        clientCredential: String?
    ) {
        guard let clientCredential else {
            self.init(policy: policy, record: record)
            return
        }
        self.init(
            grants: [
                EgressProxyCredential(rawValue: clientCredential): EgressGrant(
                    principal: EgressPrincipal(rawValue: "rv:single-credential"),
                    policy: policy
                )
            ],
            record: record
        )
    }

    /// Bound port after `start` succeeds.
    public var port: Int {
        lock.lock()
        defer { lock.unlock() }
        return boundPort
    }

    private var boundPort: Int = 0

    /// Generation the proxy currently enforces (0 until the first push).
    public var currentSupplementGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return supplementGeneration
    }

    /// Whether live supplement rules are enforced by this instance.
    /// Credentialed instances judge every request against the presenting
    /// grant alone (see `supplementAdmits`), so a supplement push loads
    /// but never admits there; supervisors must not record it as loaded.
    public var enforcesSupplement: Bool { grants == nil }

    /// Load a live rule set. Applies only when `generation` is newer than
    /// the enforced one (OpenShell generation guard): stale or reordered
    /// pushes are ignored, so enforcement only ever moves forward.
    /// Returns the enforced generation after the call.
    @discardableResult
    public func updateSupplement(
        _ rules: Set<LiveNetworkRule>,
        generation: UInt64
    ) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if generation > supplementGeneration {
            supplementRules = rules
            supplementGeneration = generation
        }
        return supplementGeneration
    }

    /// Bind 127.0.0.1:0, listen, and serve until `stop`. Returns the bound
    /// port, or the phase plus errno when the socket cannot be established
    /// (fail closed: without a proxy the cage has no route out at all).
    /// Starting a running proxy returns the bound port again.
    public func start() -> Result<Int, EgressStartError> {
        // The lock is held through bind/listen (numeric loopback only, so
        // no resolver wait): start and stop are atomic against each other,
        // concurrent starts cannot leak a listen fd or double the accept
        // loop, and a stop during the bind window cannot be undone when
        // start publishes `running`.
        lock.lock()
        defer { lock.unlock() }
        if running {
            return .success(boundPort)
        }
        var hints = addrinfo()
        memset(&hints, 0, MemoryLayout<addrinfo>.size)
        hints.ai_family = AF_INET
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
        var info: UnsafeMutablePointer<addrinfo>?
        let gai = getaddrinfo("127.0.0.1", "0", &hints, &info)
        guard gai == 0, let first = info else {
            return .failure(.resolveLoopbackFailed(code: gai))
        }
        defer { freeaddrinfo(first) }
        let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard fd >= 0 else { return .failure(.socketFailed(errno: errno)) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        guard bind(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 else {
            let code = errno
            close(fd)
            return .failure(.bindFailed(errno: code))
        }
        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            return .failure(.listenFailed(errno: code))
        }
        var name = sockaddr_storage()
        var nameLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        var savedErrno: Int32 = 0
        let bound: Int = withUnsafeMutablePointer(to: &name) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                guard getsockname(fd, address, &nameLength) == 0 else {
                    savedErrno = errno
                    return 0
                }
                return Int(EgressProxy.port(of: address))
            }
        }
        guard bound > 0 else {
            close(fd)
            return .failure(.addressFailed(errno: savedErrno))
        }
        listenFD = fd
        boundPort = bound
        running = true
        acceptQueue.async { [weak self] in self?.acceptLoop(listen: fd) }
        return .success(bound)
    }

    public func stop() {
        lock.lock()
        running = false
        let fd = listenFD
        listenFD = -1
        boundPort = 0
        lock.unlock()
        // shutdown() first: close() alone does not wake the thread blocked
        // in accept() on Darwin, which would park it (and the listening
        // socket) for the life of the process.
        if fd >= 0 {
            shutdown(fd, Int32(SHUT_RDWR))
            close(fd)
        }
    }

    deinit {
        stop()
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Serves exactly the listen fd `start` bound. The fd is passed by
    /// value and never re-read from shared state: re-reading after a
    /// concurrent `stop()` closed the number could accept on a reused fd
    /// belonging to a sibling runtime's listener and serve that client
    /// under this proxy's grant. Ownership: `stop()` owns closing
    /// `listen`; this loop owns every accepted fd until `serve` takes it.
    private func acceptLoop(listen: Int32) {
        while isRunning() {
            var peer = sockaddr_storage()
            var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            var acceptError: Int32 = 0
            let fd: Int32 = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    let accepted = accept(listen, address, &peerLength)
                    if accepted < 0 { acceptError = errno }
                    return accepted
                }
            }
            // stop() may have run while blocked in accept (its shutdown
            // wakes us). If the fd number was already reused, a successful
            // accept may hold a sibling's client: close it unserved.
            lock.lock()
            let stillMine = running && listenFD == listen
            lock.unlock()
            guard stillMine else {
                if fd >= 0 { close(fd) }
                return
            }
            guard fd >= 0 else {
                // Accept failures are abnormal; surface the errno instead
                // of spinning silently (under load these would otherwise
                // surface only as client-side timeouts).
                Self.complain("rv.egress: accept failed errno=\(acceptError)")
                usleep(50_000)
                continue
            }
            relayQueue.async { [weak self] in
                guard let self else {
                    close(fd)
                    return
                }
                self.serve(client: fd)
            }
        }
    }

    private func serve(client: Int32) {
        EgressProxy.suppressSIGPIPE(client)
        EgressProxy.setTimeout(client, seconds: 10)
        switch EgressProxy.readHeaders(client, maximumBytes: 65_536) {
        case .failure:
            close(client)
            return
        case .oversized:
            deny(client: client, host: "", port: 0, reason: .headerTooLarge)
            return
        case .success(let header, let leftover):
            serveRequest(client: client, header: header, leftover: leftover)
        }
    }

    /// Shell around the pure admission ladder: parse, gather the effectful
    /// inputs as values, decide, then execute the verdict.
    private func serveRequest(client: Int32, header: String, leftover: [UInt8]) {
        let shape: EgressRequestShape
        let target: EgressTarget
        if let parsed = EgressWire.parseCONNECT(header: header) {
            shape = .connect
            target = EgressTarget(host: parsed.host, port: parsed.port)
        } else if let parsed = EgressWire.parseAbsoluteHTTP(header: header) {
            // Absolute-URI is the plaintext shape: loopback gateways and
            // servers (the cage reaches loopback directly, so relaying grants
            // no new capability) plus public port-80 traffic under the same
            // policy and public-unicast dial filter as CONNECT. Tunneling
            // plaintext grants no capability that tunneling TLS does not.
            shape = .absoluteHTTP
            target = EgressTarget(host: parsed.host, port: parsed.port)
        } else {
            deny(client: client, host: "", port: 0, reason: .malformed)
            return
        }
        let credential = admissionCredential(header: header)
        // Authenticate before the binary gate: an unauthenticated caller
        // must not trigger per-request rehashing (up to the 256 MiB bound
        // on the mismatch path) or learn binary state from a 403-vs-407
        // distinction. The gate is only evaluated for authenticated callers.
        let binaryGateDenial: EgressBinaryGateDenial?
        if case .rejected = credential {
            binaryGateDenial = nil
        } else {
            binaryGateDenial = binaryGate()
        }
        let verdict = EgressAdmission.decide(
            target: target,
            shape: shape,
            credential: credential,
            binaryGateDenial: binaryGateDenial,
            supplementAllows: supplementAdmits(host: target.host, port: target.port)
        )
        switch verdict {
        case .deny(.deniedCredential, _):
            denyProxyAuthRequired(client: client, host: target.host, port: target.port)
        case .deny(let reason, let binaryPath):
            deny(client: client, host: target.host, port: target.port, reason: reason, binaryPath: binaryPath)
        case .tunnel(let external, let requireSNI):
            tunnel(client: client, target: target, leftover: leftover, external: external, requireSNI: requireSNI)
        case .forward(let external):
            forward(client: client, header: header, target: target, leftover: leftover, external: external)
        }
    }

    /// Executes an admitted CONNECT.
    private func tunnel(client: Int32, target: EgressTarget, leftover: [UInt8], external: Bool, requireSNI: Bool) {
        // A `requireSNI` tunnel (credentialed allowlist, external, TLS port)
        // is bound to the origin it dials: the ClientHello's SNI must be
        // that host, so a co-hosted tenant on the same address is not
        // reachable through it. The 200 goes first (clients wait for it
        // before starting TLS), then the first record is read and checked
        // before dialing.
        var hello = leftover
        var established = false
        if requireSNI {
            guard EgressProxy.writeAll(client, bytes: Array("HTTP/1.1 200 Connection established\r\n\r\n".utf8)) else {
                close(client)
                return
            }
            established = true
            guard let first = EgressProxy.readClientHello(client: client, initial: leftover),
                EgressAdmission.checkSNI(expectedHost: target.host, serverName: EgressWire.tlsServerName(first)) == nil
            else {
                close(client)
                record(EgressProxyDenial(host: target.host, port: target.port, reason: .sniMismatch, recordedAt: Date()))
                return
            }
            hello = first
        }
        guard
            let upstream = dialUpstream(
                host: target.host,
                port: target.port,
                external: external,
                client: client,
                established: established
            )
        else {
            return
        }
        EgressProxy.suppressSIGPIPE(upstream)
        guard (established || EgressProxy.writeAll(client, bytes: Array("HTTP/1.1 200 Connection established\r\n\r\n".utf8))),
            hello.isEmpty || EgressProxy.writeAll(upstream, bytes: hello)
        else {
            close(client)
            close(upstream)
            return
        }
        EgressProxy.setTimeout(client, seconds: 0)
        EgressProxy.setTimeout(upstream, seconds: 0)
        relay(client: client, upstream: upstream)
    }

    /// Executes an admitted absolute-URI request.
    private func forward(client: Int32, header: String, target: EgressTarget, leftover: [UInt8], external: Bool) {
        guard
            let upstream = dialUpstream(
                host: target.host,
                port: target.port,
                external: external,
                client: client
            )
        else {
            return
        }
        EgressProxy.suppressSIGPIPE(upstream)
        // Origin servers accept absolute-URI (RFC 7230 5.3.2): forward the
        // request with hop-by-hop proxy credentials consumed (LEAK-1: the
        // authenticated Proxy-Authorization field must not travel upstream),
        // then relay both directions.
        let forwarded = EgressProxy.stripProxyAuthorization(header: header)
        guard EgressProxy.writeAll(upstream, bytes: Array(forwarded.utf8) + leftover) else {
            close(client)
            close(upstream)
            return
        }
        EgressProxy.setTimeout(client, seconds: 0)
        EgressProxy.setTimeout(upstream, seconds: 0)
        relay(client: client, upstream: upstream)
    }

    /// Establish the golden pin at bind time: construction of a bound
    /// instance is the admission moment for a per-runtime proxy, so the
    /// bytes measured here — not first-CONNECT bytes — are the trusted
    /// ones (OpenShell trust fixed at creation:
    /// https://docs.nvidia.com/openshell/latest/how-it-works/policies/manage-policies).
    /// Admits exactly when the gate below would consult the pin (scoped +
    /// attributed + policy match), so unbound instances and policy
    /// mismatches never `stat`/hash. A failed admission pins nothing and
    /// every request then denies fail-closed via `verifyAdmitted`.
    private func admitAttributionPin() {
        guard binaryPolicy.isBinaryScoped else { return }
        guard let attribution else { return }
        guard binaryPolicy.match(forBinaryPath: attribution.binaryPath) != nil else { return }
        _ = pins.admit(canonicalPath: attribution.binaryPath)
    }

    /// Binary-scope verdict for one parsed request. Nil admits to the
    /// endpoint policy. Runs per request (not once at bind) so a binary
    /// swapped mid-runtime denies from the next CONNECT on; the pin
    /// cache makes the steady-state cost one `stat` per request.
    /// Verifies against the admission-time pin only: unknown paths deny
    /// without pinning, so a first sighting never both creates the golden
    /// and admits the creating request (OpenShell `verify_or_cache`
    /// compare/update shape:
    /// https://raw.githubusercontent.com/NVIDIA/OpenShell/f88aecfd92e02cb1b5388041f09930d78065979a/crates/navigator-sandbox/src/identity.rs).
    private func binaryGate() -> EgressBinaryGateDenial? {
        guard binaryPolicy.isBinaryScoped else { return nil }
        guard let attribution else {
            return EgressBinaryGateDenial(reason: .unattributedPeer, binaryPath: nil)
        }
        guard binaryPolicy.match(forBinaryPath: attribution.binaryPath) != nil else {
            return EgressBinaryGateDenial(reason: .binaryMismatch, binaryPath: attribution.binaryPath)
        }
        switch pins.verifyAdmitted(canonicalPath: attribution.binaryPath) {
        case .pinned, .match:
            return nil
        case .mismatch, .unreadable:
            return EgressBinaryGateDenial(reason: .binaryMismatch, binaryPath: attribution.binaryPath)
        }
    }

    /// Exact live-rule match on canonical host plus port. Supplement rules
    /// are DNS-only by construction and always dial the filtered external
    /// path, so this admits no loopback, LAN, or metadata target.
    /// Open mode only: supplement rules are instance-wide, so honoring them
    /// in credentialed mode would let one principal ride a rule approved for
    /// another. Credentialed requests are judged against their grant alone.
    private func supplementAdmits(host: String, port: Int) -> Bool {
        guard grants == nil else { return false }
        guard let rule = LiveNetworkRule(host: host, port: port) else {
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        return supplementRules.contains(rule)
    }

    private func deny(
        client: Int32,
        host: String,
        port: Int,
        reason: EgressDenialReason,
        binaryPath: String? = nil
    ) {
        _ = EgressProxy.writeAll(client, bytes: Array("HTTP/1.1 403 Forbidden\r\n\r\n".utf8))
        close(client)
        record(
            EgressProxyDenial(
                host: host,
                port: port,
                reason: reason,
                recordedAt: Date(),
                binaryPath: binaryPath
            )
        )
    }

    /// Policy judging this request: the shared policy in open mode, or the
    /// presenting credential's grant in credentialed mode; `.rejected` when
    /// credentialed mode cannot authenticate the request (the verdict then
    /// answers 407). The presented token is never logged.
    private func admissionCredential(header: String) -> EgressAdmissionCredential {
        guard let grants else { return .open(policy) }
        guard let token = Self.proxyCredentialToken(header: header),
            let grant = grants[EgressProxyCredential(rawValue: token)]
        else {
            return .rejected
        }
        return .granted(grant.policy)
    }

    private func denyProxyAuthRequired(client: Int32, host: String, port: Int) {
        _ = EgressProxy.writeAll(
            client,
            bytes: Array(
                "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Bearer\r\nConnection: close\r\n\r\n"
                    .utf8
            )
        )
        close(client)
        record(EgressProxyDenial(host: host, port: port, reason: .deniedCredential, recordedAt: Date()))
    }

    /// Presented proxy credential from a header block, or nil when absent or
    /// malformed. Accepts `Bearer <token>` and `Basic base64("<token>:...")`
    /// (the username carries the token: stock HTTP clients send `*_PROXY`
    /// URL userinfo as Basic). The first `Proxy-Authorization` field wins;
    /// field name match is case-insensitive, the token never crosses a line.
    static func proxyCredentialToken(header: String) -> String? {
        for line in header.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard name.lowercased() == "proxy-authorization" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard value.isEmpty == false else { return nil }
            let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { return nil }
            let scheme = parts[0].lowercased()
            let parameter = String(parts[1])
            if scheme == "bearer" {
                return validToken(parameter)
            }
            if scheme == "basic" {
                guard let decoded = Data(base64Encoded: parameter),
                    let pair = String(data: decoded, encoding: .utf8),
                    let mark = pair.firstIndex(of: ":")
                else {
                    return nil
                }
                return validToken(String(pair[..<mark]))
            }
            return nil
        }
        return nil
    }

    /// Hop-by-hop proxy credential removal for upstream forwards (LEAK-1,
    /// RFC 7235 section 3.2: a proxy MUST NOT forward Proxy-Authorization).
    /// Drops every `Proxy-Authorization` field line plus its obs-fold
    /// continuations, using the same name match as `proxyCredentialToken`
    /// (case-insensitive, trimmed) extended to colon-less malformed lines;
    /// all other bytes round-trip unchanged, so a header without the field
    /// is byte-identical after stripping.
    static func stripProxyAuthorization(header: String) -> String {
        var kept: [String] = []
        kept.reserveCapacity(16)
        var droppingContinuation = false
        for line in header.components(separatedBy: "\r\n") {
            if droppingContinuation, line.hasPrefix(" ") || line.hasPrefix("\t") {
                continue
            }
            droppingContinuation = false
            if isProxyAuthorizationLine(line) {
                droppingContinuation = true
                continue
            }
            kept.append(line)
        }
        return kept.joined(separator: "\r\n")
    }

    private static func isProxyAuthorizationLine(_ line: String) -> Bool {
        let lower = line.trimmingCharacters(in: .whitespaces).lowercased()
        guard lower.hasPrefix("proxy-authorization") else {
            return false
        }
        let rest = lower.dropFirst("proxy-authorization".count)
        return rest.isEmpty || rest.first == ":" || rest.first == " " || rest.first == "\t"
    }

    /// Non-empty token without whitespace or controls. Minted tokens are
    /// lowercase hex; anything else fails the grant lookup safely, but
    /// rejecting smuggling shapes here keeps the comparison input clean.
    private static func validToken(_ raw: String) -> String? {
        guard raw.isEmpty == false, raw.utf8.count <= 256 else { return nil }
        guard raw.allSatisfy({ character in
            guard let ascii = character.asciiValue else { return false }
            return ascii > 32 && ascii < 127
        }) else {
            return nil
        }
        return raw
    }

    /// Dials for a relay, denying with the precise reason on failure.
    /// Returns nil after denying; shared by the CONNECT and absolute-URI
    /// paths so the outcome mapping lives in one place. When the tunnel
    /// is already established (the SNI-checked path already sent 200),
    /// failure just closes and records instead of writing a 403 into a
    /// tunnel the client believes is open.
    private func dialUpstream(host: String, port: Int, external: Bool, client: Int32, established: Bool = false) -> Int32? {
        let reason: EgressDenialReason
        switch EgressProxy.dial(host: host, port: port, external: external, resolve: resolve) {
        case .connected(let fd):
            return fd
        case .dnsFailed:
            reason = .dnsFailed
        case .addressFiltered:
            reason = .addressFiltered
        case .connectFailed:
            reason = .dialFailed
        }
        if established {
            close(client)
            record(EgressProxyDenial(host: host, port: port, reason: reason, recordedAt: Date()))
        } else {
            deny(client: client, host: host, port: port, reason: reason)
        }
        return nil
    }

    private func relay(client: Int32, upstream: Int32) {
        let group = DispatchGroup()
        let activity = Mutex(Date())
        group.enter()
        relayQueue.async { [weak self] in
            EgressProxy.copy(from: client, to: upstream, activity: activity, shouldStop: { self?.isRunning() != true })
            group.leave()
        }
        group.enter()
        relayQueue.async { [weak self] in
            EgressProxy.copy(from: upstream, to: client, activity: activity, shouldStop: { self?.isRunning() != true })
            group.leave()
        }
        group.notify(queue: relayQueue) {
            shutdown(client, Int32(SHUT_RDWR))
            shutdown(upstream, Int32(SHUT_RDWR))
            close(client)
            close(upstream)
        }
    }

    private enum HeaderRead {
        case success(header: String, leftover: [UInt8])
        case oversized
        case failure
    }

    private static func readHeaders(_ fd: Int32, maximumBytes: Int) -> HeaderRead {
        var bytes = [UInt8]()
        bytes.reserveCapacity(4096)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while bytes.count < maximumBytes {
            var readError: Int32 = 0
            let count = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                let received = recv(fd, base, pointer.count, 0)
                if received < 0 { readError = errno }
                return received
            }
            if count < 0 {
                if readError == EINTR { continue }
                return .failure
            }
            if count == 0 { return .failure }
            bytes.append(contentsOf: buffer[..<count])
            if let split = splitHeaders(bytes) {
                return .success(header: split.header, leftover: split.leftover)
            }
        }
        return .oversized
    }

    /// Header text through the first blank line plus any already-read bytes
    /// after it. A client that pipelines tunnel bytes with the CONNECT must
    /// not lose them. Non-UTF-8 headers never split and fail oversized
    /// instead: denied either way.
    private static func splitHeaders(_ bytes: [UInt8]) -> (header: String, leftover: [UInt8])? {
        guard bytes.count >= 4 else { return nil }
        for end in 4...bytes.count {
            let tail = bytes[(end - 4)..<end]
            if tail.elementsEqual([13, 10, 13, 10]) {
                guard let header = String(bytes: bytes[..<end], encoding: .utf8) else {
                    return nil
                }
                return (header, Array(bytes[end...]))
            }
        }
        return nil
    }

    /// Resolves one relay target to copied sockaddrs. The port is baked into
    /// each sockaddr by `getaddrinfo`, as before; `dial` connects exactly
    /// these addresses without resolving again.
    static func resolveDialCandidates(host: String, port: Int) -> [EgressDialCandidate] {
        var hints = addrinfo()
        memset(&hints, 0, MemoryLayout<addrinfo>.size)
        hints.ai_family = AF_UNSPEC
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else {
            return []
        }
        defer { freeaddrinfo(first) }
        var candidates: [EgressDialCandidate] = []
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let node = current {
            if let source = node.pointee.ai_addr, node.pointee.ai_addrlen > 0,
                node.pointee.ai_addrlen <= socklen_t(MemoryLayout<sockaddr_storage>.size)
            {
                var storage = sockaddr_storage()
                withUnsafeMutableBytes(of: &storage) { target in
                    let sourceBytes = UnsafeRawBufferPointer(
                        start: UnsafeRawPointer(source),
                        count: Int(node.pointee.ai_addrlen)
                    )
                    target.copyMemory(from: sourceBytes)
                }
                candidates.append(
                    EgressDialCandidate(
                        family: node.pointee.ai_family,
                        socktype: node.pointee.ai_socktype,
                        proto: node.pointee.ai_protocol,
                        address: storage,
                        length: node.pointee.ai_addrlen
                    )
                )
            }
            current = node.pointee.ai_next
        }
        return candidates
    }

    static func dial(host: String, port: Int, external: Bool) -> DialOutcome {
        dial(host: host, port: port, external: external, resolve: boundedResolver(budget: .processCeiling))
    }

    /// Longest the proxy waits for one name to resolve. `getaddrinfo` has no
    /// timeout of its own; past this the request is denied `dns-failed`.
    static let resolveTimeout: DispatchTimeInterval = .seconds(10)

    /// Production resolver: `getaddrinfo` under `resolveTimeout` and
    /// `budget` (a proxy's own budget, which also draws on the process
    /// ceiling).
    static func boundedResolver(
        budget: EgressResolverBudget
    ) -> @Sendable (String, Int) -> [EgressDialCandidate] {
        { host, port in
            resolveWithDeadline(
                host: host, port: port, timeout: resolveTimeout, budget: budget, resolve: resolveDialCandidates
            )
        }
    }

    /// Runs `resolve` off the calling thread and waits at most `timeout`.
    /// Fails closed with an empty answer (which `dial` records as
    /// `dns-failed`) when the lookup is late or the budget is spent. A late
    /// lookup keeps its budget slot until it returns, so a resolver that
    /// hangs every query cannot pile up unbounded blocked threads; its
    /// answer is dropped, never dialed. While the deadline runs a lookup
    /// costs two threads (this caller waiting, a worker in `getaddrinfo`);
    /// past it only the worker stays blocked, bounded by the budget.
    static func resolveWithDeadline(
        host: String,
        port: Int,
        timeout: DispatchTimeInterval,
        budget: EgressResolverBudget,
        resolve: @escaping @Sendable (String, Int) -> [EgressDialCandidate]
    ) -> [EgressDialCandidate] {
        guard budget.acquire() else { return [] }
        let answer = Mutex<[EgressDialCandidate]?>(nil)
        let done = DispatchSemaphore(value: 0)
        let lookup = { @Sendable in
            let candidates = resolve(host, port)
            answer.withLock { $0 = candidates }
            budget.release()
            done.signal()
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: lookup)
        guard done.wait(timeout: .now() + timeout) == .success else { return [] }
        return answer.withLock { $0 } ?? []
    }

    /// Dial one relay upstream. `external == false` replaces the
    /// public-unicast filter with a loopback-only candidate check, so it
    /// is only valid for hosts the policy already admitted via
    /// `allowsLoopbackTarget`; both directions verify every resolved
    /// candidate, never just the name.
    ///
    /// The external verdict is consensus over the whole answer set, mirroring
    /// the admission GET door (`selectHTTPAddresses`): when any resolved
    /// address fails the public-unicast filter the name is refused without
    /// dialing, so a resolver that can poison or mix one answer into the set
    /// cannot steer the relay onto a remaining address. A compromised
    /// resolver must not rebind an admitted name onto loopback, LAN,
    /// link-local, or metadata addresses and have the proxy relay there.
    /// The dialed sockaddr is the filtered one, so there is no
    /// check-to-use race.
    static func dial(
        host: String,
        port: Int,
        external: Bool,
        resolve: (String, Int) -> [EgressDialCandidate]
    ) -> DialOutcome {
        let candidates = resolve(host, port)
        guard candidates.isEmpty == false else { return .dnsFailed }
        if external {
            for candidate in candidates {
                var storage = candidate.address
                let publicUnicast = withUnsafePointer(to: &storage) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1, isPublicUnicast)
                }
                if publicUnicast == false {
                    return .addressFiltered
                }
            }
        } else {
            // Loopback dials verify the candidates, not just the name:
            // a resolver that answers `localhost` with a non-loopback
            // address (search-domain expansion, misconfiguration) must
            // not turn the name check into an unfiltered dial.
            for candidate in candidates {
                var storage = candidate.address
                let loopback = withUnsafePointer(to: &storage) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1, isLoopbackAddress)
                }
                if loopback == false {
                    return .addressFiltered
                }
            }
        }
        for candidate in candidates {
            let fd = socket(candidate.family, candidate.socktype, candidate.proto)
            if fd >= 0 {
                var storage = candidate.address
                let connected = withUnsafePointer(to: &storage) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                        connectWithTimeout(
                            fd, address: address, length: candidate.length, seconds: 10
                        )
                    }
                }
                if connected {
                    return .connected(fd)
                }
                close(fd)
            }
        }
        return .connectFailed
    }

    /// True when `address` is loopback: 127.0.0.0/8, ::1, or an
    /// IPv4-mapped loopback. Unknown families fail closed.
    static func isLoopbackAddress(_ address: UnsafePointer<sockaddr>?) -> Bool {
        guard let address else { return false }
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { socket in
                UInt32(bigEndian: socket.pointee.sin_addr.s_addr) & 0xFF00_0000 == 0x7F00_0000
            }
        case AF_INET6:
            return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { socket in
                withUnsafeBytes(of: socket.pointee.sin6_addr) { raw in
                    guard raw.count == 16 else { return false }
                    let bytes = (0..<16).map { raw[$0] }
                    if bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes[15] == 1 {
                        return true
                    }
                    if Array(bytes.prefix(12)) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF] {
                        return bytes[12] == 127
                    }
                    return false
                }
            }
        default:
            return false
        }
    }

    /// True when `address` is a globally routable unicast destination.
    /// Rejects loopback, unspecified, private, CGNAT, link-local,
    /// site-local, unique-local, cloud metadata, multicast, reserved,
    /// documentation, and benchmarking ranges, recursing into the embedded
    /// IPv4 of mapped, translated, compatible, 6to4, and NAT64 addresses.
    /// Unknown families fail closed.
    static func isPublicUnicast(_ address: UnsafePointer<sockaddr>?) -> Bool {
        guard let address else { return false }
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { socket in
                EgressWire.isPublicIPv4(UInt32(bigEndian: socket.pointee.sin_addr.s_addr))
            }
        case AF_INET6:
            return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { socket in
                withUnsafeBytes(of: socket.pointee.sin6_addr) { raw in
                    EgressWire.isPublicIPv6(Array(raw))
                }
            }
        default:
            return false
        }
    }

    private static func connectWithTimeout(
        _ fd: Int32,
        address: UnsafePointer<sockaddr>?,
        length: socklen_t,
        seconds: Int
    ) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return false }
        let result = connect(fd, address, length)
        if result == 0 {
            _ = fcntl(fd, F_SETFL, flags)
            return true
        }
        guard errno == EINPROGRESS else { return false }
        var item = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&item, 1, Int32(seconds * 1000))
        guard ready > 0 else { return false }
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
            return false
        }
        _ = fcntl(fd, F_SETFL, flags)
        return true
    }

    /// Reads exactly one TLS record (the ClientHello) from a just-established
    /// CONNECT client, starting from bytes already read past the headers.
    /// The client's 10-second socket timeout bounds the wait. Nil on EOF,
    /// error, a non-handshake first byte, or an oversized record.
    static func readClientHello(client: Int32, initial: [UInt8]) -> [UInt8]? {
        var bytes = initial
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            if bytes.count >= 5 {
                guard bytes[0] == 0x16 else { return nil }
                let length = Int(bytes[3]) << 8 | Int(bytes[4])
                guard length <= 16_384 else { return nil }
                if bytes.count >= 5 + length { return bytes }
            }
            guard bytes.count <= 16_389 else { return nil }
            let count = chunk.withUnsafeMutableBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                return recv(client, base, pointer.count, 0)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            bytes += chunk[..<count]
        }
    }

    private static func copy(from source: Int32, to destination: Int32, activity: borrowing Mutex<Date>, shouldStop: @escaping () -> Bool) {
        var buffer = [UInt8](repeating: 0, count: 32_768)
        while shouldStop() == false {
            var item = pollfd(fd: source, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, 1000)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 {
                // Idle bound shared by both directions: a tunnel neither
                // side speaks on for an hour is closed instead of holding
                // descriptors forever.
                if activity.withLock({ Date().timeIntervalSince($0) }) >= 3600 { break }
                continue
            }
            activity.withLock { $0 = Date() }
            if item.revents & Int16(POLLERR | POLLNVAL) != 0 { break }
            let count = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                return recv(source, base, pointer.count, 0)
            }
            if count <= 0 { break }
            if writeAll(destination, bytes: Array(buffer[..<count])) == false { break }
            if item.revents & Int16(POLLHUP) != 0 { break }
        }
        shutdown(source, Int32(SHUT_RD))
        shutdown(destination, Int32(SHUT_WR))
    }

    @discardableResult
    private static func writeAll(_ fd: Int32, bytes: [UInt8]) -> Bool {
        #if canImport(Darwin)
        let flags: Int32 = 0
        #else
        let flags = Int32(MSG_NOSIGNAL)
        #endif
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                return send(fd, base.advanced(by: offset), bytes.count - offset, flags)
            }
            if written <= 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }

    /// A `send` on a closed peer must fail, not kill the host with SIGPIPE.
    /// Linux sends with MSG_NOSIGNAL per call instead.
    private static func suppressSIGPIPE(_ fd: Int32) {
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    private static func setTimeout(_ fd: Int32, seconds: Int) {
        var value = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func port(of address: UnsafePointer<sockaddr>) -> UInt16 {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { socket in
                UInt16(bigEndian: socket.pointee.sin_port)
            }
        case AF_INET6:
            return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { socket in
                UInt16(bigEndian: socket.pointee.sin6_port)
            }
        default:
            return 0
        }
    }

    private static func complain(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// Module-visible so the supervisor can chain review-queue intake
    /// ahead of the production denial log without replacing it.
    static func productionDenialLog() -> @Sendable (EgressProxyDenial) -> Void {
        { denial in
            recordDenial(denial)
        }
    }

    private static func recordDenial(_ denial: EgressProxyDenial) {
        guard let configDirectory = HomeDirectory.processConfigDirectory() else {
            complain("rv.egress: denial log skipped (HOME unavailable) host=\(denial.host) reason=\(denial.reason.rawValue)")
            return
        }
        _ = writeDenial(
            denial, to: RVPolicyPaths.egressDenialsFile(inConfigDir: configDirectory), diagnose: complain
        )
    }

    /// Appends one denial line to `url`. Returns true only when the line is
    /// persisted. Every failure path reports through `diagnose` (stderr in
    /// production) instead of dropping the record silently: the CONNECT was
    /// already denied either way, so enforcement stays fail-closed and only
    /// the audit persistence can fail.
    @discardableResult
    static func writeDenial(
        _ denial: EgressProxyDenial,
        to url: URL,
        diagnose: (String) -> Void
    ) -> Bool {
        var record = [
            "host": denial.host,
            "port": String(denial.port),
            "reason": denial.reason.rawValue,
            "recordedAt": String(denial.recordedAt.timeIntervalSince1970),
        ]
        if let binaryPath = denial.binaryPath {
            record["binary"] = binaryPath
        }
        guard let data = try? JSONSerialization.data(withJSONObject: record),
            let line = String(data: data, encoding: .utf8)
        else {
            diagnose("rv.egress: denial log encode failed host=\(denial.host) reason=\(denial.reason.rawValue)")
            return false
        }
        do {
            try JSONLAppendLog.append(Data(line.utf8), to: url, sync: false)
            return true
        } catch {
            let detail: String
            switch error {
            case .directory: detail = "directory failed path=\(url.path)"
            case .lock(let code): detail = "lock failed path=\(url.path) errno=\(code)"
            case .open(let code): detail = "create failed path=\(url.path) errno=\(code)"
            case .notRegularFile: detail = "create failed path=\(url.path) error=not a regular file"
            case .write(let code): detail = "append failed path=\(url.path) errno=\(code)"
            case .sync(let code): detail = "sync failed path=\(url.path) errno=\(code)"
            }
            diagnose("rv.egress: denial log \(detail)")
            return false
        }
    }
}

/// Caps how many host lookups may be outstanding at once. A lookup that
/// outlives the proxy's deadline still holds its slot until `getaddrinfo`
/// returns; once the budget is spent, new requests deny `dns-failed`
/// without resolving. Each proxy owns a `perProxyLimit` budget whose
/// `parent` is `processCeiling`, so a runtime that hangs its own lookups
/// exhausts only its own slots while total blocked threads stay bounded.
final class EgressResolverBudget: Sendable {
    static let perProxyLimit = 32
    static let processCeiling = EgressResolverBudget(limit: 128)

    let limit: Int
    /// Also charged on every acquire; nil for a root budget.
    let parent: EgressResolverBudget?
    private let inFlight = Mutex(0)

    init(limit: Int, parent: EgressResolverBudget? = nil) {
        self.limit = limit
        self.parent = parent
    }

    func acquire() -> Bool {
        let local = inFlight.withLock { count in
            guard count < limit else { return false }
            count += 1
            return true
        }
        guard local else { return false }
        guard parent?.acquire() ?? true else {
            inFlight.withLock { $0 -= 1 }
            return false
        }
        return true
    }

    func release() {
        inFlight.withLock { $0 -= 1 }
        parent?.release()
    }
}
