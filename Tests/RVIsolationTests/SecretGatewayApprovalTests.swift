import Foundation
import Synchronization
import RVDomain
import RVIPC
import Testing
@testable import RVIsolation

/// `approve` rules: a matching request is filed for a human through the
/// runtime's admission channel, refused as pending, and forwarded once when
/// an identical retry finds the approval granted.
@Suite("Secret gateway request approvals")
struct SecretGatewayApprovalTests {
    static let json = """
        {"version":1,"secrets":[
          {"name":"GH","source":{"hostEnvironment":{"variable":"FAKE_GH"}},
           "delivery":{"gateway":{"upstream":"https://api.example.com","baseURLEnv":"GH_API",
                                  "approve":[{"methods":["POST","DELETE"],"path":"/repos/**"}]}}}
        ]}
        """
    static let fast = GatewayApprovalTiming(wait: 0.2, poll: 0.01, maximumWaiting: 4)

    struct Harness {
        let fixture: SecretsFixture
        let broker: SecretLaunchBroker
        let upstream: RecordingUpstream
        let lease: SecretLease
        let park: ParkHarness?
        let port: Int
        var placeholder: String { lease.environment.first { $0.name == "GH" }?.value ?? "" }
        var backend: FakeAskBackend { park!.backend }

        func tearDown() {
            broker.stop()
            fixture.tearDown()
            park?.cleanup()
        }
    }

    private func harness(
        approver: Bool = true, timing: GatewayApprovalTiming = fast,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws -> Harness {
        let fixture = try SecretsFixture(Self.json)
        let upstream = RecordingUpstream()
        let resolver = SecretResolver { _ in .success(SecretValue("ghp_realtoken_approval")!) }
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory, resolver: resolver, transport: upstream.transport,
            peers: .fixed(.member), workspace: "W1", now: now, approvalTiming: timing)
        let lease = try broker.lease(names: ["GH"], agent: nil).get()
        broker.bind(lease, processGroup: testProcessGroup)
        var park: ParkHarness?
        if approver {
            let built = try ParkHarness()
            broker.bind(lease, approver: try #require(built.session.secretRequestApprover()))
            park = built
        }
        return Harness(
            fixture: fixture, broker: broker, upstream: upstream, lease: lease, park: park,
            port: try #require(broker.gatewayPort))
    }

    private func send(_ h: Harness, _ method: String = "POST", path: String = "/repos/o/r/merges", body: String = "{\"base\":\"main\"}")
        throws -> GatewayExchange
    {
        try gatewayExchange(port: h.port,
            "\(method) /s/GH\(path) HTTP/1.1\r\nAuthorization: Bearer \(h.placeholder)\r\n"
                + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)")
    }

    private func refusals(_ fixture: SecretsFixture) -> [String] {
        fixture.auditLines.filter { $0["kind"] as? String == "secret.use" }
            .compactMap { ($0["detail"] as? [String: String])?["refusal"] }
    }

    private func requested(_ h: Harness) -> [SecretRequestAction] {
        h.backend.snapshot.creates.compactMap {
            if case .secretRequest(let request) = $0.action { return request }
            return nil
        }
    }

    @Test func aMatchingRequestIsHeldThenAnIdenticalRetryIsForwardedOnce() throws {
        let h = try harness()
        defer { h.tearDown() }
        let pending = try send(h)
        #expect(pending.status == 403)
        #expect(pending.body.contains("approv"))
        #expect(h.upstream.requests.isEmpty)
        let asked = try #require(requested(h).first)
        #expect(asked.secret == "GH")
        #expect(asked.method == "POST")
        #expect(asked.host == "api.example.com")
        #expect(asked.path == "/repos/o/r/merges")
        #expect(asked.bodyBytes == 15)
        #expect(h.backend.snapshot.creates.first?.reason == .mandatoryHuman)

        let approval = try #require(h.backend.snapshot.created.first)
        h.backend.setStatusScript([.authorized], for: approval.approvalID)
        h.backend.setConsumable(approval.approvalID)
        #expect(try send(h).status == 200)
        #expect(h.upstream.requests.count == 1)
        #expect(h.upstream.requests.first?.headers["authorization"] == "Bearer ghp_realtoken_approval")
        #expect(h.backend.snapshot.consumeCalls == [approval.approvalID])

        // Single use: the same request again asks again.
        #expect(try send(h).status == 403)
        #expect(requested(h).count == 2)
        #expect(h.upstream.requests.count == 1)
        #expect(refusals(h.fixture) == ["approvalPending", "approvalPending"])
        #expect(h.fixture.auditLines.contains { $0["kind"] as? String == "secret.misuse" } == false)
    }

    @Test func theApprovalBindsTheBodyAndQuery() throws {
        let h = try harness()
        defer { h.tearDown() }
        _ = try send(h)
        let approval = try #require(h.backend.snapshot.created.first)
        h.backend.setStatusDefault(.authorized)
        h.backend.setConsumable(approval.approvalID)
        #expect(try send(h, body: "{\"base\":\"prod\"}").status == 403)
        #expect(try send(h, path: "/repos/o/r/merges?force=1").status == 403)
        #expect(h.upstream.requests.isEmpty)
        let digests = Set(requested(h).map { CanonicalActionDigest.sha256Hex(of: .secretRequest($0)) })
        #expect(digests.count == 3)
        for request in requested(h) {
            #expect(request.path.contains("?") == false)
            #expect(request.fingerprint.rawValue.contains("rvph_") == false)
        }
    }

    @Test func requestsOutsideTheApproveRulesAreNotHeld() throws {
        let h = try harness()
        defer { h.tearDown() }
        #expect(try send(h, "GET", path: "/repos/o/r", body: "").status == 200)
        #expect(try send(h, path: "/user/repos").status == 200)
        #expect(h.backend.snapshot.creates.isEmpty)
    }

    @Test func aDeniedApprovalRefusesAndTheNextRequestAsksAgain() throws {
        let h = try harness()
        defer { h.tearDown() }
        _ = try send(h)
        let approval = try #require(h.backend.snapshot.created.first)
        h.backend.setStatusScript([.denied], for: approval.approvalID)
        #expect(try send(h).status == 403)
        #expect(try send(h).status == 403)
        #expect(requested(h).count == 2)
        #expect(refusals(h.fixture) == ["approvalPending", "approvalDenied", "approvalPending"])
        #expect(h.upstream.requests.isEmpty)
    }

    @Test func anApprovalTheServiceWillNotConsumeIsDenied() throws {
        let h = try harness()
        defer { h.tearDown() }
        _ = try send(h)
        let approval = try #require(h.backend.snapshot.created.first)
        h.backend.setStatusScript([.authorized], for: approval.approvalID)
        #expect(try send(h).status == 403)
        #expect(refusals(h.fixture).last == "approvalDenied")
        #expect(h.upstream.requests.isEmpty)
    }

    @Test func withoutAnApproverMatchingRequestsAreRefused() throws {
        let h = try harness(approver: false)
        defer { h.tearDown() }
        #expect(try send(h).status == 403)
        #expect(refusals(h.fixture) == ["approvalUnavailable"])
        #expect(h.upstream.requests.isEmpty)
    }

    @Test func anApprovalServiceThatCannotFileIsRefused() throws {
        let h = try harness()
        defer { h.tearDown() }
        h.backend.setCreateDeclined(true)
        #expect(try send(h).status == 403)
        #expect(refusals(h.fixture) == ["approvalUnavailable"])
        #expect(h.upstream.requests.isEmpty)
    }

    @Test func pastTheWaitingCapARequestIsNotHeldOpen() throws {
        let h = try harness(timing: GatewayApprovalTiming(wait: 5, poll: 0.01, maximumWaiting: 0))
        defer { h.tearDown() }
        let started = Date()
        #expect(try send(h).status == 403)
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(refusals(h.fixture) == ["approvalPending"])
    }

    @Test func concurrentIdenticalRequestsShareOneApproval() throws {
        let h = try harness()
        defer { h.tearDown() }
        // Barrier: every filer is inside createApproval before any returns.
        let filing = Mutex(0)
        h.backend.setOnCreate {
            filing.withLock { $0 += 1 }
            let deadline = Date().addingTimeInterval(5)
            while filing.withLock({ $0 }) < 4, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        }
        let statuses = Mutex<[Int]>([])
        let threads = (0..<4).map { _ in
            Thread {
                let status = (try? send(h).status) ?? -1
                statuses.withLock { $0.append(status) }
            }
        }
        threads.forEach { $0.start() }
        let deadline = Date().addingTimeInterval(10)
        while statuses.withLock({ $0.count }) < 4, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(statuses.withLock { $0 } == [403, 403, 403, 403])
        let snapshot = h.backend.snapshot
        #expect(snapshot.created.count == 4)
        #expect(snapshot.cancels.count == 3)
    }

    @Test func aLapsedParkedApprovalIsFiledAgain() throws {
        let clock = Mutex(Date())
        let h = try harness(now: { clock.withLock { $0 } })
        defer { h.tearDown() }
        _ = try send(h)
        _ = try send(h)
        #expect(requested(h).count == 1)
        clock.withLock { $0 = $0.addingTimeInterval(16 * 60) }
        _ = try send(h, path: "/repos/o/other")
        _ = try send(h)
        #expect(requested(h).count == 3)
    }

    @Test func revokingTheLeaseCancelsItsParkedApprovals() throws {
        let h = try harness()
        defer { h.tearDown() }
        _ = try send(h)
        let approval = try #require(h.backend.snapshot.created.first)
        h.broker.revoke(h.lease)
        #expect(h.backend.snapshot.cancels == [approval.approvalID])
    }

    @Test func theDecoderRoundTripsApproveRulesAndRefusesAnEmptyList() throws {
        let decoded = try SecretsConfiguration.decode(Data(Self.json.utf8)).get()
        guard case .gateway(let binding) = decoded.secret(named: "GH")?.delivery else {
            Issue.record("gateway delivery did not decode")
            return
        }
        #expect(binding.approve.count == 1)
        #expect(try SecretsConfiguration.decode(decoded.encoded()).get() == decoded)
        let empty = Self.json.replacingOccurrences(
            of: #""approve":[{"methods":["POST","DELETE"],"path":"/repos/**"}]"#, with: #""approve":[]"#)
        guard case .failure = SecretsConfiguration.decode(Data(empty.utf8)) else {
            Issue.record("an empty approve list was accepted")
            return
        }
        let aws = """
            {"version":1,"secrets":[{"name":"AWS_DEV","source":{"awsProfile":{"profile":"dev"}},
             "delivery":{"awsSigV4":{"upstream":"https://s3.us-east-1.amazonaws.com","region":"us-east-1",
               "service":"s3","endpointEnv":"AWS_ENDPOINT_URL_S3","approve":[{"methods":["DELETE"],"path":"/**"}]}}}]}
            """
        let awsDecoded = try SecretsConfiguration.decode(Data(aws.utf8)).get()
        #expect(try SecretsConfiguration.decode(awsDecoded.encoded()).get() == awsDecoded)
    }
}
