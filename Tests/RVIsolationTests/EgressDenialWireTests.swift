#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import RVDomain
import Synchronization
import Testing
@testable import RVIsolation

/// Socket-level proof that refusals reach the client as status + headers +
/// `rv.egress.denied.v1` body, and that the wire stays oracle-free.

private final class DenyWireCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [EgressProxyDenial] = []

    func note(_ denial: EgressProxyDenial) {
        lock.lock()
        seen.append(denial)
        lock.unlock()
    }

    var all: [EgressProxyDenial] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }
}

private func denyWireConnect(port: Int) -> Int32? {
    #if canImport(Darwin)
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #else
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard fd >= 0 else { return nil }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port)).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result: Int32 = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
            connect(fd, address, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else {
        close(fd)
        return nil
    }
    return fd
}

/// Sends `request` and reads until the proxy closes (every refusal closes)
/// or the deadline passes. Returns the raw bytes.
private func denyWireExchange(port: Int, request: String, deadlineSeconds: TimeInterval = 20) -> [UInt8] {
    guard let fd = denyWireConnect(port: port) else { return [] }
    defer { close(fd) }
    let bytes = Array(request.utf8)
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeBytes { pointer -> Int in
            guard let base = pointer.baseAddress else { return -1 }
            return send(fd, base.advanced(by: offset), bytes.count - offset, 0)
        }
        if written <= 0 { return [] }
        offset += written
    }
    var collected = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let deadline = Date().addingTimeInterval(deadlineSeconds)
    while Date() < deadline {
        var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&item, 1, 200) > 0 else { continue }
        let count = buffer.withUnsafeMutableBytes { pointer -> Int in
            guard let base = pointer.baseAddress else { return -1 }
            return recv(fd, base, pointer.count, 0)
        }
        if count <= 0 { break }
        collected.append(contentsOf: buffer[..<count])
    }
    return collected
}

private struct DenyWireResponse {
    var statusLine: String
    var headers: [String: String]
    var body: [UInt8]

    init?(_ raw: [UInt8]) {
        let marker: [UInt8] = [13, 10, 13, 10]
        guard raw.count >= 4,
            let split = (0...(raw.count - 4)).first(where: { Array(raw[$0..<($0 + 4)]) == marker })
        else { return nil }
        let head = String(decoding: raw[..<split], as: UTF8.self).components(separatedBy: "\r\n")
        statusLine = head.first ?? ""
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        self.headers = headers
        body = Array(raw[(split + 4)...])
    }

    var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any]
    }
}

private let denyWirePolicy = EgressHostPolicy(allowedHosts: ["api.example.com"], relaysLoopback: false)
private let denyWireProposal = "0B5E1A2C-3D4E-4F60-8A9B-0C1D2E3F4A5B"

private func denyWireCandidate(_ text: String, port: Int) -> EgressDialCandidate? {
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

@Test func connectRefusalCarriesTheJSONBody() throws {
    let proxy = EgressProxy(policy: denyWirePolicy, grants: nil, record: { _ in })
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let raw = denyWireExchange(port: port, request: "CONNECT other.example:443 HTTP/1.1\r\nHost: other.example:443\r\n\r\n")
    let response = try #require(DenyWireResponse(raw))
    #expect(response.statusLine == "HTTP/1.1 403 Forbidden")
    #expect(response.headers["content-type"] == "application/json")
    #expect(response.headers["connection"] == "close")
    #expect(response.headers["content-length"] == String(response.body.count))
    #expect(response.headers["proxy-status"]?.hasPrefix("rv-egress; error=http_request_denied") == true)
    let body = try #require(response.json)
    #expect(body["schema"] as? String == "rv.egress.denied.v1")
    #expect(body["reason"] as? String == "denied-policy")
    #expect(body["host"] as? String == "other.example")
    #expect(body["port"] as? Int == 443)
    #expect(body["next_step"] as? String == "rv egress denials")
}

@Test func absoluteURIRefusalCarriesTheJSONBody() throws {
    let proxy = EgressProxy(policy: denyWirePolicy, grants: nil, record: { _ in })
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let raw = denyWireExchange(port: port, request: "GET http://other.example/x HTTP/1.1\r\nHost: other.example\r\n\r\n")
    let response = try #require(DenyWireResponse(raw))
    #expect(response.statusLine == "HTTP/1.1 403 Forbidden")
    let body = try #require(response.json)
    #expect(body["reason"] as? String == "denied-policy")
    #expect(body["port"] as? Int == 80)
}

@Test func malformedAndOversizeRefusalsCarryBodies() throws {
    let proxy = EgressProxy(policy: denyWirePolicy, grants: nil, record: { _ in })
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let malformed = try #require(DenyWireResponse(denyWireExchange(port: port, request: "BREW pot HTTP/1.1\r\n\r\n")))
    #expect(malformed.json?["reason"] as? String == "malformed")
    #expect(malformed.json?["host"] == nil)
    let oversize = try #require(
        DenyWireResponse(denyWireExchange(port: port, request: String(repeating: "A", count: 70_000))))
    #expect(oversize.statusLine == "HTTP/1.1 403 Forbidden")
    #expect(oversize.json?["reason"] as? String == "header-too-large")
}

@Test func mintedProposalRidesThePolicyDenial() throws {
    let calls = DenyWireCalls()
    let proxy = EgressProxy(
        policy: denyWirePolicy, grants: nil, record: { _ in },
        review: { denial in
            calls.note(denial)
            return denyWireProposal
        })
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let raw = denyWireExchange(port: port, request: "CONNECT other.example:443 HTTP/1.1\r\n\r\n")
    let response = try #require(DenyWireResponse(raw))
    let body = try #require(response.json)
    #expect(body["proposal_id"] as? String == denyWireProposal)
    #expect(body["next_step"] as? String == "rv egress approve \(denyWireProposal)")
    #expect(response.headers["proxy-status"]?.contains("rv egress approve \(denyWireProposal)") == true)
    #expect(calls.all.map(\.reason) == [.deniedPolicy])
    #expect(calls.all.first?.host == "other.example")
}

@Test func reviewIsNotConsultedForNonPolicyDenials() throws {
    let calls = DenyWireCalls()
    let proxy = EgressProxy(
        policy: .publicHTTPS, grants: nil, record: { _ in },
        review: { denial in
            calls.note(denial)
            return denyWireProposal
        },
        resolve: { _, _ in [] })
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let dns = try #require(DenyWireResponse(denyWireExchange(port: port, request: "CONNECT nx.example:443 HTTP/1.1\r\n\r\n")))
    #expect(dns.json?["reason"] as? String == "dial-failed")
    #expect(dns.json?["proposal_id"] == nil)
    _ = denyWireExchange(port: port, request: "BREW pot HTTP/1.1\r\n\r\n")
    #expect(calls.all.isEmpty)
}

// A stuck review queue must not turn a deny into a hang: the proxy waits a
// bounded moment, then denies without a proposal.
@Test func slowReviewStillDeniesPromptly() throws {
    let records = DenyWireCalls()
    let proxy = EgressProxy(
        policy: denyWirePolicy, grants: nil, record: { records.note($0) },
        review: { _ in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return denyWireProposal
        })
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let started = Date()
    let raw = denyWireExchange(port: port, request: "CONNECT other.example:443 HTTP/1.1\r\n\r\n")
    let elapsed = Date().timeIntervalSince(started)
    let response = try #require(DenyWireResponse(raw))
    #expect(response.statusLine == "HTTP/1.1 403 Forbidden")
    #expect(response.json?["proposal_id"] == nil)
    #expect(response.json?["next_step"] as? String == "rv egress denials")
    #expect(elapsed < 5, "deny waited \(elapsed)s on a stuck review")
    #expect(records.all.map(\.reason) == [.deniedPolicy])
}

// Oracle: a binary-mismatch or unattributed denial is byte-identical on the
// wire to a proposal-less policy denial of the same target, even when the
// binary-scoped proxy has a review hook (which must stay unconsulted).
@Test func binaryScopeDenialsAreWireIdenticalToPolicyDenials() throws {
    let request = "CONNECT other.example:443 HTTP/1.1\r\n\r\n"
    let plain = EgressProxy(policy: denyWirePolicy, grants: nil, record: { _ in })
    let plainPort = try plain.start().get()
    defer { plain.stop() }
    let baseline = denyWireExchange(port: plainPort, request: request)
    #expect(DenyWireResponse(baseline)?.json?["reason"] as? String == "denied-policy")

    let calls = DenyWireCalls()
    let mismatch = EgressProxy(
        policy: denyWirePolicy, grants: nil,
        binaryPolicy: EgressBinaryPolicy(canonicalPaths: ["/opt/rv/bin/agent"]),
        attribution: EgressRuntimeAttribution(binaryPath: "/opt/rv/bin/other"),
        record: { _ in },
        review: { denial in
            calls.note(denial)
            return denyWireProposal
        })
    let mismatchPort = try mismatch.start().get()
    defer { mismatch.stop() }
    let unattributed = EgressProxy(
        policy: denyWirePolicy, grants: nil,
        binaryPolicy: EgressBinaryPolicy(canonicalPaths: ["/opt/rv/bin/agent"]),
        record: { _ in })
    let unattributedPort = try unattributed.start().get()
    defer { unattributed.stop() }

    let mismatchBytes = denyWireExchange(port: mismatchPort, request: request)
    let unattributedBytes = denyWireExchange(port: unattributedPort, request: request)
    #expect(baseline.isEmpty == false)
    #expect(mismatchBytes == baseline)
    #expect(unattributedBytes == baseline)
    #expect(String(decoding: mismatchBytes, as: UTF8.self).contains("/opt") == false)
    #expect(calls.all.isEmpty)
}

// Oracle: the resolver's answer (NXDOMAIN vs a private address) is not
// distinguishable on the wire.
@Test func resolverOutcomesAreWireIdentical() throws {
    let request = "CONNECT intranet.example:443 HTTP/1.1\r\n\r\n"
    let nx = EgressProxy(policy: .publicHTTPS, grants: nil, record: { _ in }, resolve: { _, _ in [] })
    let nxPort = try nx.start().get()
    defer { nx.stop() }
    let candidate = try #require(denyWireCandidate("10.1.2.3", port: 443))
    let records = DenyWireCalls()
    let filtered = EgressProxy(
        policy: .publicHTTPS, grants: nil, record: { records.note($0) }, resolve: { _, _ in [candidate] })
    let filteredPort = try filtered.start().get()
    defer { filtered.stop() }
    let nxBytes = denyWireExchange(port: nxPort, request: request)
    let filteredBytes = denyWireExchange(port: filteredPort, request: request)
    #expect(nxBytes.isEmpty == false)
    #expect(nxBytes == filteredBytes)
    #expect(records.all.map(\.reason) == [.addressFiltered])
}

// Oracle: missing, malformed, and unknown credentials get one 407, and the
// binary gate (never evaluated for them) cannot change it.
@Test func credentialRefusalsAreWireIdenticalAcrossCausesAndBinaryState() throws {
    let credential = EgressProxyCredential()
    let grants = [credential: EgressGrant(principal: EgressPrincipal(rawValue: "runtime-a"), policy: .publicHTTPS)]
    let matched = EgressProxy(policy: .publicHTTPS, grants: grants, record: { _ in })
    let matchedPort = try matched.start().get()
    defer { matched.stop() }
    let mismatched = EgressProxy(
        policy: .publicHTTPS, grants: grants,
        binaryPolicy: EgressBinaryPolicy(canonicalPaths: ["/opt/rv/bin/agent"]),
        attribution: EgressRuntimeAttribution(binaryPath: "/opt/rv/bin/other"),
        record: { _ in })
    let mismatchedPort = try mismatched.start().get()
    defer { mismatched.stop() }
    let requests = [
        "CONNECT denied.example:443 HTTP/1.1\r\n\r\n",
        "CONNECT denied.example:443 HTTP/1.1\r\nProxy-Authorization: Bearer wrong-token\r\n\r\n",
        "CONNECT denied.example:443 HTTP/1.1\r\nProxy-Authorization: Bearer\r\n\r\n",
        "CONNECT denied.example:443 HTTP/1.1\r\nProxy-Authorization: Basic !!!\r\n\r\n",
    ]
    let baseline = denyWireExchange(port: matchedPort, request: requests[0])
    let parsed = try #require(DenyWireResponse(baseline))
    #expect(parsed.statusLine == "HTTP/1.1 407 Proxy Authentication Required")
    #expect(parsed.headers["proxy-authenticate"] == "Bearer")
    #expect(parsed.json?["reason"] as? String == "denied-credential")
    for request in requests {
        #expect(denyWireExchange(port: matchedPort, request: request) == baseline)
        #expect(denyWireExchange(port: mismatchedPort, request: request) == baseline)
    }
}

private func denyWireAwait(_ calls: DenyWireCalls, count: Int) {
    for _ in 0..<100 where calls.all.count < count {
        usleep(50_000)
    }
}

// Oracle: on a binary-scoped instance a binary-gate denial never mints a
// proposal, so a passing binary's policy denials must not carry one either
// (intake still runs, without the wait).
@Test func binaryScopedInstanceWithholdsProposalIDs() throws {
    let request = "CONNECT other.example:443 HTTP/1.1\r\n\r\n"
    let plain = EgressProxy(policy: denyWirePolicy, grants: nil, record: { _ in })
    let plainPort = try plain.start().get()
    defer { plain.stop() }
    let baseline = denyWireExchange(port: plainPort, request: request)

    let fingerprint = EgressBinaryFingerprint(
        size: 128, mtimeSeconds: 1_700_000_000, mtimeNanoseconds: 0,
        ctimeSeconds: 1_700_000_000, ctimeNanoseconds: 0, device: 1, inode: 7)
    let calls = DenyWireCalls()
    let scoped = EgressProxy(
        policy: denyWirePolicy, grants: nil,
        binaryPolicy: EgressBinaryPolicy(canonicalPaths: ["/opt/rv/bin/agent"]),
        attribution: EgressRuntimeAttribution(binaryPath: "/opt/rv/bin/agent"),
        pins: EgressBinaryPinCache(fingerprint: { _ in fingerprint }, hashFile: { _ in "golden" }),
        record: { _ in },
        review: { denial in
            calls.note(denial)
            return denyWireProposal
        })
    let scopedPort = try scoped.start().get()
    defer { scoped.stop() }
    let bytes = denyWireExchange(port: scopedPort, request: request)
    #expect(baseline.isEmpty == false)
    #expect(bytes == baseline)
    denyWireAwait(calls, count: 1)
    #expect(calls.all.map(\.reason) == [.deniedPolicy])
}

// A flood of denials against a stuck queue: past the waiter cap the deny
// goes out at once, and every denial still reaches intake.
@Test func reviewWaitersAreCappedAndIntakeStillRuns() throws {
    let calls = DenyWireCalls()
    let proxy = EgressProxy(
        policy: denyWirePolicy, grants: nil, record: { _ in },
        review: { denial in
            calls.note(denial)
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return denyWireProposal
        })
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let flood = 3 * EgressProxy.maximumProposalWaiters
    let replies = Mutex<[[UInt8]]>([])
    let started = Date()
    DispatchQueue.concurrentPerform(iterations: flood) { index in
        let reply = denyWireExchange(port: port, request: "CONNECT host\(index).example:443 HTTP/1.1\r\n\r\n")
        replies.withLock { $0.append(reply) }
    }
    let elapsed = Date().timeIntervalSince(started)
    let all = replies.withLock { $0 }
    #expect(all.count == flood)
    #expect(all.allSatisfy { DenyWireResponse($0)?.statusLine == "HTTP/1.1 403 Forbidden" })
    #expect(all.allSatisfy { DenyWireResponse($0)?.json?["proposal_id"] == nil })
    #expect(elapsed < 10, "flood took \(elapsed)s")
    denyWireAwait(calls, count: flood)
    #expect(calls.all.count == flood)
}
