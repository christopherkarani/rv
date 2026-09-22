import Foundation
import Synchronization
import Testing
@testable import RVDomain

@Suite("HTTP egress")
struct HTTPEgressTests {
    @Test func digestMatchesTheEmptyAndABCVectors() {
        #expect(HTTPDigest.sha256Hex([]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(
            HTTPDigest.sha256Hex(Array("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test func canonicalURLKeepsOneMeaning() throws {
        let plain = try canonicalizeHTTP(method: "GET", url: "https://Example.COM./a/../b").get()
        let explicit = try canonicalizeHTTP(method: "GET", url: "https://example.com:443/b").get()
        #expect(plain.host == "example.com")
        #expect(plain.port == 443)
        #expect(plain.path == "/b")
        #expect(plain.query == nil)
        #expect(plain.literalAddress == nil)
        #expect(plain.nameBlocked == false)
        #expect(explicit.host == plain.host)
        #expect(explicit.port == plain.port)
        #expect(explicit.path == plain.path)
    }

    @Test func dotAndPercentSegmentsResolveBeforeAuthorization() throws {
        let encoded = try canonicalizeHTTP(
            method: "GET",
            url: "https://example.com/a/%2e%2e/b/%2e/c"
        ).get()
        #expect(encoded.path == "/b/c")
        let unreserved = try canonicalizeHTTP(
            method: "GET",
            url: "https://example.com/%41"
        ).get()
        #expect(unreserved.path == "/A")
    }

    @Test func queryIsCanonicalAndSeparateFromTheAuditedPath() throws {
        let request = try canonicalizeHTTP(
            method: "GET",
            url: "https://example.com/a?token=%41"
        ).get()
        #expect(request.path == "/a")
        #expect(request.query == "token=A")
        let action = try httpAction(url: "https://example.com/a?token=secret")
        #expect(action.destination.auditedResource == "https://example.com:443/a")
        #expect(action.destination.canonicalURL.contains("secret"))
        #expect(action.fingerprint.rawValue.contains("secret") == false)
        #expect(action.fingerprint.rawValue.contains(":q:none") == false)
    }

    @Test(arguments: [
        "POST", "PUT", "HEAD", "DELETE", "OPTIONS", "PATCH", "TRACE", "CONNECT",
    ])
    func unsupportedMethodsDoNotCanonicalize(_ method: String) {
        #expect(canonicalizeHTTP(method: method, url: "https://example.com/") == .failure(.unsupportedMethod))
    }

    @Test(arguments: [
        "http://example.com/",
        "HTTP://example.com/",
        "file:///etc/passwd",
        "ftp://example.com/",
        "data:text/plain,hi",
        "javascript:alert(1)",
        "unix:///tmp/socket",
        "custom://example.com/",
    ])
    func unsupportedSchemesFailClosed(_ url: String) {
        #expect(canonicalizeHTTP(method: "GET", url: url) == .failure(.unsupportedScheme))
    }

    @Test(arguments: [
        "https://user:secret@example.com/",
        "https://user@example.com/",
        "https://example.com/a%2fb",
        "https://example.com/a%00b",
        "https://0177.0.0.1/",
        "https://0x7f000001/",
        "https://2130706433/",
        "https://127.1/",
        "https://example.com/a b",
        "https://example.com/#frag",
        "https://[::1%en0]/",
        "https://exa mple.com/",
        "http://example.com/\\@example.com/",
    ])
    func ambiguousURLsAreMalformed(_ url: String) {
        let result = canonicalizeHTTP(method: "GET", url: url)
        if case .failure(.malformed) = result {
        } else {
            Issue.record("expected malformed for \(url), got \(result)")
        }
    }

    @Test func addressClassesRejectLocalAndPrivateRanges() {
        #expect(classify("127.0.0.1") == .loopback)
        #expect(classify("0.0.0.0") == .unspecified)
        #expect(classify("10.1.2.3") == .privateUnicast)
        #expect(classify("172.16.0.1") == .privateUnicast)
        #expect(classify("192.168.1.1") == .privateUnicast)
        #expect(classify("100.64.0.1") == .sharedCGNAT)
        #expect(classify("169.254.169.254") == .linkLocal)
        #expect(classify("192.0.2.1") == .documentation)
        #expect(classify("198.51.100.1") == .documentation)
        #expect(classify("203.0.113.1") == .documentation)
        #expect(classify("224.0.0.1") == .multicast)
        #expect(classify("255.255.255.255") == .broadcast)
        #expect(classify("240.0.0.1") == .reserved)
        #expect(classify("1.1.1.1") == .publicGlobal)
        #expect(classify("8.8.8.8") == .publicGlobal)
        #expect(classify6("::1") == .loopback)
        #expect(classify6("::") == .unspecified)
        #expect(classify6("::ffff:127.0.0.1") == .mapped)
        #expect(classify6("::ffff:1.1.1.1") == .mapped)
        #expect(classify6("fe80::1") == .linkLocal)
        #expect(classify6("fc00::1") == .uniqueLocal)
        #expect(classify6("fd12:3456:789a::1") == .uniqueLocal)
        #expect(classify6("ff02::1") == .multicast)
        #expect(classify6("2001:db8::1") == .documentation)
        #expect(classify6("2001:4860:4860::8888") == .publicGlobal)
    }

    @Test func blockedNamesAreNotResolved() throws {
        for url in [
            "https://localhost/",
            "https://LOCALHOST./",
            "https://metadata.google.internal/computeMetadata/v1/",
            "https://example.local/",
            "https://printer/",
            "https://host.docker.internal/",
            "https://app.home.arpa/",
        ] {
            let canonical = try canonicalizeHTTP(method: "GET", url: url).get()
            #expect(canonical.nameBlocked, "\(url) must be blocked before DNS")
            #expect(canonical.literalAddress == nil)
        }
    }

    @Test func mixedDNSAnswersAreForbiddenAndPublicAnswersPinIPv4() throws {
        let loopback = try #require(HTTPIPAddress(ipv4: [127, 0, 0, 1]))
        let public4 = try #require(HTTPIPAddress(ipv4: [1, 1, 1, 1]))
        let public6 = try #require(parseIPv6("2001:4860:4860::8888"))
        #expect(selectHTTPAddresses([public4, loopback]) == .forbidden(loopback))
        #expect(selectHTTPAddresses([public6, public4]) == .pinned(public4))
    }

    @Test func publicGETIsAllowedAndUnsafeTargetsAreDenied() throws {
        let allowed = try httpAction(url: "https://example.com/a")
        guard case .allowed = AgentAuthorization.decide(action: .http(allowed), policy: .empty) else {
            Issue.record("public GET must be allowed")
            return
        }
        let loopback = try httpAction(url: "https://127.0.0.1/")
        guard case .denied(let denied) = AgentAuthorization.decide(action: .http(loopback), policy: .empty) else {
            Issue.record("loopback must be denied")
            return
        }
        #expect(denied.deny.ruleID == ActionPolicyEngine.Builtin.forbiddenHTTPDestination.ruleID)
        let loosened = EffectiveActionPolicy(overlay: .allow)
        guard case .denied = AgentAuthorization.decide(action: .http(loopback), policy: loosened) else {
            Issue.record("overlay allow must not loosen a forbidden destination")
            return
        }
    }

    @Test func overlayCanTightenAPublicGETToAskOrDeny() throws {
        let action = ProposedAction.http(try httpAction(url: "https://example.com/"))
        let ask = EffectiveActionPolicy(
            overlay: .mandatoryHuman(ActionPolicyEngine.Builtin.uncovered)
        )
        guard case .pending = AgentAuthorization.decide(action: action, policy: ask) else {
            Issue.record("overlay ask must stay pending")
            return
        }
        let deny = EffectiveActionPolicy(overlay: .deny(ActionPolicyEngine.Builtin.uncovered))
        guard case .denied = AgentAuthorization.decide(action: action, policy: deny) else {
            Issue.record("overlay deny must deny")
            return
        }
    }

    @Test func literalPrivateAddressDoesNotAskTheResolver() throws {
        var lookedUp = false
        let proposal = normalizeRuntimeHTTP(
            subject: try httpSubject(),
            method: "GET",
            url: "https://10.0.0.8/",
            resolve: { _ in
                lookedUp = true
                return .failure(.failed)
            }
        )
        #expect(lookedUp == false)
        let action = try proposal.get()
        guard case .denied = AgentAuthorization.decide(action: action, policy: .empty) else {
            Issue.record("private literal must be denied")
            return
        }
    }

    @Test func publicNameThatResolvesPrivateIsDenied() throws {
        let loopback = try #require(HTTPIPAddress(ipv4: [127, 0, 0, 1]))
        let action = try normalizeRuntimeHTTP(
            subject: try httpSubject(),
            method: "GET",
            url: "https://allowed.example/secret",
            resolve: { _ in .success([loopback]) }
        ).get()
        guard case .http(let http) = action else {
            Issue.record("expected an HTTP action")
            return
        }
        #expect(http.destination.address == loopback)
        #expect(http.destination.isPublicPinned == false)
        guard case .denied = AgentAuthorization.decide(action: action, policy: .empty) else {
            Issue.record("DNS to loopback must be denied")
            return
        }
    }

    @Test func requestBytesCarryNoCredentialsCookiesOrProxyHeaders() throws {
        let action = try httpAction(url: "https://example.com/a?x=1")
        let bytes = String(decoding: HTTPRequestMessage.bytes(for: action.destination), as: UTF8.self)
        #expect(bytes.hasPrefix("GET /a?x=1 HTTP/1.1\r\n"))
        #expect(bytes.contains("Host: example.com\r\n"))
        #expect(bytes.contains("User-Agent: rv-http/1\r\n"))
        #expect(bytes.contains("Authorization:") == false)
        #expect(bytes.contains("Proxy-Authorization:") == false)
        #expect(bytes.contains("Cookie:") == false)
        #expect(bytes.contains("cookie:") == false)
    }

    @Test func successfulExchangeReturnsABoundedBodyAndSelectedHeaders() throws {
        let script = ScriptedTransfer(chunks: [
            .bytes(Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nSet-Cookie: session=secret\r\nContent-Length: 5\r\n\r\nhi-ok".utf8))
        ])
        let receipt = try HTTPExchange.perform(
            destination: try httpAction(url: "https://example.com/a").destination,
            transfer: script.transfer(),
            deadline: Date().addingTimeInterval(2)
        ).get()
        #expect(receipt.status == 200)
        #expect(receipt.body == Data("hi-ok".utf8))
        #expect(receipt.headers.contains { $0.name == "content-type" && $0.value == "text/plain" })
        #expect(receipt.headers.contains { $0.name == "set-cookie" } == false)
        #expect(receipt.destination == "https://example.com:443/a")
    }

    @Test func cookiesAreNotStoredForALaterRequest() throws {
        let first = ScriptedTransfer(chunks: [
            .bytes(Data("HTTP/1.1 200 OK\r\nSet-Cookie: a=b\r\nContent-Length: 0\r\n\r\n".utf8))
        ])
        _ = try HTTPExchange.perform(
            destination: try httpAction(url: "https://example.com/").destination,
            transfer: first.transfer(),
            deadline: Date().addingTimeInterval(2)
        ).get()
        let second = ScriptedTransfer(chunks: [
            .bytes(Data("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n".utf8))
        ])
        _ = try HTTPExchange.perform(
            destination: try httpAction(url: "https://example.com/next").destination,
            transfer: second.transfer(),
            deadline: Date().addingTimeInterval(2)
        ).get()
        let written = String(decoding: second.written, as: UTF8.self)
        #expect(written.contains("Cookie") == false)
        #expect(written.contains("a=b") == false)
    }

    @Test func redirectIsNotFollowed() throws {
        var opens = 0
        let script = ScriptedTransfer(chunks: [
            .bytes(Data("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1/secret\r\nContent-Length: 0\r\n\r\n".utf8))
        ])
        opens += 1
        let result = HTTPExchange.perform(
            destination: try httpAction(url: "https://example.com/start").destination,
            transfer: script.transfer(),
            deadline: Date().addingTimeInterval(2)
        )
        guard case .failure(.opened(.redirect(let status, let location))) = result else {
            Issue.record("expected a redirect failure, got \(result)")
            return
        }
        #expect(status == 302)
        #expect(location == "http://127.0.0.1/secret")
        #expect(opens == 1)
        #expect(script.reads == 1)
        let written = String(decoding: script.written, as: UTF8.self)
        #expect(written.components(separatedBy: "GET ").count == 2)
    }

    @Test func redirectLocationDropsUserinfo() throws {
        let script = ScriptedTransfer(chunks: [
            .bytes(Data("HTTP/1.1 301 Moved\r\nLocation: https://user:secret@example.net/next\r\nContent-Length: 0\r\n\r\n".utf8))
        ])
        let result = HTTPExchange.perform(
            destination: try httpAction(url: "https://example.com/").destination,
            transfer: script.transfer(),
            deadline: Date().addingTimeInterval(2)
        )
        guard case .failure(.opened(.redirect(_, let location))) = result else {
            Issue.record("expected redirect, got \(result)")
            return
        }
        #expect(location?.contains("secret") == false)
        #expect(location == "https://example.net/next")
    }

    @Test func oversizedDeclaredBodyIsNotRead() throws {
        let script = ScriptedTransfer(chunks: [
            .bytes(Data("HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\n\r\n".utf8)),
            .bytes(Data(repeating: 0x61, count: 1_000_000)),
        ])
        let result = HTTPExchange.perform(
            destination: try httpAction(url: "https://example.com/").destination,
            transfer: script.transfer(),
            deadline: Date().addingTimeInterval(2)
        )
        #expect(result == .failure(.opened(.responseTooLarge)))
        #expect(script.reads == 1)
        #expect(script.stopped)
    }

    @Test func chunkedBodyStopsAtTheCap() throws {
        let header = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        var chunks: [HTTPTransferRead] = [.bytes(header)]
        let extra = HTTPEgressLimits.maxResponseBodyBytes + 64
        var remaining = extra
        while remaining > 0 {
            let size = min(1024, remaining)
            var piece = Data("\(String(size, radix: 16))\r\n".utf8)
            piece.append(Data(repeating: 0x62, count: size))
            piece.append(Data("\r\n".utf8))
            chunks.append(.bytes(piece))
            remaining -= size
        }
        chunks.append(.bytes(Data("0\r\n\r\n".utf8)))
        let script = ScriptedTransfer(chunks: chunks)
        let result = HTTPExchange.perform(
            destination: try httpAction(url: "https://example.com/").destination,
            transfer: script.transfer(),
            deadline: Date().addingTimeInterval(2)
        )
        #expect(result == .failure(.opened(.responseTooLarge)))
        #expect(script.stopped)
        #expect(script.leftover > 0)
    }

    @Test func stalledReadTimesOut() throws {
        let script = ScriptedTransfer(chunks: [.waiting, .waiting, .waiting, .waiting])
        let clock = AdvancingClock(start: Date(timeIntervalSince1970: 0), step: 2)
        let result = HTTPExchange.perform(
            destination: try httpAction(url: "https://example.com/").destination,
            transfer: script.transfer(),
            deadline: Date(timeIntervalSince1970: 1),
            now: clock.now
        )
        #expect(result == .failure(.opened(.timedOut)))
        #expect(script.stopped)
    }

    @Test func cancellationStopsTheRead() throws {
        let script = ScriptedTransfer(chunks: [.waiting])
        let gate = StopAfterFirst()
        let result = HTTPExchange.perform(
            destination: try httpAction(url: "https://example.com/").destination,
            transfer: script.transfer(),
            deadline: Date().addingTimeInterval(5),
            shouldStop: gate.shouldStop
        )
        #expect(result == .failure(.opened(.cancelled)))
        #expect(script.stopped)
    }

    @Test func loopbackDestinationDoesNotWrite() throws {
        let script = ScriptedTransfer(chunks: [
            .bytes(Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8))
        ])
        let destination = try httpAction(url: "https://127.0.0.1/").destination
        let result = HTTPExchange.perform(
            destination: destination,
            transfer: script.transfer(),
            deadline: Date().addingTimeInterval(2)
        )
        #expect(result == .failure(.notOpened(.forbiddenDestination)))
        #expect(script.written.isEmpty)
        #expect(script.reads == 0)
    }

    @Test func httpWireShapeRejectsShellFieldsAndExtraKeys() throws {
        let fixture = HTTPAdmissionFixture()
        let ok = RuntimeActionFrame(
            version: 1,
            requestID: RuntimeActionRequestID(),
            capability: fixture.capability,
            claimedSession: RuntimeSessionClaim(validating: fixture.session.id.rawValue.uuidString)!,
            action: .http(method: "GET", url: "https://example.com/")
        )
        let encoded = try RuntimeAdmissionCodec.encodeRequest(ok).get()
        var body = encoded.dropFirst(4)
        let decoded = try RuntimeAdmissionCodec.decodeRequest(Data(body)).get()
        #expect(decoded.action == ok.action)
        let extra = Data(
            """
            {"v":1,"id":"\(UUID().uuidString)","capability":"\(fixture.capability.rawValue)","session":"\(fixture.session.id.rawValue.uuidString)","method":"GET","url":"https://example.com/","command":"curl"}
            """.utf8
        )
        #expect(RuntimeAdmissionCodec.decodeRequest(extra) == .failure(.malformed))
        _ = body
    }

    @Test func admittedPublicGETExecutesOnceAndRecordsEvidenceWithoutTheQuery() throws {
        let fixture = HTTPAdmissionFixture()
        var binding: RuntimeChannelBinding? = fixture.binding
        var calls = 0
        let frame = fixture.httpFrame(url: "https://example.com/a?token=secret")
        let decision = RuntimeAdmissionGate.submit(
            binding: &binding,
            frame: .success(frame),
            propose: { accepted in
                fixture.propose(accepted)
            }
        )
        #expect(decision.execute != nil)
        #expect(decision.event.httpMethod == "GET")
        #expect(decision.event.httpDestination == "https://example.com:443/a")
        #expect(decision.event.httpAddress == "1.1.1.1")
        #expect(decision.event.httpQueryPresent == true)
        #expect(decision.event.httpDestination?.contains("secret") == false)
        #expect(decision.event.fingerprint?.contains("secret") == false)
        let sameID = frame
        var bindingReplay: RuntimeChannelBinding? = binding
        _ = bindingReplay
        let replay = RuntimeAdmissionGate.submit(
            binding: &binding,
            frame: .success(fixture.httpFrame(url: "https://example.com/a?token=secret"))
        ) { fixture.propose($0) }
        #expect(replay.execute == nil)
        #expect(replay.response == .rejected(.replay))
        var fresh: RuntimeChannelBinding? = fixture.binding
        _ = fresh
        let repeatedID = RuntimeAdmissionGate.submit(
            binding: &binding,
            frame: .success(sameID)
        ) { _ in
            calls += 1
            return .failure(.failed)
        }
        #expect(repeatedID.response == .rejected(.replay))
        #expect(calls == 0)
    }

    @Test func deniedPendingAndMalformedHTTPDoNotAuthorize() throws {
        let fixture = HTTPAdmissionFixture()
        var binding: RuntimeChannelBinding? = fixture.binding
        let denied = RuntimeAdmissionGate.submit(
            binding: &binding,
            frame: .success(fixture.httpFrame(url: "https://127.0.0.1/")),
            policy: .empty
        ) { fixture.propose($0) }
        #expect(denied.execute == nil)
        if case .denied = denied.response {
        } else {
            Issue.record("loopback must be denied, got \(denied.response)")
        }

        var pendingBinding: RuntimeChannelBinding? = fixture.binding
        let pending = RuntimeAdmissionGate.submit(
            binding: &pendingBinding,
            frame: .success(fixture.httpFrame(url: "https://example.com/")),
            policy: EffectiveActionPolicy(overlay: .mandatoryHuman(ActionPolicyEngine.Builtin.uncovered))
        ) { fixture.propose($0) }
        #expect(pending.execute == nil)
        #expect(pending.response == .pending(.mandatoryHuman))

        var failed: RuntimeChannelBinding? = fixture.binding
        let post = RuntimeAdmissionGate.submit(
            binding: &failed,
            frame: .success(fixture.httpFrame(method: "POST", url: "https://example.com/"))
        ) { fixture.propose($0) }
        #expect(post.execute == nil)
        #expect(post.response == .evaluationFailed)

        var scheme: RuntimeChannelBinding? = fixture.binding
        let http = RuntimeAdmissionGate.submit(
            binding: &scheme,
            frame: .success(fixture.httpFrame(url: "http://example.com/"))
        ) { fixture.propose($0) }
        #expect(http.execute == nil)
        #expect(http.response == .evaluationFailed)
    }

    #if os(macOS)
    @Test func localSocketFixtureParsesOneResponse() throws {
        let fixture = try LocalHTTPServer()
        defer { fixture.close() }
        let transfer = try fixture.connect()
        let receipt = try HTTPExchange.perform(
            destination: try httpAction(url: "https://example.com/fixture").destination,
            transfer: transfer,
            deadline: Date().addingTimeInterval(2)
        ).get()
        #expect(receipt.status == 204)
        #expect(receipt.body.isEmpty)
        let seen = fixture.requestText()
        #expect(seen.contains("GET /fixture HTTP/1.1"))
        #expect(seen.contains("Cookie") == false)
    }
    #endif
}

private func classify(_ text: String) -> HTTPAddressClass? {
    parseIPv4(text)?.addressClass
}

private func classify6(_ text: String) -> HTTPAddressClass? {
    parseIPv6(text)?.addressClass
}

private func httpSubject() throws -> RuntimeAdmissionSubject {
    let workspace = try #require(WorkingDirectory(validating: "/tmp/rv-http"))
    let session = RuntimeSession(
        id: RuntimeSessionID(),
        host: .opencode,
        workspace: workspace,
        mode: .contained(IsolationGuarantees.firstSliceContained(workspace: workspace)),
        backend: .seatbelt,
        startedAt: Date(timeIntervalSince1970: 0),
        child: nil
    )
    return RuntimeAdmissionSubject(session: session, policyWorkspace: workspace)
}

private func httpAction(url: String, resolved: HTTPIPAddress? = nil) throws -> HTTPAction {
    let canonical = try canonicalizeHTTP(method: "GET", url: url).get()
    let selection: HTTPAddressSelection
    if canonical.nameBlocked || canonical.literalAddress != nil {
        selection = .empty
    } else if let resolved {
        selection = resolved.isPublicGlobal ? .pinned(resolved) : .forbidden(resolved)
    } else {
        selection = .pinned(try #require(HTTPIPAddress(ipv4: [1, 1, 1, 1])))
    }
    return try #require(
        makeRuntimeHTTPAction(subject: try httpSubject(), canonical: canonical, resolved: selection)
    )
}

private struct HTTPAdmissionFixture {
    let session: RuntimeSession
    let capability: RuntimeCapability
    let binding: RuntimeChannelBinding

    init() {
        let workspace = WorkingDirectory(validating: "/tmp/rv-http")!
        let session = RuntimeSession(
            id: RuntimeSessionID(),
            host: .opencode,
            workspace: workspace,
            mode: .contained(IsolationGuarantees.firstSliceContained(workspace: workspace)),
            backend: .seatbelt,
            startedAt: Date(timeIntervalSince1970: 0),
            child: nil
        )
        let capability = RuntimeCapability()
        self.session = session
        self.capability = capability
        binding = RuntimeChannelBinding(session: session, capability: capability)
    }

    func httpFrame(method: String = "GET", url: String) -> RuntimeActionFrame {
        RuntimeActionFrame(
            version: 1,
            requestID: RuntimeActionRequestID(),
            capability: capability,
            claimedSession: RuntimeSessionClaim(validating: session.id.rawValue.uuidString)!,
            action: .http(method: method, url: url)
        )
    }

    func propose(
        _ frame: RuntimeActionFrame
    ) -> Result<ProposedAction, RuntimeAdmissionEvaluationError> {
        guard case .http(let method, let url) = frame.action else {
            return .failure(.failed)
        }
        return normalizeRuntimeHTTP(
            subject: RuntimeAdmissionSubject(session: session, policyWorkspace: session.workspace),
            method: method,
            url: url,
            resolve: { _ in .success([HTTPIPAddress(ipv4: [1, 1, 1, 1])!]) }
        )
    }
}

private final class AdvancingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private let step: TimeInterval

    init(start: Date, step: TimeInterval) {
        current = start
        self.step = step
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let value = current
        current = current.addingTimeInterval(step)
        return value
    }
}

private final class StopAfterFirst: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = false

    func shouldStop() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if seen { return true }
        seen = true
        return false
    }
}

private final class ScriptedTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [HTTPTransferRead]
    private(set) var written = Data()
    private(set) var reads = 0
    private(set) var stopped = false
    private(set) var bytesIssued = 0
    private(set) var leftover = 0

    init(chunks: [HTTPTransferRead]) {
        self.chunks = chunks
    }

    func transfer() -> HTTPTransfer {
        HTTPTransfer(
            write: { [self] data in
                self.lock.lock()
                self.written.append(data)
                self.lock.unlock()
                return .success(())
            },
            read: { [self] maximum, _ in
                self.lock.lock()
                defer { self.lock.unlock() }
                self.reads += 1
                if self.stopped { return .success(.end) }
                guard self.chunks.isEmpty == false else { return .success(.end) }
                let next = self.chunks.removeFirst()
                guard case .bytes(var data) = next else { return .success(next) }
                if data.count > maximum {
                    let head = Data(data.prefix(maximum))
                    data.removeFirst(maximum)
                    self.chunks.insert(.bytes(data), at: 0)
                    self.bytesIssued += head.count
                    self.leftover = self.chunks.count
                    return .success(.bytes(head))
                }
                self.bytesIssued += data.count
                self.leftover = self.chunks.count
                return .success(.bytes(data))
            },
            stop: { [self] in
                self.lock.lock()
                self.stopped = true
                self.lock.unlock()
            }
        )
    }
}

#if os(macOS)
import Darwin

private final class LocalHTTPServer {
    private let listenFD: Int32
    private let port: UInt16
    private let request = RequestBox()

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HTTPFixtureError() }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                bind(fd, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw HTTPFixtureError()
        }
        var storage = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                getsockname(fd, raw, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(fd)
            throw HTTPFixtureError()
        }
        listenFD = fd
        port = storage.sin_port
    }

    func connect() throws -> HTTPTransfer {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HTTPFixtureError() }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.connect(fd, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            throw HTTPFixtureError()
        }
        let accepted = Darwin.accept(listenFD, nil, nil)
        guard accepted >= 0 else {
            Darwin.close(fd)
            throw HTTPFixtureError()
        }
        let server = accepted
        let request = self.request
        Thread.detachNewThread {
            var header = Data()
            var buffer = [UInt8](repeating: 0, count: 512)
            while header.range(of: Data("\r\n\r\n".utf8)) == nil && header.count < 8_192 {
                let count = buffer.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.read(server, base, raw.count)
                }
                if count <= 0 { break }
                header.append(buffer, count: count)
            }
            request.store(header)
            let response = Data("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n".utf8)
            _ = response.withUnsafeBytes { raw in
                Darwin.write(server, raw.baseAddress, raw.count)
            }
        }
        return HTTPTransfer(
            write: { data in
                let bytes = [UInt8](data)
                let wrote = bytes.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.write(fd, base, raw.count)
                }
                return wrote == data.count ? .success(()) : .failure(.failed)
            },
            read: { maximum, _ in
                var buffer = [UInt8](repeating: 0, count: maximum)
                let count = buffer.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.read(fd, base, raw.count)
                }
                if count > 0 { return .success(.bytes(Data(buffer.prefix(count)))) }
                if count == 0 { return .success(.end) }
                return .failure(.failed)
            },
            stop: {
                Darwin.close(fd)
                Darwin.close(server)
            }
        )
    }

    func requestText() -> String {
        String(decoding: request.bytes(), as: UTF8.self)
    }

    func close() {
        Darwin.close(listenFD)
    }
}

private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ data: Data) {
        lock.lock()
        self.data = data
        lock.unlock()
    }

    func bytes() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private struct HTTPFixtureError: Error {}
#endif
