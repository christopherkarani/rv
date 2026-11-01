import Dispatch
import Foundation
import Synchronization
import Testing
@testable import RVIsolation

/// A clock tests move by hand.
final class TestClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = Mutex(start)
    }

    var now: Date { current.withLock { $0 } }

    func advance(_ seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// Provider stand-in for refreshes: hands out queued results, counts calls,
/// and can hold a call until released.
final class FakeRefresher: Sendable {
    private let state = Mutex<(results: [Result<String, SecretResolutionError>], calls: Int)>(([], 0))
    private let gate: DispatchSemaphore?

    init(_ results: [Result<String, SecretResolutionError>], held: Bool = false) {
        state.withLock { $0.results = results }
        gate = held ? DispatchSemaphore(value: 0) : nil
    }

    var calls: Int { state.withLock { $0.calls } }

    func release() { gate?.signal() }

    func resolve(expires: Date? = nil) -> Result<SecretRefreshed, SecretResolutionError> {
        let next = state.withLock { state -> Result<String, SecretResolutionError> in
            state.calls += 1
            return state.results.count > 1 ? state.results.removeFirst() : state.results[0]
        }
        gate?.wait()
        return next.map { SecretRefreshed(value: SecretValue($0)!, fingerprint: "fp-\($0.suffix(4))", expires: expires) }
    }
}

/// Polls `condition` for up to two seconds.
func eventually(_ condition: () -> Bool) -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        usleep(10_000)
    }
    return condition()
}

@Suite("SecretGatewayRotation")
struct SecretGatewayRotationTests {
    static let old = "sk-live-OLD-0123456789"
    static let new = "sk-live-NEW-9876543210"

    private func harness(
        upstream: RecordingUpstream, clock: TestClock, audit: AuditRecords, expires: Date? = nil,
        refresh: SecretRefreshPolicy? = nil
    ) throws -> (SecretGateway, Int, SecretPlaceholder) {
        let gateway = SecretGateway(transport: upstream.transport, peers: .fixed(.member), audit: audit.record, now: { clock.now })
        let port = try gateway.start().get()
        let placeholder = SecretPlaceholder.mint(prefix: "sk-")
        gateway.register(placeholder, entry: SecretGateway.Entry(
            secret: "OPENAI_API_KEY", prefix: "sk-", value: try #require(SecretValue(Self.old)),
            upstream: try #require(URL(string: "https://api.example.com/v1")), fingerprint: "fp-old", runtime: "R1",
            processGroup: testProcessGroup, expires: expires, refresh: refresh))
        return (gateway, port, placeholder)
    }

    private func call(_ port: Int, _ placeholder: SecretPlaceholder) throws -> GatewayExchange {
        try gatewayExchange(port: port,
            "GET /s/OPENAI_API_KEY/models HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(placeholder.text)\r\n\r\n")
    }

    private func sentValues(_ upstream: RecordingUpstream) -> [String?] {
        upstream.requests.map { $0.headers["authorization"]?.replacingOccurrences(of: "Bearer ", with: "") }
    }

    private func refusals(_ audit: AuditRecords) -> [String] {
        audit.items.withLock { $0.compactMap(\.refusal) }
    }

    private func activities(_ audit: AuditRecords, _ activity: SecretGatewayActivity) -> [SecretUseRecord] {
        audit.items.withLock { $0.filter { $0.activity == activity } }
    }

    @Test func refusesAnEntryOnceItExpires() throws {
        let upstream = RecordingUpstream()
        let audit = AuditRecords()
        let clock = TestClock()
        let (gateway, port, placeholder) = try harness(
            upstream: upstream, clock: clock, audit: audit, expires: clock.now.addingTimeInterval(60))
        defer { gateway.stop() }

        #expect(try call(port, placeholder).status == 200)
        clock.advance(60)
        let expired = try call(port, placeholder)
        #expect(expired.status == 403)
        #expect(expired.body.contains("expired"))
        #expect(upstream.requests.count == 1)
        let record = try #require(audit.items.withLock { $0.last })
        #expect(record.refusal == "expired")
        #expect(record.activity == .refused)
        #expect(record.secret == "OPENAI_API_KEY")
    }

    @Test func refreshPastTheGraceWindowSwapsTheValueAndStillScrubsTheOldOne() throws {
        let upstream = RecordingUpstream(chunks: [Data("old=\(Self.old) new=\(Self.new)".utf8)])
        let audit = AuditRecords()
        let clock = TestClock()
        let refresher = FakeRefresher([.success(Self.new)])
        let (gateway, port, placeholder) = try harness(
            upstream: upstream, clock: clock, audit: audit,
            refresh: SecretRefreshPolicy(interval: 60) { refresher.resolve() })
        defer { gateway.stop() }

        #expect(try call(port, placeholder).status == 200)
        clock.advance(121)
        let response = try call(port, placeholder)
        #expect(response.status == 200)
        #expect(sentValues(upstream) == [Self.old, Self.new])
        #expect(response.body == "old=\(placeholder.text) new=\(placeholder.text)")
        #expect(refresher.calls == 1)
        let rotated = try #require(activities(audit, .refreshed).first)
        #expect(rotated.fingerprint == "fp-3210")
        #expect(audit.items.withLock { $0.last?.fingerprint } == "fp-3210")
    }

    @Test func refreshInsideTheGraceWindowServesTheCurrentValueAndSwapsInTheBackground() throws {
        let upstream = RecordingUpstream()
        let audit = AuditRecords()
        let clock = TestClock()
        let refresher = FakeRefresher([.success(Self.new)])
        let (gateway, port, placeholder) = try harness(
            upstream: upstream, clock: clock, audit: audit,
            refresh: SecretRefreshPolicy(interval: 60) { refresher.resolve() })
        defer { gateway.stop() }

        clock.advance(30)
        #expect(try call(port, placeholder).status == 200)
        #expect(refresher.calls == 0)
        clock.advance(40)
        #expect(try call(port, placeholder).status == 200)
        #expect(sentValues(upstream) == [Self.old, Self.old])
        #expect(eventually { activities(audit, .refreshed).count == 1 })
        #expect(try call(port, placeholder).status == 200)
        #expect(sentValues(upstream).last == Self.new)
        #expect(refresher.calls == 1)
    }

    @Test func aFailedRefreshServesThePreviousValueThroughTheGraceWindowThenRefuses() throws {
        let upstream = RecordingUpstream()
        let audit = AuditRecords()
        let clock = TestClock()
        let refresher = FakeRefresher([.failure(.providerUnavailable("vault is down"))])
        let (gateway, port, placeholder) = try harness(
            upstream: upstream, clock: clock, audit: audit,
            refresh: SecretRefreshPolicy(interval: 60) { refresher.resolve() })
        defer { gateway.stop() }

        clock.advance(61)
        #expect(try call(port, placeholder).status == 200)
        #expect(eventually { activities(audit, .refreshFailed).count == 1 })
        let failure = try #require(activities(audit, .refreshFailed).first)
        #expect(failure.reason?.contains("vault is down") == true)
        #expect(failure.secret == "OPENAI_API_KEY")
        // A retry waits a quarter interval after a failure.
        clock.advance(5)
        #expect(try call(port, placeholder).status == 200)
        #expect(refresher.calls == 1)

        clock.advance(55)
        let refused = try call(port, placeholder)
        #expect(refused.status == 503)
        #expect(refused.body.contains("could not be refreshed"))
        #expect(refresher.calls == 2)
        #expect(sentValues(upstream) == [Self.old, Self.old])
        #expect(refusals(audit).last == "refreshFailed")
        // Inside the retry spacing, refusals do not call the provider again.
        clock.advance(1)
        #expect(try call(port, placeholder).status == 503)
        #expect(refresher.calls == 2)
    }

    @Test func simultaneousRequestsShareOneRefresh() throws {
        let upstream = RecordingUpstream()
        let audit = AuditRecords()
        let clock = TestClock()
        let refresher = FakeRefresher([.success(Self.new)], held: true)
        let (gateway, port, placeholder) = try harness(
            upstream: upstream, clock: clock, audit: audit,
            refresh: SecretRefreshPolicy(interval: 60) { refresher.resolve() })
        defer { gateway.stop() }

        clock.advance(121)
        let statuses = Mutex<[Int]>([])
        let group = DispatchGroup()
        for _ in 0..<2 {
            DispatchQueue.global().async(group: group) {
                let status = (try? call(port, placeholder))?.status ?? -1
                statuses.withLock { $0.append(status) }
            }
        }
        #expect(eventually { refresher.calls == 1 })
        usleep(100_000)
        refresher.release()
        #expect(group.wait(timeout: .now() + 10) == .success)
        #expect(statuses.withLock { $0 } == [200, 200])
        #expect(refresher.calls == 1)
        #expect(sentValues(upstream) == [Self.new, Self.new])
    }

    @Test func concurrentDueChecksStartOneBackgroundRefresh() throws {
        let clock = TestClock()
        let refresher = FakeRefresher([.success(Self.new)], held: true)
        let (gateway, _, placeholder) = try harness(
            upstream: RecordingUpstream(), clock: clock, audit: AuditRecords(),
            refresh: SecretRefreshPolicy(interval: 60) { refresher.resolve() })
        defer { gateway.stop() }

        clock.advance(90)
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            #expect(gateway.prepare(placeholder.token) == nil)
        }
        #expect(eventually { refresher.calls == 1 })
        refresher.release()
        usleep(100_000)
        #expect(refresher.calls == 1)
    }

    @Test func aChangedSourceMarkerRotatesOnTheNextRequest() throws {
        let upstream = RecordingUpstream()
        let audit = AuditRecords()
        let clock = TestClock()
        let marker = Mutex<String?>("m1")
        let refresher = FakeRefresher([.success(Self.new), .failure(.notFound("keychain item"))])
        let (gateway, port, placeholder) = try harness(
            upstream: upstream, clock: clock, audit: audit,
            refresh: SecretRefreshPolicy(interval: nil, marker: "m1", probe: { marker.withLock { $0 } }) {
                refresher.resolve()
            })
        defer { gateway.stop() }

        #expect(try call(port, placeholder).status == 200)
        #expect(refresher.calls == 0)
        marker.withLock { $0 = "m2" }
        // Probes are spaced, so a change lands within a couple of seconds.
        clock.advance(1)
        #expect(try call(port, placeholder).status == 200)
        clock.advance(2)
        #expect(try call(port, placeholder).status == 200)
        #expect(sentValues(upstream) == [Self.old, Self.old, Self.new])
        #expect(refresher.calls == 1)

        // A rotation that cannot be read keeps the current value; it is audited once.
        marker.withLock { $0 = nil }
        clock.advance(3)
        #expect(try call(port, placeholder).status == 200)
        clock.advance(3)
        #expect(try call(port, placeholder).status == 200)
        #expect(sentValues(upstream).suffix(2) == [Self.new, Self.new])
        #expect(refresher.calls == 2)
        #expect(activities(audit, .refreshFailed).count == 1)
    }

    @Test func historyKeepsTheLastEightValuesForScrubbing() throws {
        let values = (0..<10).map { "sk-live-GEN\($0)-0123456789" }
        let upstream = RecordingUpstream(chunks: [Data(values.joined(separator: " ").utf8)])
        let clock = TestClock()
        let refresher = FakeRefresher(values.map { .success($0) })
        let (gateway, port, placeholder) = try harness(
            upstream: upstream, clock: clock, audit: AuditRecords(),
            refresh: SecretRefreshPolicy(interval: 60) { refresher.resolve() })
        defer { gateway.stop() }

        var body = ""
        for _ in values {
            clock.advance(121)
            body = try call(port, placeholder).body
        }
        // Current GEN9 plus GEN1...GEN8; GEN0 and the launch value have aged out.
        let words = body.split(separator: " ").map(String.init)
        #expect(words.first == values[0])
        #expect(words.dropFirst().allSatisfy { $0 == placeholder.text })
    }

    @Test func refreshCarriesTheExpiryOnFile() throws {
        let upstream = RecordingUpstream()
        let audit = AuditRecords()
        let clock = TestClock()
        let refresher = FakeRefresher([.success(Self.new)])
        let soon = clock.now.addingTimeInterval(200)
        let (gateway, port, placeholder) = try harness(
            upstream: upstream, clock: clock, audit: audit,
            refresh: SecretRefreshPolicy(interval: 60) { refresher.resolve(expires: soon) })
        defer { gateway.stop() }

        clock.advance(121)
        #expect(try call(port, placeholder).status == 200)
        clock.advance(80)
        #expect(try call(port, placeholder).status == 403)
        #expect(refusals(audit).last == "expired")
    }
}

/// A Keychain stand-in whose items carry a modification marker, as the live
/// resolver reads one without the value.
final class RotatingKeychain: Sendable {
    private let items = Mutex<[String: (value: String, revision: Int)]>([:])

    func store(_ account: String, _ value: String) {
        items.withLock { $0[account] = (value, ($0[account]?.revision ?? 0) + 1) }
    }

    var resolver: SecretResolver {
        SecretResolver { source in
            guard case .keychain(_, let account) = source,
                let value = self.items.withLock({ $0[account]?.value })
            else { return .failure(.notFound("keychain item")) }
            return .success(SecretValue(value)!)
        } version: { source in
            guard case .keychain(_, let account) = source else { return nil }
            return self.items.withLock { $0[account].map { "r\($0.revision)" } }
        }
    }
}

@Suite("SecretLaunchBrokerRotation")
struct SecretLaunchBrokerRotationTests {
    static func keychainJSON(expires: String? = nil, upstream: String = "https://api.example.com/v1") -> String {
        let field = expires.map { #","expires":"\#($0)""# } ?? ""
        return """
            {"version":1,"secrets":[
              {"name":"OPENAI_API_KEY","source":{"keychain":{"service":"rv.secrets","account":"OPENAI_API_KEY"}},
               "delivery":{"gateway":{"upstream":"\(upstream)","baseURLEnv":"OPENAI_BASE_URL",
                                      "placeholderPrefix":"sk-"}}\(field)},
              {"name":"GH_TOKEN","source":{"keychain":{"service":"rv.secrets","account":"GH_TOKEN"}},
               "delivery":{"environment":{}}\(field)}
            ]}
            """
    }

    private func rewrite(_ fixture: SecretsFixture, _ json: String) throws {
        try Data(json.utf8).write(to: SecretsConfiguration.fileURL(configDirectory: fixture.directory))
    }

    private func call(_ port: Int, _ placeholder: String) throws -> GatewayExchange {
        try gatewayExchange(port: port,
            "GET /s/OPENAI_API_KEY/models HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(placeholder)\r\n\r\n")
    }

    @Test func anExpiredSecretFailsTheLaunchWithoutStagingAnything() throws {
        let fixture = try SecretsFixture(Self.keychainJSON(expires: "2027-01-15"))
        defer { fixture.tearDown() }
        let keychain = RotatingKeychain()
        keychain.store("OPENAI_API_KEY", "sk-live-OLD-0123456789")
        keychain.store("GH_TOKEN", "ghp_realtoken")
        let clock = TestClock(SecretExpiry.parse("2027-01-15")!)
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory, resolver: keychain.resolver,
            transport: RecordingUpstream().transport, workspace: nil, now: { clock.now })
        defer { broker.stop() }

        let expiry = SecretExpiry.parse("2027-01-15")!
        #expect(throws: SecretLeaseError.expired(secret: "GH_TOKEN", at: expiry)) {
            try broker.lease(names: ["GH_TOKEN"], agent: nil).get()
        }
        let failure = broker.lease(names: ["OPENAI_API_KEY", "GH_TOKEN"], agent: nil)
        guard case .failure(let error) = failure else {
            Issue.record("an expired secret must fail the launch")
            return
        }
        #expect(error == .expired(secret: "OPENAI_API_KEY", at: expiry))
        #expect(error.message.contains("expired at 2027-01-15"))
        #expect(error.message.contains("rv secrets set OPENAI_API_KEY --expires"))
        #expect(broker.liveCount == 0)
        #expect(broker.gatewayPort == nil)
        #expect(fixture.auditText.contains("staged") == false)

        clock.advance(-1)
        #expect((try? broker.lease(names: ["OPENAI_API_KEY", "GH_TOKEN"], agent: nil).get()) != nil)
    }

    @Test func aKeychainWriteReachesARunningSessionAndTheExpiryOnFileFollows() throws {
        let fixture = try SecretsFixture(Self.keychainJSON())
        defer { fixture.tearDown() }
        let keychain = RotatingKeychain()
        keychain.store("OPENAI_API_KEY", "sk-live-OLD-0123456789")
        let clock = TestClock()
        let upstream = RecordingUpstream(chunks: [Data("echo sk-live-OLD-0123456789".utf8)])
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory, resolver: keychain.resolver,
            transport: upstream.transport, peers: .fixed(.member), workspace: "W1", now: { clock.now })
        defer { broker.stop() }
        let lease = try broker.lease(names: ["OPENAI_API_KEY"], agent: nil).get()
        broker.bind(lease, processGroup: testProcessGroup)
        let placeholder = try #require(lease.environment.first { $0.name == "OPENAI_API_KEY" }?.value)
        let port = try #require(broker.gatewayPort)

        #expect(try call(port, placeholder).status == 200)
        // `rv secrets set OPENAI_API_KEY --expires ...` writes both.
        keychain.store("OPENAI_API_KEY", "sk-live-NEW-9876543210")
        let expires = SecretExpiry.text(clock.now.addingTimeInterval(3_600))
        try rewrite(fixture, Self.keychainJSON(expires: expires))
        clock.advance(3)
        let rotated = try call(port, placeholder)
        #expect(rotated.status == 200)
        #expect(rotated.body == "echo \(placeholder)")
        #expect(upstream.requests.map { $0.headers["authorization"] } == [
            "Bearer sk-live-OLD-0123456789", "Bearer sk-live-NEW-9876543210",
        ])
        let refresh = fixture.auditLines.filter { ($0["detail"] as? [String: String])?["event"] == "refresh" }
        #expect(refresh.count == 1)
        #expect(refresh.first?["decision"] as? String == "info")
        #expect(fixture.auditText.contains("sk-live-") == false)

        clock.advance(3_600)
        #expect(try call(port, placeholder).status == 403)
    }

    @Test func aChangedDeliveryIsNotPickedUpByARunningSession() throws {
        let fixture = try SecretsFixture(Self.keychainJSON())
        defer { fixture.tearDown() }
        let keychain = RotatingKeychain()
        keychain.store("OPENAI_API_KEY", "sk-live-OLD-0123456789")
        let clock = TestClock()
        let upstream = RecordingUpstream()
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory, resolver: keychain.resolver,
            transport: upstream.transport, peers: .fixed(.member), workspace: nil, now: { clock.now })
        defer { broker.stop() }
        let lease = try broker.lease(names: ["OPENAI_API_KEY"], agent: nil).get()
        broker.bind(lease, processGroup: testProcessGroup)
        let placeholder = try #require(lease.environment.first { $0.name == "OPENAI_API_KEY" }?.value)
        let port = try #require(broker.gatewayPort)

        keychain.store("OPENAI_API_KEY", "sk-live-NEW-9876543210")
        try rewrite(fixture, Self.keychainJSON(upstream: "https://evil.example.com"))
        clock.advance(3)
        #expect(try call(port, placeholder).status == 200)
        #expect(upstream.requests.first?.headers["authorization"] == "Bearer sk-live-OLD-0123456789")
        let failed = fixture.auditLines.filter { ($0["detail"] as? [String: String])?["activity"] == "refreshFailed" }
        #expect(failed.count == 1)
        #expect((failed.first?["reason"] as? String)?.contains("different source or delivery") == true)
    }
}
