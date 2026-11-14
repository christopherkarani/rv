#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import RVDomain
import RVPolicy
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
        review: denyWireHook(calls),
        proposalWait: 30)
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
        review: denyWireHook(calls),
        resolve: { _, _ in [] })
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let dns = try #require(DenyWireResponse(denyWireExchange(port: port, request: "CONNECT nx.example:443 HTTP/1.1\r\n\r\n")))
    #expect(dns.json?["reason"] as? String == "dial-failed")
    #expect(dns.json?["proposal_id"] == nil)
    _ = denyWireExchange(port: port, request: "BREW pot HTTP/1.1\r\n\r\n")
    // Sentinel: hooks run in order on one serial queue, so once this policy
    // denial reaches the hook any earlier dispatch would already show.
    _ = denyWireExchange(port: port, request: "CONNECT sentinel.example:22 HTTP/1.1\r\n\r\n")
    denyWireAwait(calls, count: 1)
    #expect(calls.all.map(\.host) == ["sentinel.example"])
}

// A stuck review queue must not turn a deny into a hang: the proxy waits a
// bounded moment, then denies without a proposal.
@Test func slowReviewStillDeniesPromptly() throws {
    let records = DenyWireCalls()
    let proxy = EgressProxy(
        policy: denyWirePolicy, grants: nil, record: { records.note($0) },
        review: denyWireHook(DenyWireCalls(), answerAfter: nil))
    let port = try proxy.start().get()
    defer { proxy.stop() }
    // The exchange's own deadline is the hang check: a deny held on the
    // stuck hook would leave it with no bytes.
    let raw = denyWireExchange(port: port, request: "CONNECT other.example:443 HTTP/1.1\r\n\r\n")
    let response = try #require(DenyWireResponse(raw))
    #expect(response.statusLine == "HTTP/1.1 403 Forbidden")
    #expect(response.json?["proposal_id"] == nil)
    #expect(response.json?["next_step"] as? String == "rv egress denials")
    denyWireAwait(records, count: 1)
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
        review: denyWireHook(calls))
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
    // Sentinel on the shared serial hook queue: a policy denial from an
    // unscoped proxy with the same hook. Any hook the mismatch deny queued
    // would run first.
    let sentinel = EgressProxy(
        policy: denyWirePolicy, grants: nil, record: { _ in }, review: denyWireHook(calls))
    let sentinelPort = try sentinel.start().get()
    defer { sentinel.stop() }
    _ = denyWireExchange(port: sentinelPort, request: "CONNECT sentinel.example:443 HTTP/1.1\r\n\r\n")
    denyWireAwait(calls, count: 1)
    #expect(calls.all.map(\.host) == ["sentinel.example"])
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
    denyWireAwait(records, count: 1)
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


/// Test review hook: records each call on the hook's own dispatch thread and
/// answers `denyWireProposal` at once (`0`), after `answerAfter` seconds, or
/// never (`nil`). No Swift concurrency, so a starved cooperative pool on a CI
/// host cannot delay it.
private func denyWireHook(_ calls: DenyWireCalls, answerAfter delay: TimeInterval? = 0) -> EgressReviewHook {
    { denial, answer in
        calls.note(denial)
        guard let delay else { return }
        if delay == 0 {
            answer(denyWireProposal)
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { answer(denyWireProposal) }
        }
    }
}

/// Waits for the condition, not a fixed budget: intake runs off the serve
/// thread and a loaded host may take seconds to schedule it.
private func denyWireAwait(_ calls: DenyWireCalls, count: Int, seconds: TimeInterval = 30) {
    let deadline = Date().addingTimeInterval(seconds)
    while calls.all.count < count, Date() < deadline {
        usleep(20_000)
    }
}

// Oracle: on a binary-scoped instance a binary-gate denial never mints a
// proposal, so a passing binary's policy denials must not carry one either,
// nor wait for one (the wait itself would be the tell). Intake still runs.
@Test func binaryScopedInstanceWithholdsProposalIDsWithoutWaiting() throws {
    let request = "CONNECT other.example:443 HTTP/1.1\r\n\r\n"
    let plain = EgressProxy(policy: denyWirePolicy, grants: nil, record: { _ in })
    let plainPort = try plain.start().get()
    defer { plain.stop() }
    let baseline = denyWireExchange(port: plainPort, request: request)

    let fingerprint = EgressBinaryFingerprint(
        size: 128, mtimeSeconds: 1_700_000_000, mtimeNanoseconds: 0,
        ctimeSeconds: 1_700_000_000, ctimeNanoseconds: 0, device: 1, inode: 7)
    let calls = DenyWireCalls()
    // A hook that never answers plus a wait longer than the exchange
    // deadline: any wait would leave the exchange with no bytes.
    let scoped = EgressProxy(
        policy: denyWirePolicy, grants: nil,
        binaryPolicy: EgressBinaryPolicy(canonicalPaths: ["/opt/rv/bin/agent"]),
        attribution: EgressRuntimeAttribution(binaryPath: "/opt/rv/bin/agent"),
        pins: EgressBinaryPinCache(fingerprint: { _ in fingerprint }, hashFile: { _ in "golden" }),
        record: { _ in },
        review: denyWireHook(calls, answerAfter: nil),
        proposalWait: 60)
    #expect(scoped.advertisesProposals == false)
    let scopedPort = try scoped.start().get()
    defer { scoped.stop() }
    let bytes = denyWireExchange(port: scopedPort, request: request)
    #expect(baseline.isEmpty == false)
    #expect(bytes == baseline)
    denyWireAwait(calls, count: 1)
    #expect(calls.all.map(\.reason) == [.deniedPolicy])
}

/// Answer closures a test hook holds until the test releases them.
private final class DenyWireHeld: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [@Sendable (String?) -> Void] = []

    func hold(_ answer: @escaping @Sendable (String?) -> Void) {
        lock.lock()
        answers.append(answer)
        lock.unlock()
    }

    func releaseAll(_ id: String) {
        lock.lock()
        let taken = answers
        answers = []
        lock.unlock()
        for answer in taken { answer(id) }
    }
}

private final class DenyWireReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [[UInt8]] = []

    func add(_ reply: [UInt8]) {
        lock.lock()
        replies.append(reply)
        lock.unlock()
    }

    var all: [[UInt8]] {
        lock.lock()
        defer { lock.unlock() }
        return replies
    }
}

// The waiter cap: with `maximumProposalWaiters` denials parked on held
// answers (and a wait longer than the exchange deadline), further policy
// denials still go out at once without an id, and their intake still runs.
// Without the cap the extras would park too and come back empty.
@Test func reviewWaitersAreCappedAndIntakeStillRuns() throws {
    let calls = DenyWireCalls()
    let held = DenyWireHeld()
    let hook: EgressReviewHook = { denial, answer in
        calls.note(denial)
        held.hold(answer)
    }
    let proxy = EgressProxy(
        policy: denyWirePolicy, grants: nil, record: { _ in }, review: hook, proposalWait: 120)
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let cap = EgressProxy.maximumProposalWaiters
    let parked = DenyWireReplies()
    let parkedDone = DispatchGroup()
    // Plain threads, not a width-limited pool: every parked client must be
    // connected at once on a small CI host.
    for index in 0..<cap {
        parkedDone.enter()
        Thread {
            parked.add(denyWireExchange(
                port: port, request: "CONNECT held\(index).example:443 HTTP/1.1\r\n\r\n", deadlineSeconds: 180))
            parkedDone.leave()
        }.start()
    }
    denyWireAwait(calls, count: cap)
    #expect(calls.all.count == cap)

    let extras = 2
    for index in 0..<extras {
        let reply = DenyWireResponse(
            denyWireExchange(port: port, request: "CONNECT extra\(index).example:443 HTTP/1.1\r\n\r\n"))
        #expect(reply?.statusLine == "HTTP/1.1 403 Forbidden")
        #expect(reply?.json?["reason"] as? String == "denied-policy")
        #expect(reply?.json?["proposal_id"] == nil)
    }
    #expect(parked.all.isEmpty, "a parked deny returned before its answer was released")
    denyWireAwait(calls, count: cap + extras)
    #expect(calls.all.count == cap + extras)

    held.releaseAll(denyWireProposal)
    #expect(parkedDone.wait(timeout: .now() + 60) == .success)
    let replies = parked.all
    #expect(replies.count == cap)
    #expect(replies.allSatisfy { DenyWireResponse($0)?.json?["proposal_id"] as? String == denyWireProposal })
}

// MARK: - Approve, then retry: the body promises only what approval does.

private func denyWireExchangeOffPool(port: Int, request: String) async -> [UInt8] {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: denyWireExchange(port: port, request: request))
        }
    }
}

private struct DenyWireReview {
    let store: PendingApprovalStore
    let queue: NetworkReviewQueue
    let hook: EgressReviewHook

    init(named name: String) throws {
        let config = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-deny-wire-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let directory = try #require(WorkingDirectory(validating: "/tmp/rv-review-ws"))
        let workspace = WorkspaceSessionID()
        let queue = NetworkReviewQueue(configDirectory: config)
        self.store = PendingApprovalStore(baseDirectory: config)
        self.queue = queue
        self.hook = { denial, answer in
            Task {
                let id = await queue.noteDenial(
                    denial, workspace: workspace, workspaceDirectory: directory, now: Date())
                answer(id?.rawValue)
            }
        }
    }

    /// Owner-side approval of one row, then the supervisor's sweep step.
    func approve(_ id: String, into proxy: EgressProxy) async throws {
        let now = Date()
        let row = try #require(try await store.load(id: ApprovalID(rawValue: id), now: now))
        _ = try await store.resolve(
            id: row.id, decision: .allowOnce, fingerprint: row.fingerprint, identity: row.identity, now: now)
        let update = try #require(await queue.applyResolved(now: now))
        _ = proxy.updateSupplement(update.rules, generation: update.generation)
    }

    func awaitingIDs() async throws -> [String] {
        let deadline = Date().addingTimeInterval(30)
        while true {
            let rows = try await store.list(now: Date()).map(\.id.rawValue)
            if rows.isEmpty == false || Date() > deadline { return rows }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

// Open instance (enforces live rules): the body names the proposal, and
// approving exactly that id admits the retry without a restart.
@Test func advertisedApprovalTakesEffectOnRetry() async throws {
    let review = try DenyWireReview(named: "open")
    let proxy = EgressProxy(
        policy: denyWirePolicy, grants: nil, record: { _ in },
        review: review.hook, proposalWait: 30, resolve: { _, _ in [] })
    #expect(proxy.advertisesProposals)
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let request = "CONNECT other.example:443 HTTP/1.1\r\n\r\n"
    let first = try #require(DenyWireResponse(await denyWireExchangeOffPool(port: port, request: request)))
    let body = try #require(first.json)
    let id = try #require(body["proposal_id"] as? String)
    #expect(body["next_step"] as? String == "rv egress approve \(id)")
    try await review.approve(id, into: proxy)
    // Policy now admits; the injected resolver answers nothing, so the
    // retry fails at dial, not at policy.
    let retry = try #require(DenyWireResponse(await denyWireExchangeOffPool(port: port, request: request)))
    #expect(retry.json?["reason"] as? String == "dial-failed")
}

// Credentialed instance (production per-runtime proxies ignore live rules):
// the proposal is still filed, but the body never names it, because
// approving it does not change this instance's verdict.
@Test func credentialedInstanceNeverAdvertisesAnApprovalThatCannotApply() async throws {
    let review = try DenyWireReview(named: "credentialed")
    let credential = EgressProxyCredential()
    let proxy = EgressProxy(
        policy: .publicHTTPS,
        grants: [credential: EgressGrant(principal: EgressPrincipal(rawValue: "runtime-a"), policy: denyWirePolicy)],
        record: { _ in },
        review: review.hook, proposalWait: 30, resolve: { _, _ in [] })
    #expect(proxy.advertisesProposals == false)
    let port = try proxy.start().get()
    defer { proxy.stop() }
    let request = "CONNECT other.example:443 HTTP/1.1\r\nProxy-Authorization: Bearer \(credential.rawValue)\r\n\r\n"
    let first = try #require(DenyWireResponse(await denyWireExchangeOffPool(port: port, request: request)))
    #expect(first.json?["reason"] as? String == "denied-policy")
    #expect(first.json?["proposal_id"] == nil)
    #expect(first.json?["next_step"] as? String == "rv egress denials")
    let filed = try await review.awaitingIDs()
    let id = try #require(filed.first)
    try await review.approve(id, into: proxy)
    let retry = try #require(DenyWireResponse(await denyWireExchangeOffPool(port: port, request: request)))
    #expect(retry.json?["reason"] as? String == "denied-policy")
    #expect(retry.json?["proposal_id"] == nil)
}
