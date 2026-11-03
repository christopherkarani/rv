#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization
import Testing
@testable import RVIsolation

/// Polls `condition` for up to `seconds`. File-private: other test files keep their own copy.
private func eventually(seconds: Int = 2, _ condition: () -> Bool) -> Bool {
    for _ in 0..<(seconds * 100) {
        if condition() { return true }
        usleep(10_000)
    }
    return condition()
}

/// `awsProfile` + `awsSigV4`: the cage holds a placeholder key id and a
/// throwaway secret; the gateway discards the agent's signature and re-signs
/// with the real keys for the bound upstream only.
@Suite("Secret gateway AWS SigV4")
struct SecretGatewayAWSTests {
    static let realKey = "AKIAREALKEY000000001"
    static let realSecret = "realSecretKey/0000+1111/2222333344445555"
    static let realToken = "real-session-token-0000111122223333"
    static let start = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15T08:00:00Z

    static func credentials(
        key: String = realKey, secret: String = realSecret, token: String? = realToken, expires: Date?
    ) -> String {
        var object: [String: Any] = ["Version": 1, "AccessKeyId": key, "SecretAccessKey": secret]
        if let token { object["SessionToken"] = token }
        if let expires {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            object["Expiration"] = formatter.string(from: expires).replacingOccurrences(of: "Z", with: "+00:00")
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func secretsJSON(
        allow: String = "", name: String = "AWS_DEV", fields: String = "", extra: String = "", service: String = "s3"
    ) -> String {
        let rules = allow.isEmpty ? "" : ",\"allow\":\(allow)"
        return """
            {"version":1,"secrets":[
              {"name":"\(name)"\(fields),"source":{"awsProfile":{"profile":"dev"}},
               "delivery":{"awsSigV4":{"upstream":"https://s3.us-east-1.amazonaws.com","region":"us-east-1",
                                       "service":"\(service)","endpointEnv":"AWS_ENDPOINT_URL_S3"\(rules)}}}\(extra)
            ]}
            """
    }

    /// Hands out queued `export-credentials` results; the last one repeats.
    final class Provider: Sendable {
        private let queue: Mutex<[Result<String, SecretResolutionError>]>
        init(_ results: [Result<String, SecretResolutionError>]) { queue = Mutex(results) }

        var resolver: SecretResolver {
            SecretResolver { source in
                guard source == .awsProfile(profile: "dev") else { return .failure(.providerUnavailable("fake")) }
                let next = self.queue.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
                return next.map { SecretValue($0)! }
            }
        }
    }

    struct Harness {
        let fixture: SecretsFixture
        let broker: SecretLaunchBroker
        let upstream: RecordingUpstream
        let clock: TestClock
        let lease: SecretLease
        let environment: [String: String]
        let port: Int

        var placeholder: String { environment["AWS_ACCESS_KEY_ID"] ?? "" }

        func tearDown() {
            broker.stop()
            fixture.tearDown()
        }
    }

    private func harness(
        _ json: String = secretsJSON(), provider: Provider? = nil, upstream: RecordingUpstream = RecordingUpstream(),
        peers: GatewayPeerCheck = .fixed(.member)
    ) throws -> Harness {
        let fixture = try SecretsFixture(json)
        let clock = TestClock(Self.start)
        let provider = provider ?? Provider([.success(Self.credentials(expires: Self.start.addingTimeInterval(3_600)))])
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory, resolver: provider.resolver, transport: upstream.transport,
            peers: peers, workspace: "W1", now: { clock.now })
        let lease = try broker.lease(names: ["AWS_DEV"], agent: nil).get()
        broker.bind(lease, processGroup: testProcessGroup)
        return Harness(
            fixture: fixture, broker: broker, upstream: upstream, clock: clock, lease: lease,
            environment: Dictionary(lease.environment.map { ($0.name, $0.value) }) { $1 },
            port: try #require(broker.gatewayPort))
    }

    /// A request as an SDK sends it: signed with the placeholder and the
    /// throwaway secret, so its signature is worthless upstream.
    private func sigV4(
        _ harness: Harness, method: String = "GET", target: String = "/s/AWS_DEV/my-bucket/a%20b.txt?list-type=2",
        key: String? = nil, contentSHA256: String = "UNSIGNED-PAYLOAD", extra: [String] = [], body: String = ""
    ) throws -> GatewayExchange {
        let lines = [
            "\(method) \(target) HTTP/1.1",
            "Host: 127.0.0.1:\(harness.port)",
            "Authorization: AWS4-HMAC-SHA256 Credential=\(key ?? harness.placeholder)/20270115/us-east-1/s3/aws4_request, "
                + "SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token, Signature=deadbeef",
            "X-Amz-Date: 19990101T000000Z",
            "X-Amz-Security-Token: agent-supplied-token",
            "X-Amz-Content-Sha256: \(contentSHA256)",
            "Content-Length: \(body.utf8.count)",
        ] + extra
        return try gatewayExchange(port: harness.port, lines.joined(separator: "\r\n") + "\r\n\r\n" + body)
    }

    /// The upstream's view: recompute the signature over what arrived, with the real secret.
    private func verifies(_ seen: RecordingUpstream.Seen, at date: Date, secret: String = realSecret,
                          token: String? = realToken) throws -> Bool {
        let authorization = try #require(seen.headers["authorization"])
        let signedList = try #require(authorization.components(separatedBy: "SignedHeaders=").last?
            .components(separatedBy: ",").first)
        let url = try #require(URLComponents(string: seen.url))
        let host = try #require(url.host)
        var headers: [(name: String, value: String)] = []
        for name in signedList.split(separator: ";").map(String.init) {
            let value = name == "host" ? host : seen.headers[name]
            headers.append((name, try #require(value)))
        }
        let payloadHash = try #require(seen.headers["x-amz-content-sha256"])
        let signed = AWSSigV4.sign(
            AWSSigV4.Request(
                method: seen.method, path: url.percentEncodedPath, query: url.percentEncodedQuery, headers: headers,
                payloadHash: payloadHash),
            credentials: AWSSigV4.Credentials(
                accessKeyID: SecretValue(Self.realKey)!, secretAccessKey: SecretValue(secret)!,
                sessionToken: token.flatMap { SecretValue($0) }),
            scope: AWSSigV4.Scope(region: "us-east-1", service: "s3"), at: date, options: .s3)
        let resigned = try #require(signed)
        return resigned.headers.first { $0.name == "Authorization" }?.value == authorization
    }

    private func refusals(_ fixture: SecretsFixture) -> [String] {
        fixture.auditLines.filter { $0["kind"] as? String == "secret.use" }
            .compactMap { ($0["detail"] as? [String: String])?["refusal"] }
    }

    // MARK: Signing

    @Test func theUpstreamGetsARequestSignedWithTheRealKeysAndTheAgentsTokenIsDropped() throws {
        let h = try harness()
        defer { h.tearDown() }
        let response = try sigV4(h)
        #expect(response.status == 200)
        let seen = try #require(h.upstream.requests.first)
        #expect(seen.url == "https://s3.us-east-1.amazonaws.com/my-bucket/a%20b.txt?list-type=2")
        #expect(seen.headers["x-amz-security-token"] == Self.realToken)
        #expect(seen.headers["x-amz-date"] == "20270115T080000Z")
        #expect(seen.headers["x-amz-content-sha256"] == "UNSIGNED-PAYLOAD")
        #expect(seen.headers["authorization"]?.contains("Credential=\(Self.realKey)/20270115/us-east-1/s3/aws4_request") == true)
        #expect(try verifies(seen, at: Self.start))
        #expect(seen.headers.values.contains { $0.contains("agent-supplied") || $0.contains("rvph_") } == false)
    }

    @Test func aSignedBodyIsHashedByTheGatewayNotTrustedFromTheAgent() throws {
        let h = try harness()
        defer { h.tearDown() }
        let body = "<Delete><Object><Key>a</Key></Object></Delete>"
        let response = try sigV4(
            h, method: "POST", target: "/s/AWS_DEV/my-bucket?delete", contentSHA256: String(repeating: "0", count: 64),
            extra: ["Content-Type: application/xml", "X-Amz-Meta-Origin: agent"], body: body)
        #expect(response.status == 200)
        let seen = try #require(h.upstream.requests.first)
        #expect(seen.headers["x-amz-content-sha256"] == AWSSigV4.payloadHash(Array(body.utf8)))
        #expect(seen.headers["authorization"]?.contains("content-type;host;x-amz-content-sha256;x-amz-date;x-amz-meta-origin;x-amz-security-token") == true)
        #expect(try verifies(seen, at: Self.start))
    }

    @Test func longTermKeysWithoutASessionTokenSignWithoutOne() throws {
        let provider = Provider([.success(Self.credentials(token: nil, expires: nil))])
        let h = try harness(provider: provider)
        defer { h.tearDown() }
        #expect(try sigV4(h).status == 200)
        let seen = try #require(h.upstream.requests.first)
        #expect(seen.headers["x-amz-security-token"] == nil)
        #expect(try verifies(seen, at: Self.start, token: nil))
    }

    // MARK: Refusals

    @Test func aKeyIDOtherThanThePlaceholderIsRefusedAsMisuse() throws {
        let h = try harness()
        defer { h.tearDown() }
        for key in ["AKIAIOSFODNN7EXAMPLE", "x" + h.placeholder, h.placeholder + "x"] {
            let response = try sigV4(h, key: key)
            #expect(response.status == 403)
            #expect(response.body.contains("access key"))
        }
        #expect(h.upstream.requests.isEmpty)
        #expect(refusals(h.fixture) == ["awsKeyMismatch", "awsKeyMismatch", "awsKeyMismatch"])
        #expect(h.fixture.auditLines.contains { $0["kind"] as? String == "secret.misuse" })
        #expect(h.fixture.auditText.contains(h.placeholder) == false)
    }

    @Test func theAWSPlaceholderCannotBeSpentAsABearerToken() throws {
        let h = try harness()
        defer { h.tearDown() }
        let response = try gatewayExchange(port: h.port,
            "GET /s/AWS_DEV/my-bucket HTTP/1.1\r\nAuthorization: Bearer \(h.placeholder)\r\n\r\n")
        #expect(response.status == 403)
        #expect(h.upstream.requests.isEmpty)
        #expect(refusals(h.fixture) == ["surfaceNotAllowed"])
    }

    @Test func aCopyOfThePlaceholderElsewhereInTheRequestIsRefused() throws {
        let h = try harness()
        defer { h.tearDown() }
        let response = try sigV4(h, target: "/s/AWS_DEV/my-bucket?prefix=\(h.placeholder)")
        #expect(response.status == 403)
        #expect(h.upstream.requests.isEmpty)
    }

    @Test(arguments: [
        "STREAMING-AWS4-HMAC-SHA256-PAYLOAD", "STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER",
        "STREAMING-AWS4-HMAC-SHA256-EVENTS", "STREAMING-AWS4-ECDSA-P256-SHA256-PAYLOAD",
    ])
    func signedStreamingPayloadsAreRefused(_ mode: String) throws {
        let h = try harness()
        defer { h.tearDown() }
        let response = try sigV4(h, method: "PUT", target: "/s/AWS_DEV/my-bucket/k", contentSHA256: mode, body: "x")
        #expect(response.status == 400)
        #expect(response.body.contains("UNSIGNED-PAYLOAD"))
        #expect(h.upstream.requests.isEmpty)
        #expect(refusals(h.fixture) == ["awsSignedStreaming"])
        #expect(h.fixture.auditLines.contains { $0["kind"] as? String == "secret.misuse" } == false)
    }

    @Test(arguments: ["UNSIGNED-PAYLOAD", "STREAMING-UNSIGNED-PAYLOAD-TRAILER"])
    func unsignedPayloadModesAreRefusedForServicesOtherThanS3(_ mode: String) throws {
        let h = try harness(Self.secretsJSON(service: "bedrock"))
        defer { h.tearDown() }
        let response = try sigV4(h, method: "POST", target: "/s/AWS_DEV/model/x/invoke", contentSHA256: mode, body: "{}")
        #expect(response.status == 400)
        #expect(response.body.contains("S3"))
        #expect(h.upstream.requests.isEmpty)
        #expect(refusals(h.fixture) == ["awsUnsignedPayload"])
        #expect(h.fixture.auditLines.contains { $0["kind"] as? String == "secret.misuse" } == false)
        // The gateway hashes the body itself when the agent does not ask for an unsigned mode.
        let hashed = try sigV4(
            h, method: "POST", target: "/s/AWS_DEV/model/x/invoke", contentSHA256: String(repeating: "0", count: 64),
            body: "{}")
        #expect(hashed.status == 200)
        #expect(h.upstream.requests.first?.headers["x-amz-content-sha256"] == AWSSigV4.payloadHash(Array("{}".utf8)))
    }

    @Test func unsignedTrailerUploadsPassThroughWithTheirMode() throws {
        let h = try harness()
        defer { h.tearDown() }
        let response = try sigV4(
            h, method: "PUT", target: "/s/AWS_DEV/my-bucket/k", contentSHA256: "STREAMING-UNSIGNED-PAYLOAD-TRAILER",
            extra: ["Content-Encoding: aws-chunked", "X-Amz-Trailer: x-amz-checksum-crc32"], body: "x")
        #expect(response.status == 200)
        let seen = try #require(h.upstream.requests.first)
        #expect(seen.headers["x-amz-content-sha256"] == "STREAMING-UNSIGNED-PAYLOAD-TRAILER")
        #expect(try verifies(seen, at: Self.start))
    }

    @Test func allowRulesBindTheSignedRequestToo() throws {
        let h = try harness(Self.secretsJSON(allow: #"[{"methods":["GET"],"path":"/my-bucket/*"}]"#))
        defer { h.tearDown() }
        #expect(try sigV4(h).status == 200)
        let delete = try sigV4(h, method: "DELETE", target: "/s/AWS_DEV/my-bucket/a%20b.txt")
        #expect(delete.status == 403)
        let other = try sigV4(h, target: "/s/AWS_DEV/other-bucket/k")
        #expect(other.status == 403)
        #expect(h.upstream.requests.count == 1)
        #expect(refusals(h.fixture) == ["outsideAllowRules", "outsideAllowRules"])
    }

    @Test func approveRulesHoldTheSignedRequestUntilAHumanSaysYes() throws {
        let json = Self.secretsJSON().replacingOccurrences(
            of: #""endpointEnv":"AWS_ENDPOINT_URL_S3""#,
            with: #""endpointEnv":"AWS_ENDPOINT_URL_S3","approve":[{"methods":["DELETE"],"path":"/**"}]"#)
        let h = try harness(json)
        defer { h.tearDown() }
        let park = try ParkHarness()
        defer { park.cleanup() }
        h.broker.bind(h.lease, approver: try #require(park.session.secretRequestApprover()))
        park.backend.authorizeAll()
        #expect(try sigV4(h).status == 200)
        #expect(park.backend.snapshot.creates.isEmpty)
        #expect(try sigV4(h, method: "DELETE", target: "/s/AWS_DEV/my-bucket/k").status == 200)
        let asked = try #require(park.backend.snapshot.creates.first?.action)
        guard case .secretRequest(let request) = asked else {
            Issue.record("filed \(asked), not a secret request")
            return
        }
        #expect(request.secret == "AWS_DEV")
        #expect(request.method == "DELETE")
        #expect(request.path == "/my-bucket/k")
        #expect(park.backend.snapshot.consumeCalls.count == 1)
        #expect(h.upstream.requests.count == 2)
        #expect(try verifies(try #require(h.upstream.requests.last), at: Self.start))
    }

    @Test func aConnectionFromOutsideTheRuntimeIsRefused() throws {
        let h = try harness(peers: .fixed(.outsider))
        defer { h.tearDown() }
        #expect(try sigV4(h).status == 403)
        #expect(h.upstream.requests.isEmpty)
        #expect(refusals(h.fixture) == ["runtimeMismatch"])
    }

    @Test func nothingGoesUpstreamWhenTheAuditLogCannotBeWritten() throws {
        let h = try harness()
        defer { h.tearDown() }
        let ledger = h.fixture.directory.appendingPathComponent("audit.jsonl")
        try FileManager.default.removeItem(at: ledger)
        try FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: false)
        #expect(try sigV4(h).status == 503)
        #expect(h.upstream.requests.isEmpty)
    }

    // MARK: Scrubbing

    @Test func realCredentialsEchoedUpstreamReachTheCageAsThePlaceholder() throws {
        let echo = "<Error><AWSAccessKeyId>\(Self.realKey)</AWSAccessKeyId><Token>\(Self.realToken)</Token>"
            + "<Secret>\(Self.realSecret)</Secret></Error>"
        let h = try harness(upstream: RecordingUpstream(status: 403, chunks: [Data(echo.utf8)]))
        defer { h.tearDown() }
        let response = try sigV4(h)
        #expect(response.body.contains(Self.realKey) == false)
        #expect(response.body.contains(Self.realToken) == false)
        #expect(response.body.contains(Self.realSecret) == false)
        #expect(response.body.contains("<AWSAccessKeyId>\(h.placeholder)</AWSAccessKeyId>"))
    }

    @Test func theStagedFingerprintIsTakenOverTheProvidersExactBytes() throws {
        let raw = Self.credentials(expires: Self.start.addingTimeInterval(3_600))
        let h = try harness(provider: Provider([.success(raw)]))
        defer { h.tearDown() }
        let expected = try #require(SecretFingerprinter.load(configDirectory: h.fixture.directory))
            .fingerprint(try #require(SecretValue(raw)))
        let staged = h.fixture.auditLines.compactMap { ($0["detail"] as? [String: String]) }
            .filter { $0["event"] == "staged" }
        #expect(staged.map { $0["fingerprint"] } == [expected])
    }

    @Test func aRotatedAwsCredentialSetStillScrubsEveryPartOfTheOldOne() throws {
        let echo = "<Error><K>\(Self.realKey)</K><T>\(Self.realToken)</T><S>\(Self.realSecret)</S></Error>"
        let provider = Provider([
            .success(Self.credentials(expires: Self.start.addingTimeInterval(600))),
            .success(Self.credentials(
                key: "AKIAROTATEDKEY000002", secret: "rotated/secret", token: "rotated-token-000",
                expires: Self.start.addingTimeInterval(4_200))),
        ])
        let h = try harness(provider: provider, upstream: RecordingUpstream(status: 403, chunks: [Data(echo.utf8)]))
        defer { h.tearDown() }
        h.clock.advance(SecretLaunchBroker.awsRefreshInterval + 1)
        _ = try sigV4(h)
        #expect(eventually {
            (try? self.sigV4(h))?.status == 403
                && h.upstream.requests.last?.headers["authorization"]?.contains("AKIAROTATEDKEY000002") == true
        })
        let response = try sigV4(h)
        for old in [Self.realKey, Self.realToken, Self.realSecret] {
            #expect(response.body.contains(old) == false)
        }
    }

    // MARK: Expiry and refresh

    @Test func expiryComesFromTheCredentialsExpiration() throws {
        let provider = Provider([
            .success(Self.credentials(expires: Self.start.addingTimeInterval(100))),
            .failure(.failed("sso session expired")),
        ])
        // An hour between refreshes, so only the credentials' own Expiration can stop the request.
        let h = try harness(Self.secretsJSON(fields: #","refresh":"1h""#), provider: provider)
        defer { h.tearDown() }
        #expect(try sigV4(h).status == 200)
        h.clock.advance(101)
        #expect(try sigV4(h).status == 403)
        #expect(h.upstream.requests.count == 1)
        #expect(refusals(h.fixture) == ["expired"])
    }

    @Test func expiredCredentialsAreRefreshedBeforeTheRequestIsRefused() throws {
        let rotatedKey = "AKIAROTATEDKEY000002"
        let provider = Provider([
            .success(Self.credentials(expires: Self.start.addingTimeInterval(100))),
            .success(Self.credentials(
                key: rotatedKey, secret: "rotated/secret", token: "rotated-token-000",
                expires: Self.start.addingTimeInterval(3_700))),
        ])
        let h = try harness(Self.secretsJSON(fields: #","refresh":"1h""#), provider: provider)
        defer { h.tearDown() }
        #expect(try sigV4(h).status == 200)
        // Past Expiration but well inside the cadence: the very next request waits for fresh credentials.
        h.clock.advance(101)
        #expect(try sigV4(h).status == 200)
        #expect(h.upstream.requests.last?.headers["authorization"]?.contains(rotatedKey) == true)
        #expect(refusals(h.fixture).isEmpty)
    }

    @Test func aLongRefreshNeverStretchesTheAWSCadence() throws {
        let rotatedKey = "AKIAROTATEDKEY000002"
        let provider = Provider([
            .success(Self.credentials(expires: Self.start.addingTimeInterval(3_600))),
            .success(Self.credentials(
                key: rotatedKey, secret: "rotated/secret", token: "rotated-token-000",
                expires: Self.start.addingTimeInterval(7_200))),
        ])
        let h = try harness(Self.secretsJSON(fields: #","refresh":"30d""#), provider: provider)
        defer { h.tearDown() }
        h.clock.advance(SecretLaunchBroker.awsRefreshInterval + 1)
        _ = try sigV4(h)
        #expect(eventually {
            (try? self.sigV4(h))?.status == 200
                && h.upstream.requests.last?.headers["authorization"]?.contains(rotatedKey) == true
        })
    }

    @Test func refreshedCredentialsAreUsedAndExtendTheExpiry() throws {
        let rotatedKey = "AKIAROTATEDKEY000002"
        let provider = Provider([
            .success(Self.credentials(expires: Self.start.addingTimeInterval(600))),
            .success(Self.credentials(
                key: rotatedKey, secret: "rotated/secret", token: "rotated-token-000",
                expires: Self.start.addingTimeInterval(4_200))),
        ])
        let h = try harness(provider: provider)
        defer { h.tearDown() }
        h.clock.advance(SecretLaunchBroker.awsRefreshInterval + 1)
        _ = try sigV4(h)
        #expect(eventually {
            (try? self.sigV4(h))?.status == 200
                && h.upstream.requests.last?.headers["authorization"]?.contains(rotatedKey) == true
        })
        h.clock.advance(600)
        #expect(try sigV4(h).status == 200)
        let last = try #require(h.upstream.requests.last)
        #expect(last.headers["x-amz-security-token"] == "rotated-token-000")
    }

    // MARK: Responses

    private static let minted = "newlyMintedSecret/aaaa+bbbb"

    @Test func aResponseCarryingNewCredentialsIsRefusedBeforeAnyByteReachesTheAgent() throws {
        let upstream = RecordingUpstream(chunks: [
            Data("<Credentials><AccessKeyId>ASIANEWKEY</AccessKeyId><SecretAcc".utf8),
            Data("essKey>\(Self.minted)</SecretAccessKey></Credentials>".utf8),
        ])
        let h = try harness(Self.secretsJSON(service: "bedrock"), upstream: upstream)
        defer { h.tearDown() }
        let response = try sigV4(h, contentSHA256: String(repeating: "0", count: 64))
        #expect(response.status == 502)
        #expect(response.body.contains("credentials"))
        #expect(response.body.contains(Self.minted) == false)
        #expect(response.body.contains("ASIANEWKEY") == false)
        #expect(refusals(h.fixture) == ["awsCredentialsInResponse"])
        #expect(h.fixture.auditLines.contains { $0["kind"] as? String == "secret.misuse" } == false)
        #expect(h.fixture.auditText.contains(Self.minted) == false)
    }

    @Test func credentialsLateInALargeResponseCutTheStreamBeforeTheValue() throws {
        let filler = Data(repeating: UInt8(ascii: "x"), count: 20_000)
        let upstream = RecordingUpstream(
            chunks: Array(repeating: filler, count: 5) + [Data(#"{"SecretAccessKey":"\#(Self.minted)"}"#.utf8)])
        let h = try harness(Self.secretsJSON(service: "bedrock"), upstream: upstream)
        defer { h.tearDown() }
        let response = try sigV4(h, contentSHA256: String(repeating: "0", count: 64))
        #expect(response.body.contains(Self.minted) == false)
        #expect(response.body.contains("SecretAccessKey") == false)
        #expect(response.body.hasPrefix("xxxx"))
        #expect(refusals(h.fixture) == ["awsCredentialsInResponse"])
    }

    @Test func s3ObjectBodiesThatNameSecretAccessKeyPassThrough() throws {
        let upstream = RecordingUpstream(chunks: [Data("aws_secret_access_key: SecretAccessKey=notes".utf8)])
        let h = try harness(upstream: upstream)
        defer { h.tearDown() }
        let response = try sigV4(h)
        #expect(response.status == 200)
        #expect(response.body == "aws_secret_access_key: SecretAccessKey=notes")
        #expect(refusals(h.fixture).isEmpty)
    }

    @Test func hexEncodedCanonicalRequestsInS3ErrorBodiesAreScrubbed() throws {
        func hex(_ text: String) -> String { text.utf8.map { String(format: "%02x", $0) }.joined(separator: " ") }
        let body = "<Error><Code>SignatureDoesNotMatch</Code><CanonicalRequestBytes>47 45 54 0a "
            + "\(hex("x-amz-security-token:" + Self.realToken)) 0a \(hex(Self.realKey).uppercased())</CanonicalRequestBytes></Error>"
        let upstream = RecordingUpstream(status: 403, chunks: [Data(body.utf8)])
        let h = try harness(upstream: upstream)
        defer { h.tearDown() }
        let response = try sigV4(h)
        #expect(response.status == 403)
        #expect(response.body.contains("SignatureDoesNotMatch"))
        #expect(response.body.contains(hex(Self.realToken)) == false)
        #expect(response.body.contains(hex(Self.realKey).uppercased()) == false)
        #expect(response.body.contains("[rv:redacted]"))
    }

    // MARK: Lease

    @Test func theLeaseStagesAPlaceholderKeyAThrowawaySecretAndTheEndpoint() throws {
        let h = try harness()
        defer { h.tearDown() }
        #expect(h.placeholder.hasPrefix("rvph_"))
        #expect(h.environment["AWS_SECRET_ACCESS_KEY"]?.isEmpty == false)
        #expect(h.environment["AWS_SECRET_ACCESS_KEY"] != Self.realSecret)
        #expect(h.environment["AWS_SECRET_ACCESS_KEY"]?.contains("rvph_") == false)
        #expect(h.environment["AWS_ENDPOINT_URL_S3"] == "http://127.0.0.1:\(h.port)/s/AWS_DEV")
        #expect(h.environment["AWS_REGION"] == "us-east-1")
        #expect(h.environment["AWS_SESSION_TOKEN"] == nil)
        let staged = h.environment.values.joined(separator: "\n")
        for real in [Self.realKey, Self.realSecret, Self.realToken] {
            #expect(staged.contains(real) == false)
            #expect(h.fixture.auditText.contains(real) == false)
        }
    }

    @Test func unusableCredentialsFailTheLaunch() throws {
        for bad in ["not json", #"{"AccessKeyId":"AKIA"}"#, Self.credentials(expires: nil).replacingOccurrences(
            of: "\"Version\":1", with: "\"Version\":1,\"Expiration\":\"soon\"")]
        {
            let fixture = try SecretsFixture(Self.secretsJSON())
            defer { fixture.tearDown() }
            let broker = SecretLaunchBroker(
                configDirectory: fixture.directory, resolver: Provider([.success(bad)]).resolver,
                transport: RecordingUpstream().transport, workspace: nil)
            defer { broker.stop() }
            guard case .failure(let error) = broker.lease(names: ["AWS_DEV"], agent: nil) else {
                Issue.record("unusable credentials were staged")
                continue
            }
            #expect(error == .awsCredentialsUnusable("AWS_DEV"))
            #expect(error.message.contains("AKIA") == false)
        }
    }

    @Test func twoAWSSecretsInOneLaunchAreRefused() throws {
        let second = #"""
            ,{"name":"AWS_BEDROCK","source":{"awsProfile":{"profile":"dev"}},
              "delivery":{"awsSigV4":{"upstream":"https://bedrock-runtime.us-east-1.amazonaws.com","region":"us-east-1",
                                      "service":"bedrock","endpointEnv":"AWS_ENDPOINT_URL_BEDROCK_RUNTIME"}}}
            """#
        let fixture = try SecretsFixture(Self.secretsJSON(extra: second))
        defer { fixture.tearDown() }
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory,
            resolver: Provider([.success(Self.credentials(expires: nil))]).resolver,
            transport: RecordingUpstream().transport, workspace: nil)
        defer { broker.stop() }
        guard case .failure(let error) = broker.lease(names: ["AWS_DEV", "AWS_BEDROCK"], agent: nil) else {
            Issue.record("two AWS secrets would both stage AWS_ACCESS_KEY_ID")
            return
        }
        #expect(error == .variableCollision(variable: "AWS_ACCESS_KEY_ID", secrets: ["AWS_DEV", "AWS_BEDROCK"]))
        #expect(broker.liveCount == 0)
    }

    // MARK: Configuration

    @Test func theDecoderRoundTripsAWSDefinitions() throws {
        let decoded = try SecretsConfiguration.decode(Data(Self.secretsJSON(
            allow: #"[{"methods":["GET"],"path":"/my-bucket/*"}]"#).utf8)).get()
        let secret = try #require(decoded.secret(named: "AWS_DEV"))
        #expect(secret.source == .awsProfile(profile: "dev"))
        guard case .awsSigV4(let binding) = secret.delivery else {
            Issue.record("awsSigV4 delivery did not decode")
            return
        }
        #expect(binding.upstream.absoluteString == "https://s3.us-east-1.amazonaws.com")
        #expect(binding.region == "us-east-1")
        #expect(binding.service == "s3")
        #expect(binding.endpointEnv == "AWS_ENDPOINT_URL_S3")
        #expect(binding.allow.isEmpty == false)
        #expect(try SecretsConfiguration.decode(decoded.encoded()).get() == decoded)
    }

    @Test(arguments: [
        // Unknown key.
        #"{"awsProfile":{"profile":"dev"}}|{"awsSigV4":{"upstream":"https://s3.amazonaws.com","region":"us-east-1","service":"s3","endpointEnv":"AWS_ENDPOINT_URL","signHost":"x"}}"#,
        // Plain http upstream.
        #"{"awsProfile":{"profile":"dev"}}|{"awsSigV4":{"upstream":"http://s3.amazonaws.com","region":"us-east-1","service":"s3","endpointEnv":"AWS_ENDPOINT_URL"}}"#,
        // Region and service are scope parts: no `/` or spaces.
        #"{"awsProfile":{"profile":"dev"}}|{"awsSigV4":{"upstream":"https://s3.amazonaws.com","region":"us-east-1/x","service":"s3","endpointEnv":"AWS_ENDPOINT_URL"}}"#,
        #"{"awsProfile":{"profile":"dev"}}|{"awsSigV4":{"upstream":"https://s3.amazonaws.com","region":"us-east-1","service":"","endpointEnv":"AWS_ENDPOINT_URL"}}"#,
        // The endpoint variable must be a variable name, and not one rv stages itself.
        #"{"awsProfile":{"profile":"dev"}}|{"awsSigV4":{"upstream":"https://s3.amazonaws.com","region":"us-east-1","service":"s3","endpointEnv":"1BAD"}}"#,
        #"{"awsProfile":{"profile":"dev"}}|{"awsSigV4":{"upstream":"https://s3.amazonaws.com","region":"us-east-1","service":"s3","endpointEnv":"AWS_ACCESS_KEY_ID"}}"#,
        // A profile is a single token.
        #"{"awsProfile":{"profile":"--debug"}}|{"awsSigV4":{"upstream":"https://s3.amazonaws.com","region":"us-east-1","service":"s3","endpointEnv":"AWS_ENDPOINT_URL"}}"#,
        #"{"awsProfile":{"profile":"dev","region":"x"}}|{"awsSigV4":{"upstream":"https://s3.amazonaws.com","region":"us-east-1","service":"s3","endpointEnv":"AWS_ENDPOINT_URL"}}"#,
        // An AWS profile's value is a credential set: it only signs.
        #"{"awsProfile":{"profile":"dev"}}|{"environment":{}}"#,
        #"{"awsProfile":{"profile":"dev"}}|{"gateway":{"upstream":"https://s3.amazonaws.com","baseURLEnv":"S3_URL"}}"#,
        // And signing needs a credential set.
        #"{"keychain":{"service":"rv","account":"aws"}}|{"awsSigV4":{"upstream":"https://s3.amazonaws.com","region":"us-east-1","service":"s3","endpointEnv":"AWS_ENDPOINT_URL"}}"#,
    ])
    func theStrictDecoderRefusesMalformedAWSDefinitions(_ pair: String) {
        let parts = pair.split(separator: "|", maxSplits: 1).map(String.init)
        let json = #"{"version":1,"secrets":[{"name":"AWS_DEV","source":\#(parts[0]),"delivery":\#(parts[1])}]}"#
        guard case .failure = SecretsConfiguration.decode(Data(json.utf8)) else {
            Issue.record("accepted: \(pair)")
            return
        }
    }

    @Test(arguments: [
        "sts", "iam", "sso", "sso-oauth", "awsssoportal", "awsssooidc", "signin", "cognito-identity", "cognito-idp",
        "s3express", "ecr", "ecr-public", "codeartifact",
    ])
    func theDecoderRefusesServicesThatMintCredentials(_ service: String) {
        let json = Self.secretsJSON(service: service)
        guard case .failure(let error) = SecretsConfiguration.decode(Data(json.utf8)) else {
            Issue.record("accepted credential-minting service \(service)")
            return
        }
        #expect(error.message.contains("mints credentials"))
        #expect(error.message.contains(service))
    }

    @Test(arguments: ["ec2", "sqs", "sns", "rds", "elasticloadbalancing", "autoscaling", "cloudformation", "monitoring"])
    func theDecoderRefusesReadOnlyForQueryProtocolServices(_ service: String) throws {
        let json = Self.secretsJSON(allow: #"["read-only"]"#, service: service)
        guard case .failure(let error) = SecretsConfiguration.decode(Data(json.utf8)) else {
            Issue.record("accepted read-only on query-protocol service \(service)")
            return
        }
        #expect(error.message.contains("read-only"))
        #expect(error.message.contains("query"))
        // An explicit rule is the operator's own and stays allowed, as does read-only elsewhere.
        _ = try SecretsConfiguration.decode(Data(Self.secretsJSON(
            allow: #"[{"methods":["POST"],"path":"/"}]"#, service: service).utf8)).get()
        _ = try SecretsConfiguration.decode(Data(Self.secretsJSON(allow: #"["read-only"]"#, service: "s3").utf8)).get()
    }

    // MARK: Provider

    @Test func theProfileIsReadWithExportCredentials() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-aws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("aws")
        try Data("""
            #!/bin/sh
            printf '%s\\n' "$*" > "$HOME/args"
            printf '%s' '\(Self.credentials(expires: Self.start))'
            """.utf8).write(to: script)
        chmod(script.path, 0o755)
        let environment = ["PATH": directory.path, "HOME": directory.path]
        let value = try SecretCommandProviders.awsProfile("dev", environment: environment).get()
        let definition = try #require(
            try SecretsConfiguration.decode(Data(Self.secretsJSON().utf8)).get().secret(named: "AWS_DEV"))
        guard case .awsCredentials(let set)? = ResolvedSecret.parse(value, for: definition) else {
            Issue.record("the export-credentials output was not read as an AWS credential set")
            return
        }
        #expect(set.expires == Self.start)
        #expect(String(describing: value) == "<redacted>")
        let args = try String(contentsOf: directory.appendingPathComponent("args"), encoding: .utf8)
        #expect(args == "configure export-credentials --profile dev --format process\n")
    }
}
