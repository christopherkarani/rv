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

/// T5 (Item 3): broker construction + dialer injection.
///
/// Consult returns the injection and the gate passes it as an argument to
/// the performing transport — no closure-sink, no request-ID correlation.
/// `.direct` threads it into the authorized request bytes as exactly one
/// `Authorization` header; `.effectWithCredential` hands it to
/// caller-supplied transfers. Legacy `.effect` keeps the Phase 5 hook tap.
/// Audit stays names-only everywhere. All helpers are T5-private so this
/// file links beside the shared admission suites untouched.
@Suite("RuntimeAdmissionBrokerInjection")
struct RuntimeAdmissionBrokerInjectionTests {
    @Test func credentialedEffectReceivesGrantedInjection() throws {
        let transport = T5CredentialedTransport()
        let harness = try T5AdmissionHarness(
            normalize: t5CombinedNormalize,
            http: .effectWithCredential(transport.run),
            broker: t5BrokerFixture(),
            delivery: nil
        )
        defer { harness.cleanup() }

        let decision = harness.session.submitLegacy(
            .success(harness.httpFrame("https://approved.example.com/v1/models", id: UUID()))
        )
        guard case .http(let receipt) = decision.response else {
            Issue.record("approved endpoint must execute, got \(decision.response)")
            return
        }
        #expect(receipt.status == 200)
        #expect(transport.runs == 1)
        #expect(transport.received.count == 1)
        let delivered = try #require(transport.received.first)
        #expect(delivered.injection?.credentialName == "API_KEY")
        #expect(delivered.injection?.host == "approved.example.com")
        #expect(delivered.injection?.value == t5SecretValue)
        // Return-value correlation: the injection rides with the exact
        // action being performed, no request-ID lookup.
        #expect(delivered.injection?.host == delivered.action.destination.host)
        let grantedEvents = harness.evidence.snapshot().filter {
            $0.result.hasPrefix("credential")
        }
        #expect(grantedEvents.count == 1)
        #expect(grantedEvents.first?.result == "credentialGranted:API_KEY")
        #expect(grantedEvents.first?.authorization == .allowed)
        #expect(grantedEvents.first?.executionAttempted == false)

        // Values never in the evidence structs.
        let encoded = try JSONEncoder().encode(harness.evidence.snapshot())
        #expect(String(decoding: encoded, as: UTF8.self).contains(t5SecretValue) == false)
    }

    @Test func credentialedEffectReceivesNilWhenWithheld() throws {
        let transport = T5CredentialedTransport()
        let harness = try T5AdmissionHarness(
            normalize: t5CombinedNormalize,
            http: .effectWithCredential(transport.run),
            broker: t5BrokerFixture(),
            delivery: nil
        )
        defer { harness.cleanup() }

        let decision = harness.session.submitLegacy(
            .success(harness.httpFrame("https://other.example.net/x", id: UUID()))
        )
        guard case .http = decision.response else {
            Issue.record("unapproved endpoint request must still execute, got \(decision.response)")
            return
        }
        #expect(transport.runs == 1)
        #expect(transport.received.count == 1)
        #expect(transport.received.first?.injection == nil)
        #expect(
            harness.evidence.snapshot().contains {
                $0.result == "credentialWithheld:endpointNotApproved" && $0.authorization == .denied
            }
        )
    }

    @Test func legacyEffectWithoutHookDropsGrantFailClosed() throws {
        let transport = T5LegacyTransport()
        let harness = try T5AdmissionHarness(
            normalize: t5CombinedNormalize,
            http: .effect(transport.run),
            broker: t5BrokerFixture(),
            delivery: nil
        )
        defer { harness.cleanup() }

        let decision = harness.session.submitLegacy(
            .success(harness.httpFrame("https://approved.example.com/v1/models", id: UUID()))
        )
        // The broker never breaks the request: it executes unauthenticated.
        guard case .http = decision.response else {
            Issue.record("unwired legacy transport must not break the request, got \(decision.response)")
            return
        }
        #expect(transport.runs == 1)
        let brokerEvents = harness.evidence.snapshot().filter {
            $0.result.hasPrefix("credential")
        }
        #expect(brokerEvents.count == 1)
        #expect(brokerEvents.first?.result == "credentialUnwired:API_KEY")
        #expect(brokerEvents.first?.authorization == .executorFailed)
        #expect(brokerEvents.first?.executionAttempted == false)
    }

    @Test func legacyEffectWithHookStillDeliversViaHook() throws {
        let transport = T5LegacyTransport()
        let delivery = T5HookCapture()
        let harness = try T5AdmissionHarness(
            normalize: t5CombinedNormalize,
            http: .effect(transport.run),
            broker: t5BrokerFixture(),
            delivery: delivery.deliver
        )
        defer { harness.cleanup() }

        let decision = harness.session.submitLegacy(
            .success(harness.httpFrame("https://approved.example.com/v1/models", id: UUID()))
        )
        guard case .http = decision.response else {
            Issue.record("approved endpoint must execute, got \(decision.response)")
            return
        }
        #expect(transport.runs == 1)
        #expect(delivery.all.count == 1)
        #expect(delivery.all.first?.credentialName == "API_KEY")
        #expect(delivery.all.first?.host == "approved.example.com")
        #expect(delivery.all.first?.value == t5SecretValue)
        #expect(
            harness.evidence.snapshot().contains {
                $0.result == "credentialGranted:API_KEY" && $0.authorization == .allowed
            }
        )
    }

    @Test func exchangeWritesSingleAuthorizationHeader() throws {
        let action = try t5PublicAction(url: "https://approved.example.com/v1/models")
        let capture = T5CapturingTransfer(
            response: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
        )
        let credential = "Bearer \(t5SecretValue)"
        let receipt = try HTTPExchange.perform(
            destination: action.destination,
            transfer: capture.transfer(),
            deadline: Date().addingTimeInterval(5),
            credential: credential
        ).get()
        #expect(receipt.status == 200)
        #expect(String(decoding: receipt.body, as: UTF8.self) == "ok")
        let text = String(decoding: capture.written, as: UTF8.self)
        let expected = "GET /v1/models HTTP/1.1\r\n"
            + "Host: approved.example.com\r\n"
            + "User-Agent: \(HTTPEgressLimits.userAgent)\r\n"
            + "Accept: */*\r\n"
            + "Connection: close\r\n"
            + "Authorization: \(credential)\r\n"
            + "\r\n"
        #expect(text == expected)
        #expect(text.components(separatedBy: "Authorization:").count == 2)
    }

    @Test func exchangeOmitsAuthorizationWithoutCredential() throws {
        let action = try t5PublicAction(url: "https://approved.example.com/v1/models")
        let capture = T5CapturingTransfer(
            response: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
        )
        let receipt = try HTTPExchange.perform(
            destination: action.destination,
            transfer: capture.transfer(),
            deadline: Date().addingTimeInterval(5),
            credential: nil
        ).get()
        #expect(receipt.status == 200)
        let text = String(decoding: capture.written, as: UTF8.self)
        let expected = "GET /v1/models HTTP/1.1\r\n"
            + "Host: approved.example.com\r\n"
            + "User-Agent: \(HTTPEgressLimits.userAgent)\r\n"
            + "Accept: */*\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        #expect(text == expected)
        #expect(text.contains("Authorization:") == false)
    }

    @Test func credentialGuardMustScanBytesNotCharacters() {
        // CRLF is a single Swift grapheme: Character-element contains()
        // matches neither half of it. The credential guard therefore scans
        // UTF-8 bytes; this pins the trap so nobody "simplifies" it back.
        #expect("secret\r\nInjected: yes".contains("\r") == false)
        #expect("secret\r\nInjected: yes".contains("\n") == false)
        #expect("secret\r\nInjected: yes".utf8.contains(0x0D))
        #expect("secret\r\nInjected: yes".utf8.contains(0x0A))
    }

    @Test func exchangeFailsClosedOnMalformedCredential() throws {
        let action = try t5PublicAction(url: "https://approved.example.com/v1/models")
        for bad in ["secret\r\nInjected: yes", "secret\nnewline", "", "a\rb", "bad" + String(UnicodeScalar(0x7F)!) + "del"] {
            let capture = T5CapturingTransfer(
                response: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
            )
            let result = HTTPExchange.perform(
                destination: action.destination,
                transfer: capture.transfer(),
                deadline: Date().addingTimeInterval(5),
                credential: bad
            )
            #expect(result == .failure(.notOpened(.unavailable)), "value: \(bad.debugDescription)")
            #expect(capture.written.isEmpty, "value: \(bad.debugDescription)")
        }
    }

    #if os(macOS)
    @Test func directConnectorRefusesLoopbackWithCredentialBeforeAccept() throws {
        let listener = try T5BoundListener()
        defer { listener.close() }
        let action = try t5LoopbackAction()
        let result = HTTPDirectExecutor.perform(
            action,
            credential: BrokeredCredentialInjection(
                credentialName: "API_KEY",
                host: "127.0.0.1",
                value: t5SecretValue
            ),
            cancellation: HTTPCancellation(),
            shouldStop: { false }
        )
        #expect(result == .failure(.notOpened(.forbiddenDestination)))
        #expect(listener.accepted == false)
    }
    #endif
}

private let t5SecretValue = "test-t5-broker-secret-BBB222"

private func t5BrokerFixture(revision: UInt64 = 7) -> ContainedCredentialBroker {
    ContainedCredentialBroker(
        credentials: [
            "API_KEY": ContainedCredentialBroker.Credential(
                value: t5SecretValue,
                kind: .secret,
                approvedHosts: ["approved.example.com"],
                placeholder: true
            ),
            "AWS_CREDENTIAL_PROFILE": ContainedCredentialBroker.Credential(
                value: "prod-profile",
                kind: .selector,
                approvedHosts: []
            ),
        ],
        grants: ["approved.example.com": "API_KEY"],
        revision: revision
    )
}

private struct T5PerformedCredentialedRequest: Sendable {
    var action: HTTPAction
    var injection: BrokeredCredentialInjection?
}

private final class T5CredentialedTransport: Sendable {
    private let box = Mutex<T5CredentialedState>(T5CredentialedState())

    private struct T5CredentialedState: Sendable {
        var runs = 0
        var received: [T5PerformedCredentialedRequest] = []
    }

    var runs: Int { box.withLock { $0.runs } }
    var received: [T5PerformedCredentialedRequest] { box.withLock { $0.received } }

    func run(
        _ action: HTTPAction,
        _ credential: BrokeredCredentialInjection?,
        _: HTTPCancellation,
        _: @escaping @Sendable () -> Bool
    ) -> Result<HTTPExecutionReceipt, HTTPEgressFailure> {
        box.withLock {
            $0.runs += 1
            $0.received.append(T5PerformedCredentialedRequest(action: action, injection: credential))
        }
        return .success(
            HTTPExecutionReceipt(
                status: 200,
                destination: action.destination.auditedResource,
                headers: [],
                body: Data("ok".utf8)
            )
        )
    }
}

private final class T5LegacyTransport: Sendable {
    private let runsBox = Mutex(0)

    var runs: Int { runsBox.withLock { $0 } }

    func run(
        _ action: HTTPAction,
        _: HTTPCancellation,
        _: @escaping @Sendable () -> Bool
    ) -> Result<HTTPExecutionReceipt, HTTPEgressFailure> {
        runsBox.withLock { $0 += 1 }
        return .success(
            HTTPExecutionReceipt(
                status: 200,
                destination: action.destination.auditedResource,
                headers: [],
                body: Data("ok".utf8)
            )
        )
    }
}

private final class T5HookCapture: Sendable {
    private let box = Mutex<[BrokeredCredentialInjection]>([])

    var all: [BrokeredCredentialInjection] { box.withLock { $0 } }

    func deliver(_ injection: BrokeredCredentialInjection) {
        box.withLock { $0.append(injection) }
    }
}

private final class T5CapturingTransfer: Sendable {
    private let box: Mutex<T5CaptureState>

    private struct T5CaptureState: Sendable {
        var written = Data()
        var served = false
        var response: Data
    }

    init(response: String) {
        box = Mutex(T5CaptureState(response: Data(response.utf8)))
    }

    var written: Data { box.withLock { $0.written } }

    func transfer() -> HTTPTransfer {
        HTTPTransfer(
            write: { [self] data in
                self.box.withLock { $0.written.append(data) }
                return .success(())
            },
            read: { [self] _, _ in
                self.box.withLock { state -> Result<HTTPTransferRead, HTTPTransferFault> in
                    if state.served == false {
                        state.served = true
                        return .success(.bytes(state.response))
                    }
                    return .success(.end)
                }
            },
            stop: {}
        )
    }
}

private final class T5AdmissionEffect: Sendable {
    func run(_: AllowedAction) -> Result<Int32, RuntimeAdmissionExecutorError> {
        .success(0)
    }
}

private struct T5AdmissionHarness {
    let root: URL
    let runtime: RuntimeSession
    let capability: RuntimeCapability
    let requestID: UUID
    let effect: T5AdmissionEffect
    let evidence: RuntimeAdmissionEvidence
    let session: RuntimeAdmissionSession

    init(
        normalize: @escaping @Sendable (
            RuntimeAdmissionSubject, RuntimeRequestedAction
        ) -> Result<ProposedAction, RuntimeAdmissionEvaluationError>,
        http: RuntimeHTTPExecutor,
        broker: ContainedCredentialBroker? = nil,
        delivery: (@Sendable (BrokeredCredentialInjection) -> Void)? = nil
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-t5-admission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = try #require(WorkingDirectory(validating: root.path))
        let plan = compileContainedPlan(workspace: workspace)
        let runtime = RuntimeSession(
            id: RuntimeSessionID(),
            workspaceSessionID: WorkspaceSessionID(),
            host: .opencode,
            workspace: workspace,
            backend: .seatbelt,
            startedAt: Date(),
            child: nil
        )
        let capability = RuntimeCapability()
        let effect = T5AdmissionEffect()
        let evidence = RuntimeAdmissionEvidence()
        let configuration = RuntimeAdmissionConfiguration(
            normalize: normalize,
            executor: .effect(effect.run),
            http: http,
            approval: { _, _ in nil },
            policy: { _ in .empty },
            evidence: evidence,
            credentialBroker: broker,
            credentialDelivery: delivery
        )
        self.root = root
        self.runtime = runtime
        self.capability = capability
        self.requestID = UUID()
        self.effect = effect
        self.evidence = evidence
        session = RuntimeAdmissionSession(
            binding: RuntimeChannelBinding(session: runtime, capability: capability),
            configuration: configuration,
            launch: AdmittedLaunchContext(
                plan: plan,
                profileSource: "(deny file-link)",
                profileIsContainedCompilerOutput: true,
                workspacePath: workspace.rawValue
            ),
            requestRead: -1,
            responseWrite: -1
        )
    }

    func httpFrame(
        _ url: String,
        method: String = "GET",
        capability: RuntimeCapability? = nil,
        claim: UUID? = nil,
        id: UUID? = nil
    ) -> RuntimeActionFrame {
        RuntimeActionFrame(
            version: 1,
            requestID: RuntimeActionRequestID(validating: (id ?? requestID).uuidString)!,
            capability: capability ?? self.capability,
            claimedSession: RuntimeSessionClaim(validating: (claim ?? runtime.id.rawValue).uuidString)!,
            action: .http(method: method, url: url)
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func t5CombinedNormalize(
    subject: RuntimeAdmissionSubject,
    action: RuntimeRequestedAction
) -> Result<ProposedAction, RuntimeAdmissionEvaluationError> {
    guard case .http(let method, let url) = action else {
        return .failure(.failed)
    }
    return normalizeRuntimeHTTP(subject: subject, method: method, url: url) { host in
        switch host {
        case "approved.example.com", "other.example.net":
            return .success([HTTPIPAddress(ipv4: [1, 1, 1, 1])!])
        default:
            return .failure(.failed)
        }
    }
}

private func t5PublicAction(url: String) throws -> HTTPAction {
    let workspace = try #require(WorkingDirectory(validating: "/tmp/rv-t5-http-admission"))
    let session = RuntimeSession(
        id: RuntimeSessionID(),
        workspaceSessionID: WorkspaceSessionID(),
        host: .opencode,
        workspace: workspace,
        backend: .seatbelt,
        startedAt: Date(timeIntervalSince1970: 0),
        child: nil
    )
    let proposed = normalizeRuntimeHTTP(
        subject: RuntimeAdmissionSubject(session: session, policyWorkspace: workspace),
        method: "GET",
        url: url
    ) { _ in .success([HTTPIPAddress(ipv4: [1, 1, 1, 1])!]) }
    guard case .success(.http(let action)) = proposed else {
        throw T5FixtureError()
    }
    #expect(action.destination.isPublicPinned)
    return action
}

private struct T5FixtureError: Error {}

#if os(macOS)
private func t5LoopbackAction() throws -> HTTPAction {
    let workspace = try #require(WorkingDirectory(validating: "/tmp/rv-t5-http-admission"))
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

private final class T5BoundListener {
    let fd: Int32

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw T5FixtureError() }
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
            throw T5FixtureError()
        }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        self.fd = fd
    }

    var accepted: Bool {
        Darwin.accept(fd, nil, nil) >= 0
    }

    func close() {
        Darwin.close(fd)
    }
}
#endif
