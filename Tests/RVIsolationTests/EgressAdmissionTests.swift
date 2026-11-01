import RVDomain
import Testing
@testable import RVIsolation

/// Table tests for the pure egress admission ladder. Every reason
/// `EgressAdmission` can return, both request shapes, and the ordering
/// edges of SEC-001 (credential, binary gate, plaintext-443, policy or
/// supplement, else loopback, SNI). No sockets.
struct EgressAdmissionTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var target: EgressTarget
        var shape: EgressRequestShape
        var credential: EgressAdmissionCredential
        var gate: EgressBinaryGateDenial? = nil
        var supplement: Bool = false
        var expected: EgressAdmissionVerdict

        var testDescription: String { name }
    }

    static let allowlist = EgressHostPolicy(allowedHosts: ["api.example.com"])
    static let allowlistNoLoopback = EgressHostPolicy(allowedHosts: ["api.example.com"], relaysLoopback: false)
    static let unattributed = EgressBinaryGateDenial(reason: .unattributedPeer, binaryPath: nil)
    static let mismatch = EgressBinaryGateDenial(reason: .binaryMismatch, binaryPath: "/opt/rv/bin/other")

    static func target(_ host: String, _ port: Int) -> EgressTarget {
        EgressTarget(host: host, port: port)
    }

    static let cases: [Case] = [
        // Credential: rejected wins over everything, both shapes.
        Case(
            name: "rejected credential, CONNECT", target: target("api.example.com", 443), shape: .connect,
            credential: .rejected, expected: .deny(.deniedCredential)),
        Case(
            name: "rejected credential, absolute", target: target("127.0.0.1", 8080), shape: .absoluteHTTP,
            credential: .rejected, expected: .deny(.deniedCredential)),
        Case(
            name: "rejected credential beats binary gate", target: target("api.example.com", 443),
            shape: .connect, credential: .rejected, gate: unattributed, expected: .deny(.deniedCredential)),
        Case(
            name: "rejected credential beats supplement", target: target("live.example.com", 443),
            shape: .absoluteHTTP, credential: .rejected, supplement: true, expected: .deny(.deniedCredential)),

        // Binary gate: runs after auth, before policy; carries the path.
        Case(
            name: "unattributed peer, open CONNECT", target: target("127.0.0.1", 9), shape: .connect,
            credential: .open(.publicHTTPS), gate: unattributed, expected: .deny(.unattributedPeer)),
        Case(
            name: "binary mismatch, granted CONNECT", target: target("api.example.com", 443), shape: .connect,
            credential: .granted(allowlist), gate: mismatch,
            expected: .deny(.binaryMismatch, binaryPath: "/opt/rv/bin/other")),
        Case(
            name: "binary gate beats policy allow, absolute", target: target("127.0.0.1", 9),
            shape: .absoluteHTTP, credential: .open(.publicHTTPS), gate: unattributed,
            expected: .deny(.unattributedPeer)),
        Case(
            name: "binary gate beats plaintext-443", target: target("api.example.com", 443),
            shape: .absoluteHTTP, credential: .granted(allowlist), gate: mismatch,
            expected: .deny(.binaryMismatch, binaryPath: "/opt/rv/bin/other")),

        // Policy: neither external nor loopback denies, both shapes.
        Case(
            name: "unknown host, open allowlist CONNECT", target: target("evil.example.com", 443),
            shape: .connect, credential: .open(allowlist), expected: .deny(.deniedPolicy)),
        Case(
            name: "wrong port, open allowlist CONNECT", target: target("api.example.com", 8443),
            shape: .connect, credential: .open(allowlist), expected: .deny(.deniedPolicy)),
        Case(
            name: "external absolute under allowlist port 443-only", target: target("api.example.com", 80),
            shape: .absoluteHTTP, credential: .open(allowlist), expected: .deny(.deniedPolicy)),
        Case(
            name: "loopback refused when cage cannot relay it", target: target("127.0.0.1", 9),
            shape: .connect, credential: .open(allowlistNoLoopback), expected: .deny(.deniedPolicy)),
        Case(
            name: "loopback refused, absolute, granted", target: target("localhost", 9),
            shape: .absoluteHTTP, credential: .granted(allowlistNoLoopback), expected: .deny(.deniedPolicy)),
        Case(
            name: "publicHTTPS refuses non-web ports", target: target("api.example.com", 22),
            shape: .connect, credential: .open(.publicHTTPS), expected: .deny(.deniedPolicy)),

        // Supplement: open mode only.
        Case(
            name: "supplement admits in open mode, CONNECT", target: target("live.example.com", 443),
            shape: .connect, credential: .open(allowlist), supplement: true,
            expected: .tunnel(external: true, requireSNI: false)),
        Case(
            name: "supplement admits in open mode, absolute", target: target("live.example.com", 80),
            shape: .absoluteHTTP, credential: .open(allowlist), supplement: true,
            expected: .forward(external: true)),
        Case(
            name: "supplement ignored when credentialed", target: target("live.example.com", 443),
            shape: .connect, credential: .granted(allowlist), supplement: true, expected: .deny(.deniedPolicy)),

        // Plaintext absolute-URI to the TLS port: credentialed + allowed only.
        Case(
            name: "plaintext-443 denied, granted allowlist", target: target("api.example.com", 443),
            shape: .absoluteHTTP, credential: .granted(allowlist), expected: .deny(.deniedPolicy)),
        Case(
            name: "plaintext-443 denied, granted publicHTTPS", target: target("api.example.com", 443),
            shape: .absoluteHTTP, credential: .granted(.publicHTTPS), expected: .deny(.deniedPolicy)),
        Case(
            name: "plaintext-80 forwarded, granted publicHTTPS", target: target("api.example.com", 80),
            shape: .absoluteHTTP, credential: .granted(.publicHTTPS), expected: .forward(external: true)),
        Case(
            name: "plaintext-443 forwarded in open mode", target: target("api.example.com", 443),
            shape: .absoluteHTTP, credential: .open(.publicHTTPS), expected: .forward(external: true)),
        Case(
            name: "absolute loopback :443 forwarded when credentialed", target: target("127.0.0.1", 443),
            shape: .absoluteHTTP, credential: .granted(allowlist), expected: .forward(external: false)),

        // Admitted CONNECT: SNI required only for credentialed allowlist :443 external.
        Case(
            name: "spec example: open publicHTTPS CONNECT", target: target("api.github.com", 443),
            shape: .connect, credential: .open(.publicHTTPS), expected: .tunnel(external: true, requireSNI: false)),
        Case(
            name: "granted allowlist :443 requires SNI", target: target("api.example.com", 443),
            shape: .connect, credential: .granted(allowlist), expected: .tunnel(external: true, requireSNI: true)),
        Case(
            name: "granted publicHTTPS :443 stays dial-first", target: target("api.example.com", 443),
            shape: .connect, credential: .granted(.publicHTTPS), expected: .tunnel(external: true, requireSNI: false)),
        Case(
            name: "granted publicHTTPS :80 tunnel, no SNI", target: target("api.example.com", 80),
            shape: .connect, credential: .granted(.publicHTTPS), expected: .tunnel(external: true, requireSNI: false)),
        Case(
            name: "open allowlist :443 never requires SNI", target: target("api.example.com", 443),
            shape: .connect, credential: .open(allowlist), expected: .tunnel(external: true, requireSNI: false)),
        Case(
            name: "granted loopback :443 tunnel, no SNI", target: target("127.0.0.1", 443),
            shape: .connect, credential: .granted(allowlist), expected: .tunnel(external: false, requireSNI: false)),
        Case(
            name: "open loopback any port", target: target("localhost", 10100),
            shape: .connect, credential: .open(.publicHTTPS), expected: .tunnel(external: false, requireSNI: false)),
        Case(
            name: "open loopback absolute", target: target("127.0.0.1", 10100),
            shape: .absoluteHTTP, credential: .open(.publicHTTPS), expected: .forward(external: false)),
    ]

    @Test(arguments: cases)
    func decide(_ row: Case) {
        let verdict = EgressAdmission.decide(
            target: row.target,
            shape: row.shape,
            credential: row.credential,
            binaryGateDenial: row.gate,
            supplementAllows: row.supplement
        )
        #expect(verdict == row.expected)
    }

    /// Every reason `decide` itself can return is exercised above.
    @Test func decideCoversEveryAdmissionReason() {
        let reasons = Set(
            Self.cases.compactMap { row -> EgressDenialReason? in
                guard case .deny(let reason, _) = row.expected else { return nil }
                return reason
            }
        )
        #expect(reasons == [.deniedCredential, .unattributedPeer, .binaryMismatch, .deniedPolicy])
    }

    @Test(
        arguments: [
            ("api.example.com", "api.example.com", nil),
            ("API.Example.com.", "api.example.com", nil),
            ("api.example.com", "API.EXAMPLE.COM", nil),
            ("other.example.com", "api.example.com", EgressDenialReason.sniMismatch),
            (nil, "api.example.com", .sniMismatch),
            ("", "api.example.com", .sniMismatch),
            ("api.example.com.evil", "api.example.com", .sniMismatch),
        ] as [(String?, String, EgressDenialReason?)]
    )
    func checkSNI(serverName: String?, expectedHost: String, expected: EgressDenialReason?) {
        #expect(EgressAdmission.checkSNI(expectedHost: expectedHost, serverName: serverName) == expected)
    }
}
