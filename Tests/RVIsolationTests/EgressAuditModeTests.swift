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

/// Audit mode for an allowlist (OpenShell `enforcement: audit`): a host the
/// allowlist alone would refuse passes once its would-be block is durable.
/// Every other refusal still denies.
@Suite("Egress allowlist audit mode")
struct EgressAuditModeTests {
    static let listed = EgressHostPolicy(allowedHosts: ["api.example.com"], relaysLoopback: false)

    static func decide(
        _ host: String, _ port: Int = 443, shape: EgressRequestShape = .connect,
        credential: EgressAdmissionCredential = .granted(listed), gate: EgressBinaryGateDenial? = nil,
        audits: Bool = true
    ) -> EgressAdmissionVerdict {
        EgressAdmission.decide(
            target: EgressTarget(host: host, port: port), shape: shape, credential: credential,
            binaryGateDenial: gate, supplementAllows: false, auditsAllowlist: audits)
    }

    // MARK: Admission ladder

    @Test func auditPassesAnUnlistedHostAsAnSNIBoundTunnel() {
        #expect(Self.decide("other.example") == .audited(.tunnel(external: true, requireSNI: true)))
        #expect(Self.decide("other.example", credential: .open(Self.listed)) == .audited(.tunnel(external: true, requireSNI: false)))
    }

    @Test func enforceDeniesTheSameHost() {
        #expect(Self.decide("other.example", audits: false) == .deny(.deniedPolicy))
    }

    @Test func listedHostsAreNotAudited() {
        #expect(Self.decide("api.example.com") == .tunnel(external: true, requireSNI: true))
    }

    @Test func auditKeepsEveryOtherRefusal() {
        let mismatch = EgressBinaryGateDenial(reason: .binaryMismatch, binaryPath: "/opt/rv/bin/other")
        #expect(Self.decide("other.example", credential: .rejected) == .deny(.deniedCredential))
        #expect(Self.decide("other.example", gate: mismatch) == .deny(.binaryMismatch, binaryPath: "/opt/rv/bin/other"))
        // Plaintext to the TLS port on a credentialed proxy.
        #expect(Self.decide("other.example", shape: .absoluteHTTP) == .deny(.deniedPolicy))
        // The allowlist's port still holds.
        #expect(Self.decide("other.example", 22) == .deny(.deniedPolicy))
        #expect(Self.decide("other.example", 80, shape: .absoluteHTTP) == .deny(.deniedPolicy))
        // No IP literal, no loopback name, no single label.
        for host in ["127.0.0.1", "169.254.169.254", "10.0.0.1", "localhost", "intranet", "0x7f.0.0.1"] {
            #expect(Self.decide(host) == .deny(.deniedPolicy), "\(host)")
        }
    }

    @Test func auditDoesNotWidenPublicHTTPS() {
        #expect(Self.decide("other.example", 22, credential: .open(.publicHTTPS)) == .deny(.deniedPolicy))
    }

    // MARK: Proxy

    @Test func auditPassWritesItsWouldBeBlockThenDials() throws {
        let harness = Harness(resolveAnswer: [])
        let proxy = harness.proxy(audit: true)
        let port = try proxy.start().get()
        defer { proxy.stop() }
        let raw = exchange(port: port, request: "CONNECT other.example:443 HTTP/1.1\r\n\r\n")
        // Past admission: the dial ran (and found no address).
        #expect(harness.resolveCalls == 1)
        #expect(raw.contains("dial-failed"))
        #expect(harness.wouldBe.map(\.host) == ["other.example"])
        #expect(harness.wouldBe.map(\.port) == [443])
        #expect(harness.wouldBe.map(\.reason) == [.deniedPolicy])
        harness.awaitDenials(1)
        #expect(harness.denials.map(\.reason) == [.dnsFailed])
    }

    @Test func enforceProxyDeniesWithoutAnAuditRecord() throws {
        let harness = Harness(resolveAnswer: [])
        let proxy = harness.proxy(audit: false)
        let port = try proxy.start().get()
        defer { proxy.stop() }
        let raw = exchange(port: port, request: "CONNECT other.example:443 HTTP/1.1\r\n\r\n")
        #expect(raw.hasPrefix("HTTP/1.1 403"))
        #expect(raw.contains("denied-policy"))
        #expect(harness.resolveCalls == 0)
        #expect(harness.wouldBe.isEmpty)
    }

    @Test func dialFilterStillRefusesMetadataUnderAudit() throws {
        let metadata = try #require(candidateV4("169.254.169.254", port: 443))
        let harness = Harness(resolveAnswer: [metadata])
        let proxy = harness.proxy(audit: true)
        let port = try proxy.start().get()
        defer { proxy.stop() }
        let raw = exchange(port: port, request: "CONNECT metadata.example:443 HTTP/1.1\r\n\r\n")
        #expect(raw.hasPrefix("HTTP/1.1 403"))
        harness.awaitDenials(1)
        #expect(harness.denials.map(\.reason) == [.addressFiltered])
    }

    @Test func unwritableAuditRecordDenies() throws {
        let harness = Harness(resolveAnswer: [], recordSucceeds: false)
        let proxy = harness.proxy(audit: true)
        let port = try proxy.start().get()
        defer { proxy.stop() }
        let raw = exchange(port: port, request: "CONNECT other.example:443 HTTP/1.1\r\n\r\n")
        #expect(raw.hasPrefix("HTTP/1.1 403"))
        #expect(raw.contains("denied-policy"))
        #expect(harness.resolveCalls == 0)
        harness.awaitDenials(1)
        #expect(harness.denials.map(\.reason) == [.deniedPolicy])
    }

    @Test func credentialedAuditPassStillBindsSNI() throws {
        let harness = Harness(resolveAnswer: [])
        let credential = EgressProxyCredential()
        let proxy = harness.proxy(audit: true, credential: credential)
        let port = try proxy.start().get()
        defer { proxy.stop() }
        let auth = "Proxy-Authorization: Bearer \(credential.rawValue)\r\n"
        _ = exchange(
            port: port, request: "CONNECT other.example:443 HTTP/1.1\r\n\(auth)\r\n", then: clientHello("elsewhere.example"))
        harness.awaitDenials(1)
        #expect(harness.denials.map(\.reason) == [.sniMismatch])
        #expect(harness.resolveCalls == 0)
        // A bare or mismatched CONNECT never mints an audit record.
        #expect(harness.wouldBe.isEmpty)

        let unauthenticated = exchange(port: port, request: "CONNECT other.example:443 HTTP/1.1\r\n\r\n")
        #expect(unauthenticated.hasPrefix("HTTP/1.1 407"))
        #expect(harness.wouldBe.isEmpty)

        _ = exchange(
            port: port, request: "CONNECT other.example:443 HTTP/1.1\r\n\(auth)\r\n", then: clientHello("other.example"))
        harness.awaitDenials(3)
        #expect(harness.wouldBe.map(\.host) == ["other.example"])
        #expect(harness.resolveCalls == 1)
        #expect(harness.denials.last?.reason == .dnsFailed)
    }

    @Test func credentialedAuditRecordFailureClosesWithoutDialing() throws {
        let harness = Harness(resolveAnswer: [], recordSucceeds: false)
        let credential = EgressProxyCredential()
        let proxy = harness.proxy(audit: true, credential: credential)
        let port = try proxy.start().get()
        defer { proxy.stop() }
        _ = exchange(
            port: port,
            request: "CONNECT other.example:443 HTTP/1.1\r\nProxy-Authorization: Bearer \(credential.rawValue)\r\n\r\n",
            then: clientHello("other.example"))
        harness.awaitDenials(1)
        #expect(harness.denials.map(\.reason) == [.deniedPolicy])
        #expect(harness.resolveCalls == 0)
        #expect(harness.wouldBe.count == 1)
    }
}

private final class Harness: Sendable {
    private let state = Mutex<(wouldBe: [EgressProxyDenial], denials: [EgressProxyDenial], resolves: Int)>(([], [], 0))
    let resolveAnswer: [EgressDialCandidate]
    let recordSucceeds: Bool

    init(resolveAnswer: [EgressDialCandidate], recordSucceeds: Bool = true) {
        self.resolveAnswer = resolveAnswer
        self.recordSucceeds = recordSucceeds
    }

    var wouldBe: [EgressProxyDenial] { state.withLock { $0.wouldBe } }
    var denials: [EgressProxyDenial] { state.withLock { $0.denials } }
    var resolveCalls: Int { state.withLock { $0.resolves } }

    func awaitDenials(_ count: Int) {
        let deadline = Date().addingTimeInterval(10)
        while denials.count < count, Date() < deadline { usleep(10_000) }
    }

    func proxy(audit: Bool, credential: EgressProxyCredential? = nil) -> EgressProxy {
        let policy = EgressAuditModeTests.listed
        let grants = credential.map { [$0: EgressGrant(principal: EgressPrincipal(rawValue: "audit-test"), policy: policy)] }
        let succeeds = recordSucceeds
        let answer = resolveAnswer
        return EgressProxy(
            policy: policy, grants: grants,
            record: { denial in self.state.withLock { $0.denials.append(denial) } },
            audit: audit
                ? EgressAuditMode(record: { denial in
                    self.state.withLock { $0.wouldBe.append(denial) }
                    return succeeds
                }) : nil,
            resolve: { _, _ in
                self.state.withLock { $0.resolves += 1 }
                return answer
            })
    }
}

/// Sends `request` (then `then`, once the proxy answered 200) and reads
/// until the proxy closes or 10 s pass.
private func exchange(port: Int, request: String, then followUp: [UInt8] = []) -> String {
    #if canImport(Darwin)
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #else
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard fd >= 0 else { return "" }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port)).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { return "" }
    func sendAll(_ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0) }
            if written <= 0 { return }
            offset += written
        }
    }
    sendAll(Array(request.utf8))
    var collected = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 4096)
    var sentFollowUp = followUp.isEmpty
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&item, 1, 200) > 0 else { continue }
        let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        if count <= 0 { break }
        collected.append(contentsOf: buffer[..<count])
        if sentFollowUp == false, String(decoding: collected, as: UTF8.self).contains("\r\n\r\n") {
            sendAll(followUp)
            sentFollowUp = true
        }
    }
    return String(decoding: collected, as: UTF8.self)
}

private func candidateV4(_ text: String, port: Int) -> EgressDialCandidate? {
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port)).bigEndian
    guard inet_pton(AF_INET, text, &addr.sin_addr) == 1 else { return nil }
    var storage = sockaddr_storage()
    withUnsafeBytes(of: &addr) { raw in
        withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: raw) }
    }
    #if canImport(Darwin)
    let socktype: Int32 = SOCK_STREAM
    let proto: Int32 = IPPROTO_TCP
    #else
    let socktype = Int32(SOCK_STREAM.rawValue)
    let proto = Int32(IPPROTO_TCP)
    #endif
    return EgressDialCandidate(
        family: AF_INET, socktype: socktype, proto: proto, address: storage,
        length: socklen_t(MemoryLayout<sockaddr_in>.size))
}

/// Minimal TLS 1.3 ClientHello record carrying an SNI host_name.
private func clientHello(_ host: String) -> [UInt8] {
    let name = Array(host.utf8)
    let entry: [UInt8] = [0x00, UInt8(name.count >> 8), UInt8(name.count & 0xFF)] + name
    let list: [UInt8] = [UInt8(entry.count >> 8), UInt8(entry.count & 0xFF)] + entry
    let extensions: [UInt8] = [0x00, 0x00, UInt8(list.count >> 8), UInt8(list.count & 0xFF)] + list
    var body: [UInt8] = [0x03, 0x03] + [UInt8](repeating: 0xAB, count: 32) + [0x00]
    body += [0x00, 0x02, 0x13, 0x01, 0x01, 0x00]
    body += [UInt8(extensions.count >> 8), UInt8(extensions.count & 0xFF)] + extensions
    let handshake: [UInt8] = [0x01, UInt8((body.count >> 16) & 0xFF), UInt8((body.count >> 8) & 0xFF),
                              UInt8(body.count & 0xFF)] + body
    return [0x16, 0x03, 0x01, UInt8(handshake.count >> 8), UInt8(handshake.count & 0xFF)] + handshake
}
