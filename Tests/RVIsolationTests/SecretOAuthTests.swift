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

/// `oauth` sources: tokens minted from Keychain credentials, refresh tokens
/// that rotate are written back, and an exchange with an unknown outcome
/// blocks its refresh token instead of resending it.
@Suite("Secret OAuth minting")
struct SecretOAuthTests {
    static let refreshItem = SecretKeychainItem(service: "rv.oauth", account: "gh-refresh")
    static let secretItem = SecretKeychainItem(service: "rv.oauth", account: "gh-client-secret")
    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    static let source = OAuthSource(
        tokenURL: URL(string: "https://issuer.example.com/oauth/token")!, clientID: "client-1",
        clientSecret: secretItem, refreshToken: refreshItem, scope: "repo read:org")

    /// A Keychain, an issuer, and a state directory, all fake.
    final class Issuer: Sendable {
        let keychain = Mutex<[SecretKeychainItem: String]>([refreshItem: "rt-1", secretItem: "cs-shhh"])
        let sent = Mutex<[[String: String]]>([])
        let answers: Mutex<[OAuthTokenMinter.Exchange]>
        let writable = Mutex(true)
        let directory: URL
        let onSend = Mutex<(@Sendable () -> Void)?>(nil)

        init(_ answers: [OAuthTokenMinter.Exchange] = []) throws {
            self.answers = Mutex(answers)
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("rv-oauth-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        /// The next answer, or a rotation of whatever refresh token was sent.
        static func rotation(of sent: [String: String], access: String) -> OAuthTokenMinter.Exchange {
            let next = sent["refresh_token"].map { "rt-\(Int($0.dropFirst(3))! + 1)" }
            var body: [String: Any] = ["access_token": access, "token_type": "Bearer", "expires_in": 3600]
            if let next { body["refresh_token"] = next }
            return .response(status: 200, body: try! JSONSerialization.data(withJSONObject: body))
        }

        var minter: OAuthTokenMinter {
            OAuthTokenMinter(
                send: { request in
                    let form = Dictionary(
                        String(decoding: request.httpBody ?? Data(), as: UTF8.self).split(separator: "&").map {
                            let pair = $0.split(separator: "=", maxSplits: 1).map {
                                String($0).removingPercentEncoding ?? ""
                            }
                            return (pair[0], pair.count > 1 ? pair[1] : "")
                        }) { $1 }
                    self.onSend.withLock { $0 }?()
                    let count = self.sent.withLock { $0.append(form); return $0.count }
                    return self.answers.withLock { $0.isEmpty ? nil : $0.removeFirst() }
                        ?? Self.rotation(of: form, access: "at-\(count)")
                },
                read: { item in self.keychain.withLock { $0[item] }.flatMap { SecretValue($0) } },
                write: { item, value in
                    guard self.writable.withLock({ $0 }) else { return false }
                    self.keychain.withLock { $0[item] = value.text }
                    return true
                },
                stateDirectory: directory.appendingPathComponent(OAuthTokenMinter.directoryName, isDirectory: true),
                now: { SecretOAuthTests.start })
        }

        var stateFiles: [String] {
            let state = directory.appendingPathComponent(OAuthTokenMinter.directoryName)
            return ((try? FileManager.default.contentsOfDirectory(atPath: state.path)) ?? []).filter { $0.hasSuffix(".json") }
        }

        func tearDown() { try? FileManager.default.removeItem(at: directory) }
    }

    static func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private func token(_ result: Result<SecretValue, SecretResolutionError>) -> OAuthAccessToken? {
        guard case .success(let value) = result else { return nil }
        return OAuthAccessToken(value)
    }

    private func message(_ result: Result<SecretValue, SecretResolutionError>) -> String {
        guard case .failure(let error) = result else { return "minted" }
        return error.message
    }

    // MARK: Grants

    @Test func aRefreshGrantMintsAndStoresTheRotatedRefreshToken() throws {
        let issuer = try Issuer()
        defer { issuer.tearDown() }
        let minted = try #require(token(issuer.minter.mint(Self.source)))
        #expect(minted.token == SecretValue("at-1"))
        #expect(minted.expires == Self.start.addingTimeInterval(3600))
        #expect(issuer.sent.withLock { $0 } == [[
            "grant_type": "refresh_token", "refresh_token": "rt-1", "scope": "repo read:org",
            "client_id": "client-1", "client_secret": "cs-shhh",
        ]])
        #expect(issuer.keychain.withLock { $0[Self.refreshItem] } == "rt-2")
        #expect(issuer.stateFiles.isEmpty)
        // The next mint sends the rotated token.
        _ = issuer.minter.mint(Self.source)
        #expect(issuer.sent.withLock { $0.last?["refresh_token"] } == "rt-2")
    }

    @Test func theClientCredentialsGrantSendsNoRefreshTokenAndKeepsNoState() throws {
        let issuer = try Issuer()
        defer { issuer.tearDown() }
        var source = Self.source
        source.refreshToken = nil
        source.scope = nil
        #expect(token(issuer.minter.mint(source))?.token == SecretValue("at-1"))
        #expect(issuer.sent.withLock { $0 } == [
            ["grant_type": "client_credentials", "client_id": "client-1", "client_secret": "cs-shhh"]
        ])
        #expect(issuer.stateFiles.isEmpty)
    }

    @Test func aMissingStoredCredentialIsNotFoundAndNothingIsSent() throws {
        let issuer = try Issuer()
        defer { issuer.tearDown() }
        issuer.keychain.withLock { $0[Self.refreshItem] = nil }
        #expect(message(issuer.minter.mint(Self.source)).contains("not found: keychain item rv.oauth / gh-refresh"))
        #expect(issuer.sent.withLock { $0 }.isEmpty)
    }

    // MARK: Failure classes

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let exchange: OAuthTokenMinter.Exchange
        let recovery: String
        /// Whether rv sends that refresh token again.
        let retried: Bool
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "connect failure", exchange: .notSent, recovery: "(retry)", retried: true),
        Case(name: "no answer after sending", exchange: .noAnswer, recovery: "(reauthorize)", retried: false),
        Case(name: "unusable 200", exchange: .response(status: 200, body: json(["token_type": "Bearer"])),
            recovery: "(reauthorize)", retried: false),
        Case(name: "invalid_grant", exchange: .response(status: 400, body: json(["error": "invalid_grant"])),
            recovery: "(reauthorize)", retried: false),
        Case(name: "invalid_client", exchange: .response(status: 401, body: json(["error": "invalid_client"])),
            recovery: "(fixConfiguration)", retried: true),
        Case(name: "invalid_scope", exchange: .response(status: 400, body: json(["error": "invalid_scope"])),
            recovery: "(fixConfiguration)", retried: true),
        Case(name: "server error without an RFC 6749 body", exchange: .response(status: 503, body: Data()),
            recovery: "(reauthorize)", retried: false),
        Case(name: "proxy error page", exchange: .response(status: 502, body: Data("<html>bad gateway</html>".utf8)),
            recovery: "(reauthorize)", retried: false),
        Case(name: "server error with an RFC 6749 body",
            exchange: .response(status: 503, body: json(["error": "temporarily_unavailable"])), recovery: "(retry)", retried: true),
        Case(name: "200 carrying invalid_client", exchange: .response(status: 200, body: json(["error": "invalid_client"])),
            recovery: "(fixConfiguration)", retried: true),
        Case(name: "200 carrying invalid_grant", exchange: .response(status: 200, body: json(["error": "invalid_grant"])),
            recovery: "(reauthorize)", retried: false),
        Case(name: "200 carrying an unknown error",
            exchange: .response(status: 200, body: json(["error": "incorrect_client_credentials"])),
            recovery: "(retry)", retried: true),
        Case(name: "redirect", exchange: .response(status: 302, body: Data()), recovery: "(fixConfiguration)", retried: true),
    ]

    @Test(arguments: cases)
    func eachFailureIsClassifiedAndOnlyAmbiguousOnesBlockTheToken(_ failure: Case) throws {
        let issuer = try Issuer([failure.exchange])
        defer { issuer.tearDown() }
        #expect(message(issuer.minter.mint(Self.source)).hasSuffix(failure.recovery))
        let again = issuer.minter.mint(Self.source)
        #expect(issuer.sent.withLock { $0.count } == (failure.retried ? 2 : 1))
        if failure.retried == false {
            #expect(message(again).hasSuffix(failure.recovery))
            // Storing a new refresh token lifts the block.
            issuer.keychain.withLock { $0[Self.refreshItem] = "rt-7" }
            #expect(token(issuer.minter.mint(Self.source))?.token != nil)
            #expect(issuer.sent.withLock { $0.last?["refresh_token"] } == "rt-7")
        }
    }

    @Test func aRotatedRefreshTokenIsKeptEvenWhenTheAccessTokenIsRejected() throws {
        let oversized = String(repeating: "a", count: OAuthTokenMinter.maximumTokenBytes + 1)
        let bodies: [[String: Any]] = [
            ["access_token": "at-1", "token_type": "mac", "refresh_token": "rt-9"],
            ["access_token": oversized, "token_type": "Bearer", "refresh_token": "rt-9"],
            ["access_token": "has space", "token_type": "Bearer", "refresh_token": "rt-9"],
        ]
        for body in bodies {
            let issuer = try Issuer([.response(status: 200, body: Self.json(body))])
            defer { issuer.tearDown() }
            #expect(message(issuer.minter.mint(Self.source)).hasSuffix("(reauthorize)"))
            #expect(issuer.keychain.withLock { $0[Self.refreshItem] } == "rt-9", "the issuer rotated; the new token is the grant")
            // The next mint sends the new token, not the spent one.
            _ = issuer.minter.mint(Self.source)
            #expect(issuer.sent.withLock { $0.last?["refresh_token"] } == "rt-9")
        }
    }

    @Test func aRejectedAccessTokenWithAnUnstorableRotationNeverResendsTheOldToken() throws {
        let issuer = try Issuer([.response(status: 200, body: Self.json(
            ["access_token": "at-1", "token_type": "mac", "refresh_token": "rt-9"]))])
        defer { issuer.tearDown() }
        issuer.writable.withLock { $0 = false }
        #expect(message(issuer.minter.mint(Self.source)).hasSuffix("(reauthorize)"))
        _ = issuer.minter.mint(Self.source)
        #expect(issuer.sent.withLock { $0.count } == 1)
    }

    @Test func expiresInIsClampedAndNeverTraps() throws {
        for (raw, expected) in [("1e19", 86_400.0), ("1e10", 86_400.0), ("86400", 86_400.0), ("0.2", 1.0), ("30", 30.0)] {
            let body = Data(#"{"access_token":"at-1","token_type":"Bearer","expires_in":\#(raw)}"#.utf8)
            let issuer = try Issuer([.response(status: 200, body: body)])
            defer { issuer.tearDown() }
            let minted = try #require(token(issuer.minter.mint(Self.source)), "expires_in \(raw)")
            #expect(minted.expires == Self.start.addingTimeInterval(expected), "expires_in \(raw)")
        }
        for raw in ["0", "-5", "\"soon\""] {
            let body = Data(#"{"access_token":"at-1","token_type":"Bearer","expires_in":\#(raw)}"#.utf8)
            let issuer = try Issuer([.response(status: 200, body: body)])
            defer { issuer.tearDown() }
            #expect(try #require(token(issuer.minter.mint(Self.source))).expires == nil, "expires_in \(raw)")
        }
        #expect(OAuthAccessToken.encode(token: "at", expires: Date(timeIntervalSince1970: 1e19)) == nil, "no trap")
    }

    @Test func theClientCredentialsGrantRetriesWhatTheRefreshGrantBlocks() {
        let proxyError = OAuthTokenMinter.Exchange.response(status: 502, body: Data())
        #expect(OAuthTokenMinter.classify(proxyError, grant: .clientCredentials)
            == .failed(.retry, detail: "the token endpoint failed (HTTP 502)"))
        #expect(OAuthTokenMinter.classify(.noAnswer, grant: .clientCredentials) == .failed(.retry, detail: "the token endpoint did not answer"))
        let invalidGrant = OAuthTokenMinter.Exchange.response(status: 400, body: Self.json(["error": "invalid_grant"]))
        guard case .failed(.fixConfiguration, _, _) = OAuthTokenMinter.classify(invalidGrant, grant: .clientCredentials) else {
            Issue.record("invalid_grant on client credentials is a configuration problem")
            return
        }
    }

    @Test func aCrashMidExchangeBlocksThatRefreshTokenUntilItIsReplaced() throws {
        let issuer = try Issuer()
        defer { issuer.tearDown() }
        let stateDirectory = issuer.directory.appendingPathComponent(OAuthTokenMinter.directoryName)
        let saved = issuer.directory.appendingPathComponent("in-flight.json")
        // While the exchange is in flight the state is already on disk; keep a copy as a crash would.
        issuer.onSend.withLock {
            $0 = {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: stateDirectory.path)) ?? []
                if let file = files.first(where: { $0.hasSuffix(".json") }) {
                    try? FileManager.default.copyItem(at: stateDirectory.appendingPathComponent(file), to: saved)
                }
            }
        }
        issuer.answers.withLock { $0 = [.response(status: 200, body: Self.json(["access_token": "at-x", "token_type": "bearer"]))] }
        #expect(token(issuer.minter.mint(Self.source)) != nil)
        #expect(FileManager.default.fileExists(atPath: saved.path))
        issuer.onSend.withLock { $0 = nil }
        // Put the in-flight record back, as if rv died before the exchange ended.
        let stateFile = stateDirectory.appendingPathComponent("\(OAuthTokenMinter.key(Self.refreshItem)).json")
        try FileManager.default.copyItem(at: saved, to: stateFile)
        #expect(message(issuer.minter.mint(Self.source)).hasSuffix("(investigate)"))
        #expect(issuer.sent.withLock { $0.count } == 1)
        issuer.keychain.withLock { $0[Self.refreshItem] = "rt-5" }
        #expect(token(issuer.minter.mint(Self.source)) != nil)
        #expect(issuer.sent.withLock { $0.count } == 2)
    }

    @Test func clearingTheBlockLetsTheSameRefreshTokenBeSentAgain() throws {
        let issuer = try Issuer([.response(status: 400, body: Self.json(["error": "invalid_grant"]))])
        defer { issuer.tearDown() }
        #expect(OAuthRefreshBlock.clear(Self.refreshItem, configDirectory: issuer.directory) == false)
        #expect(message(issuer.minter.mint(Self.source)).hasSuffix("(reauthorize)"))
        #expect(message(issuer.minter.mint(Self.source)).contains("rv secrets oauth-reset"))
        #expect(issuer.sent.withLock { $0.count } == 1)
        let file = OAuthRefreshBlock.stateFile(Self.refreshItem, configDirectory: issuer.directory)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let mode = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
        #expect(mode & 0o777 == 0o600, "the refresh-token state file is owner-only")
        #expect(OAuthRefreshBlock.clear(Self.refreshItem, configDirectory: issuer.directory) == true)
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
        #expect(token(issuer.minter.mint(Self.source)) != nil)
        #expect(issuer.sent.withLock { $0.map { $0["refresh_token"] } } == ["rt-1", "rt-1"])
    }

    @Test func aRotationThatCannotBeStoredNeverResendsTheOldToken() throws {
        let issuer = try Issuer()
        defer { issuer.tearDown() }
        issuer.writable.withLock { $0 = false }
        #expect(message(issuer.minter.mint(Self.source)).hasSuffix("(reauthorize)"))
        _ = issuer.minter.mint(Self.source)
        #expect(issuer.sent.withLock { $0.count } == 1)
    }

    @Test func issuerErrorTextNeverReachesTheMessage() throws {
        let body = Self.json([
            "error": "invalid_grant<script>rt-1",
            "error_description": "refresh token rt-1 was revoked by admin",
        ])
        let issuer = try Issuer([.response(status: 400, body: body)])
        defer { issuer.tearDown() }
        let text = message(issuer.minter.mint(Self.source))
        #expect(text.contains("invalid_grantscriptrt-1, HTTP 400"))
        #expect(text.contains("revoked") == false)
        #expect(text.contains("<") == false)
        #expect(text.contains("cs-shhh") == false)
    }

    @Test func concurrentRefreshesAreSerializedAndEachUsesTheLatestToken() throws {
        let issuer = try Issuer()
        defer { issuer.tearDown() }
        issuer.onSend.withLock { $0 = { Thread.sleep(forTimeInterval: 0.05) } }
        let done = Mutex(0)
        let threads = (0..<3).map { _ in
            Thread {
                _ = issuer.minter.mint(Self.source)
                done.withLock { $0 += 1 }
            }
        }
        threads.forEach { $0.start() }
        #expect(eventually(seconds: 10) { done.withLock { $0 } == 3 })
        #expect(issuer.sent.withLock { $0.map { $0["refresh_token"] ?? "" } } == ["rt-1", "rt-2", "rt-3"])
        #expect(issuer.keychain.withLock { $0[Self.refreshItem] } == "rt-4")
    }

    // MARK: Gateway

    static let secretsJSON = """
        {"version":1,"secrets":[
          {"name":"GH","source":{"oauth":{"tokenURL":"https://issuer.example.com/oauth/token",
             "clientID":"client-1","refreshToken":{"service":"rv.oauth","account":"gh-refresh"}}},
           "delivery":{"gateway":{"upstream":"https://api.example.com","baseURLEnv":"GH_API"}}}
        ]}
        """

    @Test func mintedTokensReachTheUpstreamAndAreReMintedOnTheirLifetime() throws {
        let fixture = try SecretsFixture(Self.secretsJSON)
        defer { fixture.tearDown() }
        let clock = TestClock(Self.start)
        let mints = Mutex(0)
        let failing = Mutex(false)
        let resolver = SecretResolver { source in
            guard case .oauth = source else { return .failure(.notFound("not oauth")) }
            if failing.withLock({ $0 }) { return .failure(.failed("issuer down (retry)")) }
            let n = mints.withLock { $0 += 1; return $0 }
            return .success(OAuthAccessToken.encode(token: "at-\(n)", expires: clock.now.addingTimeInterval(600))!)
        }
        let upstream = RecordingUpstream()
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory, resolver: resolver, transport: upstream.transport,
            peers: .fixed(.member), workspace: "W1", now: { clock.now })
        defer { broker.stop() }
        let lease = try broker.lease(names: ["GH"], agent: nil).get()
        broker.bind(lease, processGroup: testProcessGroup)
        let placeholder = try #require(lease.environment.first { $0.name == "GH" }?.value)
        #expect(placeholder.hasPrefix("at-") == false)
        let port = try #require(broker.gatewayPort)
        func send() throws -> Int {
            try gatewayExchange(port: port,
                "GET /s/GH/user HTTP/1.1\r\nAuthorization: Bearer \(placeholder)\r\nContent-Length: 0\r\n\r\n").status
        }
        func lastToken() -> String? { upstream.requests.last?.headers["authorization"] }

        #expect(try send() == 200)
        #expect(lastToken() == "Bearer at-1")
        // Before half-life nothing is minted.
        clock.advance(299)
        #expect(try send() == 200)
        #expect(mints.withLock { $0 } == 1)
        // Past half-life: served the current token, and a new one is minted behind it.
        clock.advance(2)
        #expect(try send() == 200)
        #expect(lastToken() == "Bearer at-1")
        #expect(eventually { mints.withLock { $0 } == 2 })
        #expect(eventually { (try? send()) == 200 && lastToken() == "Bearer at-2" })
        // At expiry the request waits for a fresh one.
        clock.advance(601)
        #expect(try send() == 200)
        #expect(lastToken() == "Bearer at-3")
        // An issuer that cannot mint past expiry stops the secret being used.
        failing.withLock { $0 = true }
        clock.advance(601)
        let forwarded = upstream.requests.count
        #expect(try send() == 503)
        #expect(upstream.requests.count == forwarded)
        #expect(fixture.auditLines.contains { ($0["detail"] as? [String: String])?["refusal"] == "refreshFailed" })
        #expect(fixture.auditLines.contains {
            ($0["detail"] as? [String: String])?["activity"] == "refreshFailed"
        })
    }

    final class MintCount: Sendable {
        private let value = Mutex(0)
        var count: Int { value.withLock { $0 } }
        func next() -> Int { value.withLock { $0 += 1; return $0 } }
    }

    final class Harness: Sendable {
        let broker: SecretLaunchBroker
        let upstream: RecordingUpstream
        let mints: MintCount
        let send: @Sendable () throws -> Int

        init(broker: SecretLaunchBroker, upstream: RecordingUpstream, mints: MintCount, send: @escaping @Sendable () throws -> Int) {
            self.broker = broker
            self.upstream = upstream
            self.mints = mints
            self.send = send
        }
    }

    /// A broker leasing `GH` whose tokens live `lifetime` seconds, with a mint counter.
    private func lifetimeHarness(
        lifetime: TimeInterval, fixture: SecretsFixture, clock: TestClock
    ) throws -> Harness {
        let mints = MintCount()
        let resolver = SecretResolver { source in
            guard case .oauth = source else { return .failure(.notFound("not oauth")) }
            return .success(OAuthAccessToken.encode(
                token: "at-\(mints.next())", expires: clock.now.addingTimeInterval(lifetime))!)
        }
        let upstream = RecordingUpstream()
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory, resolver: resolver, transport: upstream.transport,
            peers: .fixed(.member), workspace: "W1", now: { clock.now })
        let lease = try broker.lease(names: ["GH"], agent: nil).get()
        broker.bind(lease, processGroup: testProcessGroup)
        let placeholder = try #require(lease.environment.first { $0.name == "GH" }?.value)
        let port = try #require(broker.gatewayPort)
        let send: @Sendable () throws -> Int = {
            try gatewayExchange(port: port,
                "GET /s/GH/user HTTP/1.1\r\nAuthorization: Bearer \(placeholder)\r\nContent-Length: 0\r\n\r\n").status
        }
        return Harness(broker: broker, upstream: upstream, mints: mints, send: send)
    }

    @Test func nothingIsMintedOnceTheDefinitionsOwnExpiryHasPassed() throws {
        let json = Self.secretsJSON.replacingOccurrences(
            of: #"GH_API"}}}"#, with: #"GH_API"}},"expires":"2027-01-15T08:16:40Z"}"#)
        #expect(json != Self.secretsJSON)
        let fixture = try SecretsFixture(json)
        defer { fixture.tearDown() }
        let clock = TestClock(Self.start)
        let harness = try lifetimeHarness(lifetime: 3600, fixture: fixture, clock: clock)
        defer { harness.broker.stop() }
        #expect(harness.mints.count == 1)
        clock.advance(1001)
        #expect(try harness.send() != 200)
        #expect(harness.mints.count == 1, "an expired definition must not rotate the refresh token for nothing")
        #expect(try harness.send() != 200)
        #expect(harness.mints.count == 1)
    }

    @Test func aTokenThatLivesUnderThePacingFloorIsRefreshedBeforeARequestAfterItExpires() throws {
        let fixture = try SecretsFixture(Self.secretsJSON)
        defer { fixture.tearDown() }
        let clock = TestClock(Self.start)
        let harness = try lifetimeHarness(lifetime: 20, fixture: fixture, clock: clock)
        defer { harness.broker.stop() }
        clock.advance(25)
        #expect(try harness.send() == 200, "past expiry the request waits for a fresh token instead of being refused")
        #expect(harness.upstream.requests.last?.headers["authorization"] == "Bearer at-2")
        #expect(harness.mints.count == 2)
    }

    @Test func aTokenAlreadyExpiredAtLaunchFailsTheLease() throws {
        let fixture = try SecretsFixture(Self.secretsJSON)
        defer { fixture.tearDown() }
        let resolver = SecretResolver { _ in .success(OAuthAccessToken.encode(token: "at-1", expires: Self.start)!) }
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory, resolver: resolver, transport: RecordingUpstream().transport,
            peers: .fixed(.member), workspace: "W1", now: { Self.start })
        defer { broker.stop() }
        guard case .failure(.expired(let secret, _)) = broker.lease(names: ["GH"], agent: nil) else {
            Issue.record("an expired token was leased")
            return
        }
        #expect(secret == "GH")
    }

    // MARK: Configuration

    @Test func theDecoderRoundTripsOAuthSources() throws {
        let decoded = try SecretsConfiguration.decode(Data(Self.secretsJSON.utf8)).get()
        guard case .oauth(let oauth) = decoded.secret(named: "GH")?.source else {
            Issue.record("oauth source did not decode")
            return
        }
        #expect(oauth.refreshToken == Self.refreshItem)
        #expect(oauth.clientSecret == nil)
        #expect(try SecretsConfiguration.decode(decoded.encoded()).get() == decoded)
        let full = SecretsConfiguration(secrets: [
            SecretDefinition(name: "GH", source: .oauth(Self.source), delivery: .gateway(SecretGatewayBinding(
                upstream: URL(string: "https://api.example.com")!, baseURLEnv: "GH_API")))
        ])
        #expect(try SecretsConfiguration.decode(full.encoded()).get() == full)
    }

    @Test func aTokenURLKeepsItsTrailingSlash() throws {
        let json = Self.secretsJSON.replacingOccurrences(
            of: "https://issuer.example.com/oauth/token", with: "https://issuer.example.com/o/token/")
        let decoded = try SecretsConfiguration.decode(Data(json.utf8)).get()
        guard case .oauth(let oauth) = decoded.secret(named: "GH")?.source else {
            Issue.record("oauth source did not decode")
            return
        }
        #expect(oauth.tokenURL.absoluteString == "https://issuer.example.com/o/token/")
        #expect(try SecretsConfiguration.decode(decoded.encoded()).get() == decoded)
    }

    static let malformed: [(String, String)] = [
        (#""tokenURL":"https://issuer.example.com/oauth/token""#, #""tokenURL":"http://issuer.example.com/token""#),
        (#""tokenURL":"https://issuer.example.com/oauth/token""#, #""tokenURL":"https://issuer.example.com/t?x=1""#),
        (#""clientID":"client-1""#, #""clientID":"client 1""#),
        (#""clientID":"client-1""#, #""clientID":"""#),
        (#""clientID":"client-1","#, #""clientID":"client-1","scope":"repo ","#),
        (#""clientID":"client-1","#, #""clientID":"client-1","audience":"x","#),
        (#"{"service":"rv.oauth","account":"gh-refresh"}"#, #"{"service":"rv.oauth"}"#),
        (#","refreshToken":{"service":"rv.oauth","account":"gh-refresh"}"#, ""),
        (#""delivery":{"gateway":{"upstream":"https://api.example.com","baseURLEnv":"GH_API"}}"#,
            #""delivery":{"environment":{}}"#),
    ]

    @Test(arguments: malformed.indices)
    func theStrictDecoderRefusesMalformedOAuthSources(_ index: Int) {
        let (from, to) = Self.malformed[index]
        let json = Self.secretsJSON.replacingOccurrences(of: from, with: to)
        #expect(json != Self.secretsJSON)
        guard case .failure = SecretsConfiguration.decode(Data(json.utf8)) else {
            Issue.record("accepted: \(to)")
            return
        }
    }
}
