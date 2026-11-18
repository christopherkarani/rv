#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import Synchronization
import Testing
@testable import RVIsolation

/// Audit mode (`sandbox.enforcement: audit`) and owner-set `allowed_ips`
/// together. Audit lets an unlisted host past admission, but that host dials
/// public unicast only: it never borrows a listed host's private ranges. A
/// listed host's dial-time floors (forbidden ranges, partly covered answers)
/// keep denying under audit. No packet leaves the host: the connect seam
/// records the vetted candidate instead of dialing it.
@Suite struct EgressAuditAllowedIPsTests {
    static let listed = "staging.corp.lan"

    static func ranges() throws -> EgressAllowedIPs {
        try EgressAllowedIPs(parsing: ["10.0.5.0/24"])
    }

    static func policy() throws -> EgressHostPolicy {
        EgressHostPolicy(allowedHosts: [listed], allowedIPs: [listed: try ranges()], relaysLoopback: false)
    }

    static func v4(_ text: String) throws -> EgressDialCandidate {
        try #require(EgressDestinationCheckTests.candidateV4(text, port: 443))
    }

    // MARK: Admission

    @Test func auditPassForAnUnlistedHostCarriesNoRanges() throws {
        let verdict = EgressAdmission.decide(
            target: EgressTarget(host: "other.corp.lan", port: 443), shape: .connect,
            credential: .granted(try Self.policy()), binaryGateDenial: nil, supplementAllows: false,
            auditsAllowlist: true)
        #expect(verdict == .audited(.tunnel(external: true, requireSNI: true, allowedIPs: nil)))
        let listed = EgressAdmission.decide(
            target: EgressTarget(host: Self.listed, port: 443), shape: .connect,
            credential: .granted(try Self.policy()), binaryGateDenial: nil, supplementAllows: false,
            auditsAllowlist: true)
        #expect(listed == .tunnel(external: true, requireSNI: true, allowedIPs: try Self.ranges()))
    }

    // MARK: Proxy (credentialed allowlist proxy in audit mode, the MCP sandbox shape)

    struct Row: Sendable, CustomTestStringConvertible {
        var host: String
        var answer: [String]
        var audited: Bool
        var dialed: [String]
        var denial: EgressDenialReason
        var testDescription: String { "\(host) → \(answer)" }
    }

    static let rows: [Row] = [
        // Unlisted host answering inside the listed host's range: audited
        // past admission, then refused at dial (public unicast only).
        Row(host: "other.corp.lan", answer: ["10.0.5.20"], audited: true, dialed: [], denial: .addressFiltered),
        // Listed host answering metadata: a forbidden range still refuses.
        Row(host: listed, answer: ["169.254.169.254"], audited: false, dialed: [], denial: .addressFiltered),
        // Listed host with a partly covered answer: refused whole.
        Row(host: listed, answer: ["10.0.5.20", "10.0.6.20"], audited: false, dialed: [], denial: .addressFiltered),
        // Listed host with a covered answer: audit mode leaves allowed_ips working.
        Row(host: listed, answer: ["10.0.5.20"], audited: false, dialed: ["10.0.5.20"], denial: .dialFailed),
    ]

    @Test(arguments: rows)
    func dialFloorsHoldUnderAudit(_ row: Row) throws {
        let answer = try row.answer.map(Self.v4)
        let dialed = Mutex<[String]>([])
        let denials = Mutex<[EgressDenialReason]>([])
        let wouldBe = Mutex<[String]>([])
        let credential = EgressProxyCredential()
        let grant = EgressGrant(principal: EgressPrincipal(rawValue: "mcp:staging"), policy: try Self.policy())
        let proxy = EgressProxy(
            policy: .publicHTTPS, grants: [credential: grant],
            record: { denial in denials.withLock { $0.append(denial.reason) } },
            audit: EgressAuditMode(record: { denial in
                wouldBe.withLock { $0.append(denial.host) }
                return true
            }),
            resolve: { _, _ in answer },
            connect: { candidate in
                let shown = EgressProxy.coverageAddress(of: candidate)?.description ?? "?"
                dialed.withLock { $0.append(shown) }
                return nil
            })
        let port = try proxy.start().get()
        defer { proxy.stop() }
        let client = try #require(EgressDestinationCheckTests.dialLoopback(port: port))
        defer { close(client) }
        #expect(EgressDestinationCheckTests.send(client, Array(
            "CONNECT \(row.host):443 HTTP/1.1\r\nProxy-Authorization: Bearer \(credential.rawValue)\r\n\r\n".utf8)))
        #expect(EgressDestinationCheckTests.read(client).contains("HTTP/1.1 200"))
        #expect(EgressDestinationCheckTests.send(client, EgressDestinationCheckTests.clientHello(row.host)))
        for _ in 0..<400 where denials.withLock({ $0.isEmpty }) { usleep(25_000) }
        #expect(wouldBe.withLock { $0 } == (row.audited ? [row.host] : []))
        #expect(dialed.withLock { $0 } == row.dialed)
        #expect(denials.withLock { $0 } == [row.denial])
    }
}
