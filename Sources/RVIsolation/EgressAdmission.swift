import RVDomain

/// One parsed proxy request target: the authority the client asked for.
struct EgressTarget: Sendable, Equatable {
    var host: String
    var port: Int
}

/// Which request form the proxy parsed: a CONNECT tunnel or a plaintext
/// absolute-URI request.
enum EgressRequestShape: Sendable, Equatable {
    case connect
    case absoluteHTTP
}

/// Outcome of credential lookup, gathered by the proxy before admission.
enum EgressAdmissionCredential: Sendable, Equatable {
    /// Open mode: every local connector is judged against the shared policy.
    case open(EgressHostPolicy)
    /// Credentialed mode, mapped token: judged against that grant's policy.
    case granted(EgressHostPolicy)
    /// Credentialed mode, missing, malformed, or unknown token.
    case rejected
}

/// Binary-scope gate denial, gathered by the proxy (it may `stat`/hash).
struct EgressBinaryGateDenial: Sendable, Equatable {
    var reason: EgressDenialReason
    /// Observed runtime binary; nil when no peer can be attributed.
    var binaryPath: String?
}

/// What the proxy does with one request. Performs no I/O.
enum EgressAdmissionVerdict: Sendable, Equatable {
    /// Refuse and record. `.deniedCredential` answers 407; every other
    /// reason answers 403.
    case deny(EgressDenialReason, binaryPath: String? = nil)
    /// CONNECT admitted. `requireSNI` binds the tunnel to the CONNECT
    /// authority: the first TLS record must name it before dialing.
    case tunnel(external: Bool, requireSNI: Bool)
    /// Absolute-URI admitted: forward the request upstream.
    case forward(external: Bool)
}

/// Pure admission ladder shared by both request shapes. Order (SEC-001):
/// credential, binary gate, plaintext-to-443 (absolute-URI only), then
/// policy or live supplement, else loopback. Effectful inputs (credential
/// lookup, binary gate, supplement read) arrive as values.
enum EgressAdmission {
    static func decide(
        target: EgressTarget,
        shape: EgressRequestShape,
        credential: EgressAdmissionCredential,
        binaryGateDenial: EgressBinaryGateDenial?,
        supplementAllows: Bool
    ) -> EgressAdmissionVerdict {
        let policy: EgressHostPolicy
        let credentialed: Bool
        switch credential {
        case .rejected:
            return .deny(.deniedCredential)
        case .open(let shared):
            policy = shared
            credentialed = false
        case .granted(let granted):
            policy = granted
            credentialed = true
        }
        if let gate = binaryGateDenial {
            return .deny(gate.reason, binaryPath: gate.binaryPath)
        }
        let policyAllows = policy.allows(host: target.host, port: target.port)
        let tlsPort = target.port == EgressHostPolicy.httpsPort
        // A credentialed proxy never speaks plaintext absolute-URI to the
        // TLS port of an allowed host: that shape could only smuggle
        // cleartext where the grant meant TLS. Port-80 is unaffected.
        if shape == .absoluteHTTP, credentialed, tlsPort, policyAllows {
            return .deny(.deniedPolicy)
        }
        // Supplement rules are instance-wide, so credentialed requests are
        // judged against their grant alone.
        let external = policyAllows || (!credentialed && supplementAllows)
        let loopback = policy.allowsLoopbackTarget(host: target.host, port: target.port)
        guard external || loopback else {
            return .deny(.deniedPolicy)
        }
        switch shape {
        case .connect:
            // Credentialed allowlist grants (the per-server MCP sandbox
            // shape) bind external TLS tunnels to their origin. Generic
            // public-HTTPS grants and port-80 tunnels stay dial-first.
            let requireSNI = credentialed && external && tlsPort && policy.mode == .allowlist
            return .tunnel(external: external, requireSNI: requireSNI)
        case .absoluteHTTP:
            return .forward(external: external)
        }
    }

    /// SNI binding for a `requireSNI` tunnel: the ClientHello's server name
    /// must match the CONNECT host. A missing name (no ClientHello, not TLS,
    /// or no SNI extension) fails closed.
    static func checkSNI(expectedHost: String, serverName: String?) -> EgressDenialReason? {
        guard let serverName, EgressWire.dnsNamesMatch(serverName, expectedHost) else {
            return .sniMismatch
        }
        return nil
    }
}
