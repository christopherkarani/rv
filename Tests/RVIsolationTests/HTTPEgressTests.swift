#if canImport(Darwin)
import Darwin
#endif
import Foundation
import RVDomain
import Synchronization
import Testing
@testable import RVIsolation

@Suite("HTTP admission")
struct HTTPAdmissionTests {
    @Test func resolutionDoesNotStartWhenTheSessionHasStopped() {
        let lookedUp = Mutex(false)
        let result = RuntimeAdmissionStop.$shouldStop.withValue({ true }) {
            resolveAdmittedHTTPHost(
                "example.com",
                budgetMilliseconds: 5_000,
                lookup: { _ in
                    lookedUp.withLock { $0 = true }
                    return .failure(.failed)
                }
            )
        }
        #expect(result == .failure(.failed))
        #expect(lookedUp.withLock { $0 } == false)
    }

    @Test func resolutionReturnsWhenTheSessionStopsDuringLookup() {
        let release = Mutex(false)
        let stop = Mutex(false)
        let entered = Mutex(false)
        defer { release.withLock { $0 = true } }
        let result = RuntimeAdmissionStop.$shouldStop.withValue({ stop.withLock { $0 } }) {
            resolveAdmittedHTTPHost(
                "example.com",
                budgetMilliseconds: 20_000,
                lookup: { _ in
                    entered.withLock { $0 = true }
                    stop.withLock { $0 = true }
                    while release.withLock({ $0 }) == false {
                        usleep(1_000)
                    }
                    return .success([])
                }
            )
        }
        #expect(entered.withLock { $0 })
        #expect(result == .failure(.failed))
    }

    @Test func allowedGETRunsOnce() throws {
        let harness = try HTTPHarness()
        let first = harness.session.submit(.success(harness.frame("https://example.com/a")))
        #expect(harness.spy.calls == 1)
        #expect(first.event.executionAttempted)
        #expect(first.event.httpMethod == "GET")
        #expect(first.event.httpDestination == "https://example.com:443/a")
        #expect(first.event.httpAddress == "1.1.1.1")
        guard case .http(let receipt) = first.response else {
            Issue.record("expected an HTTP receipt, got \(first.response)")
            return
        }
        #expect(receipt.status == 204)
        let replay = harness.session.submit(.success(harness.frame("https://example.com/a")))
        #expect(harness.spy.calls == 1)
        #expect(replay.response == .rejected(.replay))
        #expect(replay.event.executionAttempted == false)
    }

    @Test func capabilitySessionAndClosureDoNotRun() throws {
        let harness = try HTTPHarness()
        let other = try HTTPHarness()
        let missing = harness.session.submit(
            .success(harness.frame("https://example.com/", capability: RuntimeCapability()))
        )
        let foreign = harness.session.submit(.success(other.frame("https://example.com/")))
        let impersonated = harness.session.submit(
            .success(harness.frame("https://example.com/", claim: other.runtime.id.rawValue))
        )
        #expect(missing.response == .rejected(.invalidCapability))
        #expect(foreign.response == .rejected(.invalidCapability))
        #expect(impersonated.response == .rejected(.impersonation))
        #expect(harness.spy.calls == 0)
        harness.session.finish()
        let encoded = try RuntimeAdmissionCodec.encodeRequest(
            harness.frame("https://example.com/")
        ).get()
        let stale = harness.session.accept(encoded)
        #expect(stale.first?.response == .rejected(.inactiveSession))
        #expect(harness.spy.calls == 0)
    }

    @Test func denyPendingAndFailureDoNotRun() throws {
        let harness = try HTTPHarness()
        let denied = harness.session.submit(.success(harness.frame("https://10.0.0.8/")))
        #expect(harness.spy.calls == 0)
        if case .denied = denied.response {
        } else {
            Issue.record("private address must be denied, got \(denied.response)")
        }
        let dns = harness.session.submit(.success(harness.frame("https://allowed.example/")))
        #expect(harness.spy.calls == 0)
        if case .denied = dns.response {
        } else {
            Issue.record("private DNS answer must be denied, got \(dns.response)")
        }
        let pending = try HTTPHarness(policy: .mandatoryHuman)
        let asked = pending.session.submit(.success(pending.frame("https://example.com/")))
        #expect(pending.spy.calls == 0)
        #expect(asked.response == .pending(.mandatoryHuman))
        let approved = try HTTPHarness(
            policy: .mandatoryHuman,
            approval: { _ in .success(.allowOnce) }
        )
        let ran = approved.session.submit(.success(approved.frame("https://example.com/")))
        #expect(approved.spy.calls == 1)
        guard case .http = ran.response else {
            Issue.record("allow-once must execute, got \(ran.response)")
            return
        }
        let post = harness.session.submit(.success(harness.frame("https://example.com/", method: "POST")))
        let scheme = harness.session.submit(.success(harness.frame("http://example.com/")))
        let broken = harness.session.submit(.success(harness.frame("https://example.com/ a")))
        #expect(post.response == .evaluationFailed)
        #expect(scheme.response == .evaluationFailed)
        #expect(broken.response == .evaluationFailed)
        #expect(harness.spy.calls == 0)
    }

    @Test func redirectDoesNotOpenASecondTransfer() throws {
        let harness = try HTTPHarness(exchange: .redirect)
        let decision = harness.session.submit(.success(harness.frame("https://example.com/start")))
        #expect(harness.spy.calls == 1)
        #expect(decision.event.executionAttempted)
        guard case .httpFailed(.redirect(let status, let location)) = decision.response else {
            Issue.record("expected redirect, got \(decision.response)")
            return
        }
        #expect(status == 302)
        #expect(location == "http://127.0.0.1/")
        #expect(decision.event.httpStatus == 302)
    }

    @Test func cancellationStopsTheExchangeBeforeFinishReturns() throws {
        let harness = try HTTPHarness(exchange: .blockUntilCancel)
        let started = DispatchSemaphore(value: 0)
        harness.spy.started = started
        let finished = DispatchSemaphore(value: 0)
        let worker = Thread {
            _ = harness.session.submit(.success(harness.frame("https://example.com/")))
            finished.signal()
        }
        worker.start()
        #expect(started.wait(timeout: .now() + 2) == .success)
        harness.session.finish()
        #expect(harness.spy.stopped)
        #expect(finished.wait(timeout: .now() + 2) == .success)
    }

    #if os(macOS)
    @Test func directConnectorRefusesLoopbackBeforeAccept() throws {
        let listener = try BoundListener()
        defer { listener.close() }
        let action = try loopbackAction()
        let result = HTTPDirectExecutor.perform(
            action,
            cancellation: HTTPCancellation(),
            shouldStop: { false }
        )
        #expect(result == .failure(.notOpened(.forbiddenDestination)))
        #expect(listener.accepted == false)
    }

    @Test func directConfigurationDisablesProxiesAndCredentials() throws {
        let address = try #require(HTTPIPAddress(ipv4: [1, 1, 1, 1]))
        setenv("HTTP_PROXY", "http://127.0.0.1:9", 1)
        setenv("HTTPS_PROXY", "http://127.0.0.1:9", 1)
        setenv("ALL_PROXY", "http://127.0.0.1:9", 1)
        defer {
            unsetenv("HTTP_PROXY")
            unsetenv("HTTPS_PROXY")
            unsetenv("ALL_PROXY")
        }
        let configuration = DirectHTTPConnection.configuration(
            address: address,
            port: 443,
            serverName: "example.com"
        )
        #expect(configuration.preferNoProxies)
        #expect(configuration.includePeerToPeer == false)
        #expect(configuration.minimumTLS12)
        #expect(configuration.alpn == ["http/1.1"])
        #expect(configuration.usesURLSession == false)
        #expect(configuration.sendsAmbientCredentials == false)
        #expect(configuration.peer == "1.1.1.1")
        #expect(configuration.serverName == "example.com")
        let parameters = DirectHTTPConnection.makeParameters(configuration)
        #expect(parameters.preferNoProxies)
        #expect(parameters.includePeerToPeer == false)
        let endpoint = try #require(DirectHTTPConnection.endpoint(address: address, port: 443))
        #expect(DirectHTTPConnection.peerMatches(endpoint, address: address, port: 443))
        let other = try #require(HTTPIPAddress(ipv4: [8, 8, 8, 8]))
        #expect(DirectHTTPConnection.peerMatches(endpoint, address: other, port: 443) == false)
    }
    #endif
}

private enum HTTPHarnessPolicy {
    case empty
    case mandatoryHuman
}

private enum HTTPHarnessExchange {
    case empty
    case redirect
    case blockUntilCancel
}

private final class HTTPSpy: @unchecked Sendable {
    var calls = 0
    var stopped = false
    var started: DispatchSemaphore?
    let exchange: HTTPHarnessExchange

    init(exchange: HTTPHarnessExchange) {
        self.exchange = exchange
    }

    func run(
        _ action: HTTPAction,
        _ cancellation: HTTPCancellation,
        _ shouldStop: @escaping @Sendable () -> Bool
    ) -> Result<HTTPExecutionReceipt, HTTPEgressFailure> {
        calls += 1
        switch exchange {
        case .empty:
            return .success(
                HTTPExecutionReceipt(
                    status: 204,
                    destination: action.destination.auditedResource,
                    headers: [],
                    body: Data()
                )
            )
        case .redirect:
            let script = OneShotTransfer(
                response: "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1/\r\nContent-Length: 0\r\n\r\n"
            )
            return HTTPExchange.perform(
                destination: action.destination,
                transfer: script.transfer(),
                deadline: Date().addingTimeInterval(2),
                shouldStop: shouldStop
            )
        case .blockUntilCancel:
            started?.signal()
            while cancellation.isCancelled == false && shouldStop() == false {
                usleep(1_000)
            }
            stopped = true
            return .failure(.opened(.cancelled))
        }
    }
}

/// The cancellation test shares this with one worker thread and joins it
/// before the harness is released.
private struct HTTPHarness: @unchecked Sendable {
    let runtime: RuntimeSession
    let spy: HTTPSpy
    let session: RuntimeAdmissionSession
    let capability: RuntimeCapability

    init(
        policy: HTTPHarnessPolicy = .empty,
        approval: @escaping @Sendable (PendingAuthorization) -> Result<ApprovalDecision, AgentApprovalError>? = { _ in nil },
        exchange: HTTPHarnessExchange = .empty
    ) throws {
        let workspace = try #require(WorkingDirectory(validating: "/tmp/rv-http-admission"))
        let plan = compileContainedPlan(workspace: workspace)
        let runtime = RuntimeSession(
            id: RuntimeSessionID(),
            workspaceSessionID: WorkspaceSessionID(),
            host: .opencode,
            workspace: workspace,
            backend: .seatbelt,
            startedAt: Date(timeIntervalSince1970: 0),
            child: nil
        )
        let capability = RuntimeCapability()
        let spy = HTTPSpy(exchange: exchange)
        let effective: EffectiveActionPolicy
        switch policy {
        case .empty:
            effective = .empty
        case .mandatoryHuman:
            effective = EffectiveActionPolicy(
                overlay: .mandatoryHuman(ActionPolicyEngine.Builtin.uncovered)
            )
        }
        let configuration = RuntimeAdmissionConfiguration(
            normalize: { subject, action in
                guard case .http(let method, let url) = action else {
                    return .failure(.failed)
                }
                return normalizeRuntimeHTTP(
                    subject: subject,
                    method: method,
                    url: url,
                    resolve: { name in
                        if name == "allowed.example" {
                            return .success([HTTPIPAddress(ipv4: [127, 0, 0, 1])!])
                        }
                        return .success([HTTPIPAddress(ipv4: [1, 1, 1, 1])!])
                    }
                )
            },
            executor: .refuse,
            http: .effect(spy.run),
            approval: approval,
            policy: { _ in effective },
            evidence: RuntimeAdmissionEvidence()
        )
        self.runtime = runtime
        self.spy = spy
        self.capability = capability
        session = RuntimeAdmissionSession(
            binding: RuntimeChannelBinding(session: runtime, capability: capability),
            configuration: configuration,
            launch: AdmittedLaunchContext(
                plan: plan,
                profileSource: "(deny file-link)",
                workspacePath: workspace.rawValue
            ),
            requestRead: -1,
            responseWrite: -1
        )
    }

    func frame(
        _ url: String,
        method: String = "GET",
        capability: RuntimeCapability? = nil,
        claim: UUID? = nil
    ) -> RuntimeActionFrame {
        RuntimeActionFrame(
            version: 1,
            requestID: RuntimeActionRequestID(),
            capability: capability ?? self.capability,
            claimedSession: RuntimeSessionClaim(validating: (claim ?? runtime.id.rawValue).uuidString)!,
            action: .http(method: method, url: url)
        )
    }
}

private final class OneShotTransfer: @unchecked Sendable {
    let response: String
    init(response: String) { self.response = response }

    func transfer() -> HTTPTransfer {
        let payload = Data(response.utf8)
        let state = TransferState(payload: payload)
        return HTTPTransfer(
            write: { _ in .success(()) },
            read: { _, _ in state.take() },
            stop: {}
        )
    }
}

private final class TransferState: @unchecked Sendable {
    private let lock = NSLock()
    private var payload: Data
    init(payload: Data) { self.payload = payload }

    func take() -> Result<HTTPTransferRead, HTTPTransferFault> {
        lock.lock()
        defer { lock.unlock() }
        if payload.isEmpty { return .success(.end) }
        let data = payload
        payload.removeAll()
        return .success(.bytes(data))
    }
}

#if os(macOS)
private func loopbackAction() throws -> HTTPAction {
    let workspace = try #require(WorkingDirectory(validating: "/tmp/rv-http-admission"))
    let session = RuntimeSession(
        id: RuntimeSessionID(),
        workspaceSessionID: WorkspaceSessionID(),
        host: .opencode,
        workspace: workspace,
        backend: .seatbelt,
        startedAt: Date(timeIntervalSince1970: 0),
        child: nil
    )
    let canonical = try canonicalizeHTTP(method: "GET", url: "https://127.0.0.1/").get()
    return try #require(
        makeRuntimeHTTPAction(
            subject: RuntimeAdmissionSubject(session: session, policyWorkspace: workspace),
            canonical: canonical,
            resolved: .empty
        )
    )
}

private final class BoundListener {
    let fd: Int32
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ListenerError() }
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
            throw ListenerError()
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
            throw ListenerError()
        }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        self.fd = fd
        port = storage.sin_port
    }

    var accepted: Bool {
        Darwin.accept(fd, nil, nil) >= 0
    }

    func close() {
        Darwin.close(fd)
    }
}

private struct ListenerError: Error {}
#endif
