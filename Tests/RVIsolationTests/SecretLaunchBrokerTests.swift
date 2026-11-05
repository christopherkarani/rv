#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVPolicy
import Synchronization
import Testing
@testable import RVIsolation

/// Temporary `~/.config/rv` stand-in holding a 0600 secrets.json.
struct SecretsFixture {
    let directory: URL

    init(_ json: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-secrets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = SecretsConfiguration.fileURL(configDirectory: directory)
        try Data(json.utf8).write(to: file)
        chmod(file.path, 0o600)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    var auditLines: [[String: Any]] {
        let url = directory.appendingPathComponent("audit.jsonl")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    var auditText: String {
        (try? String(contentsOf: directory.appendingPathComponent("audit.jsonl"), encoding: .utf8)) ?? ""
    }

    static let standard = """
        {"version":1,"secrets":[
          {"name":"OPENAI_API_KEY","agents":["codex"],
           "source":{"hostEnvironment":{"variable":"FAKE_OPENAI"}},
           "delivery":{"gateway":{"upstream":"https://api.example.com/v1","baseURLEnv":"OPENAI_BASE_URL",
                                  "placeholderPrefix":"sk-"}}},
          {"name":"GH_TOKEN","source":{"hostEnvironment":{"variable":"FAKE_GH"}},"delivery":{"environment":{}}}
        ]}
        """
}

let fakeResolver = SecretResolver { source in
    guard case .hostEnvironment(let variable) = source else { return .failure(.providerUnavailable("fake")) }
    switch variable {
    case "FAKE_OPENAI": return .success(SecretValue("sk-live-REAL-0123456789")!)
    case "FAKE_GH": return .success(SecretValue("ghp_realtoken")!)
    default: return .failure(.notFound("host variable \(variable) is not set"))
    }
}

@Suite("SecretLaunchBroker")
struct SecretLaunchBrokerTests {
    @Test func fingerprintIsRFC4231HMACSHA256() {
        func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
        #expect(hex(SecretFingerprinter.hmacSHA256(key: Array("Jefe".utf8), message: Array("what do ya want for nothing?".utf8)))
            == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        let longKey = [UInt8](repeating: 0xaa, count: 131)
        #expect(hex(SecretFingerprinter.hmacSHA256(
            key: longKey, message: Array("Test Using Larger Than Block-Size Key - Hash Key First".utf8)))
            == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
        let fingerprinter = SecretFingerprinter(key: Array("Jefe".utf8))
        #expect(fingerprinter.fingerprint(SecretValue("what do ya want for nothing?")!) == "5bdcc146bf60754e")
    }

    @Test func gatewaySecretsStageOnlyAPlaceholderAndBaseURL() throws {
        let fixture = try SecretsFixture(SecretsFixture.standard)
        defer { fixture.tearDown() }
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory, resolver: fakeResolver,
            transport: RecordingUpstream().transport, workspace: "W1")
        defer { broker.stop() }

        let lease = try broker.lease(names: ["OPENAI_API_KEY", "GH_TOKEN"], agent: "codex").get()
        let environment = Dictionary(uniqueKeysWithValues: lease.environment.map { ($0.name, $0.value) })
        let port = try #require(broker.gatewayPort)
        #expect(environment["OPENAI_API_KEY"]?.hasPrefix("sk-rvph_") == true)
        #expect(environment["OPENAI_API_KEY"]?.contains("REAL") == false)
        #expect(environment["OPENAI_BASE_URL"] == "http://127.0.0.1:\(port)/s/OPENAI_API_KEY")
        #expect(environment["GH_TOKEN"] == "ghp_realtoken")
        #expect(lease.placeholders.count == 1)

        let staged = fixture.auditLines.filter { $0["kind"] as? String == "secret.use" }
        #expect(staged.count == 2)
        #expect(staged.allSatisfy { ($0["detail"] as? [String: String])?["fingerprint"]?.count == 16 })
        #expect(fixture.auditText.contains("sk-live-REAL") == false)
        #expect(fixture.auditText.contains("ghp_realtoken") == false)
        var info = stat()
        #expect(stat(fixture.directory.appendingPathComponent("audit.key").path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
    }

    @Test func gatewayBindingSurfacesReachTheGatewayEntry() throws {
        let fixture = try SecretsFixture("""
            {"version":1,"secrets":[
              {"name":"MAPS_KEY","source":{"hostEnvironment":{"variable":"FAKE_OPENAI"}},
               "delivery":{"gateway":{"upstream":"https://api.example.com/v1","baseURLEnv":"MAPS_BASE_URL",
                                      "placeholderPrefix":"sk-","surfaces":["query"]}}}
            ]}
            """)
        defer { fixture.tearDown() }
        let upstream = RecordingUpstream(status: 200)
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory, resolver: fakeResolver,
            transport: upstream.transport, peers: .fixed(.member), workspace: nil)
        defer { broker.stop() }
        let lease = try broker.lease(names: ["MAPS_KEY"], agent: nil).get()
        broker.bind(lease, runtime: "R1")
        broker.bind(lease, processGroup: testProcessGroup)
        let placeholder = try #require(lease.placeholders.first).text
        let port = try #require(broker.gatewayPort)

        let query = try gatewayExchange(port: port,
            "GET /s/MAPS_KEY/x?key=\(placeholder) HTTP/1.1\r\n\r\n")
        #expect(query.status == 200)
        let seen = try #require(upstream.requests.first)
        #expect(seen.url == "https://api.example.com/v1/x?key=sk-live-REAL-0123456789")

        let header = try gatewayExchange(port: port,
            "GET /s/MAPS_KEY/x HTTP/1.1\r\nAuthorization: Bearer \(placeholder)\r\n\r\n")
        #expect(header.status == 403)
        #expect(upstream.requests.count == 1)
    }

    @Test func agentFilterSkipsSecretsForOtherAgents() throws {
        let fixture = try SecretsFixture(SecretsFixture.standard)
        defer { fixture.tearDown() }
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory, resolver: fakeResolver, workspace: nil)
        defer { broker.stop() }
        let lease = try broker.lease(names: ["OPENAI_API_KEY", "GH_TOKEN"], agent: "claude").get()
        #expect(lease.environment.map(\.name) == ["GH_TOKEN"])
        #expect(broker.gatewayPort == nil)
    }

    @Test func unknownOrUnresolvableSecretsFailWithoutStaging() throws {
        let fixture = try SecretsFixture("""
            {"version":1,"secrets":[
              {"name":"OPENAI_API_KEY","source":{"hostEnvironment":{"variable":"FAKE_OPENAI"}},
               "delivery":{"gateway":{"upstream":"https://api.example.com","baseURLEnv":"OPENAI_BASE_URL"}}},
              {"name":"MISSING","source":{"hostEnvironment":{"variable":"NOPE"}},"delivery":{"environment":{}}}
            ]}
            """)
        defer { fixture.tearDown() }
        let broker = SecretLaunchBroker(configDirectory: fixture.directory, resolver: fakeResolver, workspace: nil)
        defer { broker.stop() }
        guard case .failure(.unknownSecret("NOT_DEFINED")) = broker.lease(names: ["NOT_DEFINED"], agent: nil) else {
            Issue.record("undefined secret must fail")
            return
        }
        guard case .failure(.resolution(secret: "MISSING", _)) = broker.lease(
            names: ["OPENAI_API_KEY", "MISSING"], agent: nil)
        else {
            Issue.record("unresolvable secret must fail")
            return
        }
        #expect(broker.liveCount == 0)
    }

    @Test func revokingTheRuntimeKillsItsPlaceholders() throws {
        let fixture = try SecretsFixture(SecretsFixture.standard)
        defer { fixture.tearDown() }
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory, resolver: fakeResolver,
            transport: RecordingUpstream().transport, workspace: nil)
        defer { broker.stop() }
        let first = try broker.lease(names: ["OPENAI_API_KEY"], agent: "codex").get()
        let second = try broker.lease(names: ["OPENAI_API_KEY"], agent: "codex").get()
        #expect(first.environment.first?.value != second.environment.first?.value)
        broker.bind(first, runtime: "R1")
        broker.bind(second, runtime: "R2")
        #expect(broker.liveCount == 2)
        broker.revoke(runtime: "R1")
        #expect(broker.liveCount == 1)
        broker.revoke(runtime: "R2")
        #expect(broker.liveCount == 0)
    }

    @Test func unsafeConfigurationFailsClosed() throws {
        let fixture = try SecretsFixture(SecretsFixture.standard)
        defer { fixture.tearDown() }
        chmod(SecretsConfiguration.fileURL(configDirectory: fixture.directory).path, 0o666)
        let broker = SecretLaunchBroker(configDirectory: fixture.directory, resolver: fakeResolver, workspace: nil)
        #expect(throws: SecretLeaseError.configuration(.unsafeFile("group or world writable"))) {
            try broker.lease(names: ["GH_TOKEN"], agent: nil).get()
        }
    }

    @Test func organizationPolicyRefusesForbiddenSourcesDeliveryAndInvalidBundles() throws {
        let fixture = try SecretsFixture(SecretsFixture.standard)
        defer { fixture.tearDown() }
        func broker(_ state: ManagedPolicyState) -> SecretLaunchBroker {
            SecretLaunchBroker(
                configDirectory: fixture.directory, resolver: fakeResolver,
                transport: RecordingUpstream().transport, workspace: nil, managed: { state })
        }
        var policy = ManagedPolicy()
        policy.secrets.allowEnvironmentDelivery = false
        let gatewayOnly = broker(.active(ManagedPolicyBundle(policy: policy, sha256: "", isSigned: false, directory: "")))
        defer { gatewayOnly.stop() }
        #expect(throws: SecretLeaseError.organizationPolicy(
            "GH_TOKEN is delivered as an environment variable, which is not allowed; use the gateway")) {
            try gatewayOnly.lease(names: ["OPENAI_API_KEY", "GH_TOKEN"], agent: "codex").get()
        }
        #expect(gatewayOnly.liveCount == 0)

        policy = ManagedPolicy()
        policy.secrets.allowedSources = [.keychain]
        let keychainOnly = broker(.active(ManagedPolicyBundle(policy: policy, sha256: "", isSigned: false, directory: "")))
        #expect(throws: SecretLeaseError.organizationPolicy(
            "OPENAI_API_KEY uses a hostEnvironment source, which is not allowed")) {
            try keychainOnly.lease(names: ["OPENAI_API_KEY"], agent: "codex").get()
        }

        let invalid = broker(.invalid("bad signature"))
        #expect(throws: SecretLeaseError.organizationPolicy("invalid, so secrets are not staged: bad signature")) {
            try invalid.lease(names: ["GH_TOKEN"], agent: nil).get()
        }
        #expect(fixture.auditText.contains("staged") == false)
    }
}
extension SecretLaunchBrokerTests {
    private func leasedPlaceholder(_ broker: SecretLaunchBroker) throws -> (port: Int, text: String, token: String) {
        let lease = try broker.lease(names: ["OPENAI_API_KEY"], agent: "codex").get()
        broker.bind(lease, runtime: "R1")
        broker.bind(lease, processGroup: testProcessGroup)
        let text = try #require(lease.environment.first { $0.name == "OPENAI_API_KEY" }?.value)
        return (try #require(broker.gatewayPort), text, String(text.suffix(SecretPlaceholder.tokenLength)))
    }

    @Test func policyRefusalsAddAHighSeverityMisuseEventWithoutPlaceholderOrQuery() throws {
        let fixture = try SecretsFixture(SecretsFixture.standard)
        defer { fixture.tearDown() }
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory, resolver: fakeResolver,
            transport: RecordingUpstream().transport, peers: .fixed(.member), workspace: "W1")
        defer { broker.stop() }
        let placeholder = try leasedPlaceholder(broker)
        // The binding allows only the header surface.
        let offSurface = try gatewayExchange(port: placeholder.port,
            "GET /s/OPENAI_API_KEY/models?key=\(placeholder.text)&q=privatequery HTTP/1.1\r\n\r\n")
        #expect(offSurface.status == 403)
        let encoded = try gatewayExchange(port: placeholder.port,
            "GET /s/OPENAI_API_KEY/rvph%5F\(placeholder.token)/x HTTP/1.1\r\n\r\n")
        #expect(encoded.status == 400)
        // Not a policy violation: no misuse event.
        let bare = try gatewayExchange(port: placeholder.port, "GET /s/OPENAI_API_KEY/models HTTP/1.1\r\n\r\n")
        #expect(bare.status == 401)

        let misuse = fixture.auditLines.filter { $0["kind"] as? String == "secret.misuse" }
        #expect(misuse.count == 2)
        #expect(misuse.allSatisfy { $0["decision"] as? String == "denied" && $0["subject"] as? String == "OPENAI_API_KEY" })
        let refusals = misuse.compactMap { ($0["detail"] as? [String: String])?["refusal"] }
        #expect(refusals == ["surfaceNotAllowed", "encodedPlaceholder"])
        #expect(misuse.allSatisfy { ($0["detail"] as? [String: String])?["severity"] == "high" })
        // The encoded placeholder is never looked up, so only the first names a runtime.
        #expect(misuse.map { $0["runtime"] as? String } == ["R1", nil])
        let denied = fixture.auditLines.filter {
            $0["kind"] as? String == "secret.use" && ($0["detail"] as? [String: String])?["event"] == "request"
        }
        #expect(denied.compactMap { ($0["detail"] as? [String: String])?["activity"] } == ["blocked", "blocked", "refused"])
        #expect(fixture.auditText.contains(placeholder.token) == false)
        #expect(fixture.auditText.contains("privatequery") == false)
        #expect(fixture.auditText.contains("sk-live-REAL") == false)
    }

    @Test func misuseFindingsAreNotForgedForSecretsTheBrokerDoesNotHold() throws {
        let fixture = try SecretsFixture(SecretsFixture.standard)
        defer { fixture.tearDown() }
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory, resolver: fakeResolver,
            transport: RecordingUpstream().transport, workspace: "W1")
        defer { broker.stop() }
        let placeholder = try leasedPlaceholder(broker)
        let trace = try gatewayExchange(port: placeholder.port, "TRACE /s/PROD_DB_PASSWORD/x HTTP/1.1\r\n\r\n")
        #expect(trace.status == 405)
        let encoded = try gatewayExchange(port: placeholder.port,
            "GET /s/AWS_SECRET/rvph%5F\(placeholder.token) HTTP/1.1\r\n\r\n")
        #expect(encoded.status == 400)
        #expect(fixture.auditLines.filter { $0["kind"] as? String == "secret.misuse" }.isEmpty)
    }

    @Test func brokeredRequestsAreNotForwardedWhenTheAuditLogCannotBeWritten() throws {
        let fixture = try SecretsFixture(SecretsFixture.standard)
        defer { fixture.tearDown() }
        let upstream = RecordingUpstream(status: 200, chunks: [Data("ok".utf8)])
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory, resolver: fakeResolver, transport: upstream.transport,
            peers: .fixed(.member), workspace: nil)
        defer { broker.stop() }
        let placeholder = try leasedPlaceholder(broker)
        let ledger = fixture.directory.appendingPathComponent("audit.jsonl")
        try FileManager.default.removeItem(at: ledger)
        try FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: false)
        let response = try gatewayExchange(port: placeholder.port,
            "GET /s/OPENAI_API_KEY/models HTTP/1.1\r\nAuthorization: Bearer \(placeholder.text)\r\n\r\n")
        #expect(response.status == 503)
        #expect(response.body.contains("audit log"))
        #expect(upstream.requests.isEmpty)
    }

    @Test func aPlaceholderSpentFromOutsideItsRuntimeIsAMisuseFindingForThatRuntime() throws {
        let fixture = try SecretsFixture(SecretsFixture.standard)
        defer { fixture.tearDown() }
        let upstream = RecordingUpstream(status: 200)
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory, resolver: fakeResolver, transport: upstream.transport,
            peers: .fixed(.outsider), workspace: "W1")
        defer { broker.stop() }
        let placeholder = try leasedPlaceholder(broker)
        let response = try gatewayExchange(port: placeholder.port,
            "GET /s/OPENAI_API_KEY/models HTTP/1.1\r\nAuthorization: Bearer \(placeholder.text)\r\n\r\n")
        #expect(response.status == 403)
        #expect(upstream.requests.isEmpty)
        let misuse = try #require(fixture.auditLines.first { $0["kind"] as? String == "secret.misuse" })
        #expect(misuse["runtime"] as? String == "R1")
        #expect((misuse["detail"] as? [String: String])?["refusal"] == "runtimeMismatch")
        #expect(fixture.auditText.contains(placeholder.token) == false)
    }

    @Test func activityEventsCarrySurfacesStatusAndDuration() {
        let record = SecretUseRecord(
            secret: "OPENAI_API_KEY", runtime: "R1", upstreamHost: "api.example.com", method: "POST",
            path: "/s/OPENAI_API_KEY/chat", status: 502, upstreamStatus: 401, activity: .brokered, refusal: nil,
            reason: "upstream returned 401 for the brokered credential", surfaces: ["header", "query"],
            fingerprint: "abcd", responseBytes: 0, durationMilliseconds: 12, stage: .complete)
        let event = SecretLaunchBroker.auditEvent(record, workspace: "W1")
        #expect(event.kind == .secretUse)
        #expect(event.decision == .allowed)
        #expect(event.detail["event"] == "request")
        #expect(event.detail["activity"] == "brokered")
        #expect(event.detail["surfaces"] == "header,query")
        #expect(event.detail["upstreamStatus"] == "401")
        #expect(event.detail["status"] == "502")
        #expect(event.detail["durationMs"] == "12")
        #expect(SecretLaunchBroker.misuseEvent(record, workspace: "W1") == nil)

        var failed = record
        failed.activity = .error
        failed.upstreamStatus = nil
        #expect(SecretLaunchBroker.auditEvent(failed, workspace: nil).decision == .failed)
        var forward = record
        forward.stage = .forward
        #expect(SecretLaunchBroker.auditEvent(forward, workspace: nil).detail["event"] == "forward")
    }
}
