import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RVDomain
import Synchronization
import Testing
@testable import RVIsolation

// MARK: - Stub infrastructure

/// Immutable holder: `URLSession` is thread-safe per Foundation, so sharing is safe.
private final class SessionBox: @unchecked Sendable {
    let session: URLSession
    init(_ session: URLSession) { self.session = session }
}

private struct StubState: Sendable {
    var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    var requests: [URLRequest] = []
}

private final class StubBox: Sendable {
    let mutex = Mutex(StubState())
}

/// Mutable stub state is confined to `StubBox.mutex`; the static holder is initialized once.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let box = StubBox()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let result: Result<(Int, Data), Error> = StubURLProtocol.box.mutex.withLock { state in
            state.requests.append(request)
            guard let handler = state.handler else {
                return .failure(URLError(.cannotConnectToHost))
            }
            do {
                return .success(try handler(request))
            } catch {
                return .failure(error)
            }
        }
        switch result {
        case .success((let status, let data)):
            let url = request.url ?? URL(string: "https://vault.example.com/")!
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func setStubHandler(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) {
    StubURLProtocol.box.mutex.withLock {
        $0.handler = handler
        $0.requests = []
    }
}

private func recordedRequests() -> [URLRequest] {
    StubURLProtocol.box.mutex.withLock { $0.requests }
}

private func makeClient(
    endpoint: String = "https://vault.example.com:8200",
    mount: String = "secret",
    auth: VaultHTTPAuth = .token("test-token"),
    tls: VaultTLSConfig = .system,
    timeout: Double = 10,
    wrapTTL: String? = nil,
    tracker: VaultLeaseTracker? = nil
) throws -> VaultHTTPClient {
    let url = URL(string: endpoint)!
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    let box = SessionBox(URLSession(configuration: config))
    let transport: VaultTransport = { request in
        let (data, response) = try await box.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
    return try VaultHTTPClient(
        endpoint: url, mount: mount, auth: auth, tls: tls,
        timeoutSeconds: timeout, transport: transport,
        wrapTTL: wrapTTL, tracker: tracker
    )
}

/// Mutable clock box for deterministic lease time-travel.
private final class ClockBox: Sendable {
    let mutex = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    func now() -> Date { mutex.withLock { $0 } }

    func advance(by seconds: Double) {
        mutex.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

private func makeTracker(
    policy: VaultLeasePolicy = VaultLeasePolicy(),
    jitterUnit: Double = 0
) -> (VaultLeaseTracker, ClockBox) {
    let box = ClockBox()
    let tracker = VaultLeaseTracker(
        policy: policy,
        clock: { box.now() },
        jitter: { jitterUnit }
    )
    return (tracker, box)
}

private func kvLeaseData(
    fields: String,
    leaseID: String? = "lease-1",
    renewable: Bool? = true,
    duration: Int? = 100
) -> Data {
    var top: [String] = []
    if let leaseID { top.append("\"lease_id\":\"\(leaseID)\"") }
    if let renewable { top.append("\"renewable\":\(renewable ? "true" : "false")") }
    if let duration { top.append("\"lease_duration\":\(duration)") }
    top.append("\"data\":{\"data\":{\(fields)}}")
    return Data("{\(top.joined(separator: ","))}".utf8)
}

private func wrapData(token: String = "wrapping-token-1", ttl: Int = 300) -> Data {
    Data("{\"wrap_info\":{\"token\":\"\(token)\",\"ttl\":\(ttl)}}".utf8)
}

private func renewData(
    leaseID: String = "lease-1",
    renewable: Bool = true,
    duration: Int = 200
) -> Data {
    Data(
        "{\"lease_id\":\"\(leaseID)\",\"renewable\":\(renewable ? "true" : "false"),\"lease_duration\":\(duration)}"
            .utf8
    )
}

private func healthData(
    version: String? = "1.15.0",
    sealedValue: Bool? = false,
    initialized: Bool? = true,
    standby: Bool? = false
) -> Data {
    var parts: [String] = []
    if let initialized { parts.append("\"initialized\":\(initialized ? "true" : "false")") }
    if let sealedValue { parts.append("\"sealed\":\(sealedValue ? "true" : "false")") }
    if let standby { parts.append("\"standby\":\(standby ? "true" : "false")") }
    if let version { parts.append("\"version\":\"\(version)\"") }
    return Data("{\(parts.joined(separator: ","))}".utf8)
}

private func loginData(token: String = "s.token", accessor: String = "acc-1", ttl: Int = 600) -> Data {
    Data(
        """
        {"auth":{"client_token":"\(token)","accessor":"\(accessor)","lease_duration":\(ttl)}}
        """.utf8
    )
}

private func kvData(_ fields: String, destroyed: Bool? = nil, deletionTime: String? = nil) -> Data {
    var meta: [String] = []
    if let destroyed { meta.append("\"destroyed\":\(destroyed ? "true" : "false")") }
    if let deletionTime { meta.append("\"deletion_time\":\"\(deletionTime)\"") }
    let metaJSON = meta.isEmpty ? "" : ",\"metadata\":{\(meta.joined(separator: ","))}"
    return Data("{\"data\":{\"data\":{\(fields)}\(metaJSON)}}".utf8)
}

private func healthyHandler(kvFields: String = "\"value\":\"s3cr3t\"") -> @Sendable (URLRequest) throws -> (Int, Data) {
    { request in
        let path = request.url?.path ?? ""
        if path == "/v1/sys/health" { return (200, healthData()) }
        if path.hasPrefix("/v1/secret/data/") { return (200, kvData(kvFields)) }
        return (404, Data("{\"errors\":[\"no handler\"]}".utf8))
    }
}

private func makeTempDir(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
}

private func writeApproleFile(at directory: URL, json: String, mode: Int = 0o600) throws {
    let url = directory.appendingPathComponent(VaultAppRoleStore.fileName)
    try json.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

private func makeDirectClient(throwing error: Error) throws -> VaultHTTPClient {
    let url = URL(string: "https://vault.example.com:8200")!
    let transport: VaultTransport = { _ in throw error }
    return try VaultHTTPClient(
        endpoint: url, mount: "secret", auth: .token("t"),
        tls: .system, timeoutSeconds: 10, transport: transport
    )
}

private func requestBody(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let chunk = 4096
    var buffer = [UInt8](repeating: 0, count: chunk)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: chunk)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

private func findVaultBinary() -> String? {
    let candidates = ["/usr/local/bin/vault", "/opt/homebrew/bin/vault", "/usr/bin/vault"]
    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
        return path
    }
    guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else { return nil }
    for dir in pathEnv.split(separator: ":").map(String.init) {
        let full = (dir as NSString).appendingPathComponent("vault")
        if FileManager.default.isExecutableFile(atPath: full) { return full }
    }
    return nil
}

#if os(macOS)
private final class FakeChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
#endif

@Suite("VaultHTTPClient", .serialized)
struct VaultHTTPClientTests {
    @Test func idIsVaultHTTP() throws {
        #expect(try makeClient().id == "vault-http")
    }

    @Test func versionParsesThreeParts() {
        #expect(VaultVersion(parsing: "1.15.0") == VaultVersion(major: 1, minor: 15, patch: 0))
        #expect(VaultVersion(parsing: "1.18.2")?.description == "1.18.2")
        #expect(VaultVersion(parsing: "0.0.0") == VaultVersion(major: 0, minor: 0, patch: 0))
    }

    @Test func versionParsesSuffixes() {
        #expect(VaultVersion(parsing: "v1.15.0") == VaultVersion(major: 1, minor: 15, patch: 0))
        #expect(VaultVersion(parsing: "V1.15.0") == VaultVersion(major: 1, minor: 15, patch: 0))
        #expect(VaultVersion(parsing: "1.15.0+ent") == VaultVersion(major: 1, minor: 15, patch: 0))
        #expect(VaultVersion(parsing: "1.15.0-beta1") == VaultVersion(major: 1, minor: 15, patch: 0))
        #expect(VaultVersion(parsing: "  1.15.0  ") == VaultVersion(major: 1, minor: 15, patch: 0))
        #expect(VaultVersion(parsing: "1.15") == VaultVersion(major: 1, minor: 15, patch: 0))
    }

    @Test func versionRejectsInvalid() {
        for text in ["", "v", "1", "a.b.c", "1.2.3.4", "1..3", "..", "1.2.x", "-1.2.3", "1.-2.3", " ", "v+ent"] {
            #expect(VaultVersion(parsing: text) == nil, "rejects \(text)")
        }
    }

    @Test func versionOrdersCorrectly() {
        let old = VaultVersion(major: 1, minor: 14, patch: 9)
        let min = VaultVersion.minimum
        let patch = VaultVersion(major: 1, minor: 15, patch: 1)
        let next = VaultVersion(major: 1, minor: 18, patch: 2)
        #expect(old < min)
        #expect(min < patch)
        #expect(patch < next)
        #expect((min < min) == false)
        #expect(min >= VaultVersion(major: 1, minor: 15, patch: 0))
    }

    @Test func minimumIs1150() {
        #expect(VaultHTTPClient.minimumVersion == VaultVersion(major: 1, minor: 15, patch: 0))
        #expect(VaultVersion.minimum.description == "1.15.0")
        #expect(VaultHTTPClient.maximumTokenTTLSeconds == 3_600)
    }

    @Test func tlsSystemMatchesAny() {
        #expect(VaultTLSConfig.system.matches(leafDER: Data([1, 2, 3])))
        #expect(VaultTLSConfig.system.matches(leafDER: Data()))
    }

    @Test func tlsPinnedMatchesExact() {
        let pinned = Data(repeating: 0xAB, count: 256)
        let config = VaultTLSConfig.pinnedLeafDER(pinned)
        #expect(config.matches(leafDER: pinned))
        #expect(config.matches(leafDER: Data(repeating: 0xAB, count: 255)) == false)
        #expect(config.matches(leafDER: Data(repeating: 0xAC, count: 256)) == false)
        #expect(config.matches(leafDER: Data()) == false)
    }

    @Test func authLabelNeverEchoes() {
        #expect(VaultHTTPAuth.token("hunter2-token").label == "token")
        #expect(VaultHTTPAuth.appRole(roleID: "role-1", secretID: "s3cr3t").label == "approle")
        #expect(VaultHTTPAuth.token("hunter2-token").label.contains("hunter2") == false)
        #expect(VaultHTTPAuth.appRole(roleID: "r", secretID: "s3cr3t").label.contains("s3cr3t") == false)
    }

    @Test func endpointRejectsMalformed() throws {
        for endpoint in [
            "ftp://vault.example.com:8200",
            "https://user:pass@vault.example.com:8200",
            "https://vault.example.com:8200?x=1",
            "https://vault.example.com:8200#frag",
            "https://vault.example.com/vault",
            "https:///v1/sys/health",
            "gopher://vault.example.com",
        ] {
            #expect(
                throws: VaultConfigurationError.invalidEndpoint,
                "rejects \(endpoint)"
            ) {
                try makeClient(endpoint: endpoint)
            }
        }
    }

    @Test func httpLoopbackAllowed() throws {
        for endpoint in ["http://127.0.0.1:8200", "http://localhost:8200", "http://[::1]:8200"] {
            let client = try makeClient(endpoint: endpoint)
            #expect(client.endpoint.absoluteString.hasPrefix("http://"))
        }
        let https = try makeClient(endpoint: "https://vault.example.com:8200")
        #expect(https.endpoint.scheme == "https")
    }

    @Test func endpointAcceptsUppercaseSchemeAndTrailingSlash() throws {
        let upper = try makeClient(endpoint: "HTTPS://vault.example.com:8200")
        #expect(upper.endpoint.scheme?.lowercased() == "https")
        let slashed = try makeClient(endpoint: "https://vault.example.com:8200/")
        #expect(slashed.endpoint.host == "vault.example.com")
        var parts = URLComponents()
        parts.scheme = "http"
        parts.host = "[::1]"
        parts.port = 8200
        let loopback = try #require(parts.url)
        #expect(loopback.host == "::1")
        try VaultHTTPClient.validate(endpoint: loopback)
    }

    @Test func httpNonLoopbackRejected() {
        for endpoint in ["http://vault.example.com:8200", "http://10.0.0.1:8200", "http://example.com"] {
            #expect(
                throws: VaultConfigurationError.httpNotAllowedForNonLoopback,
                "rejects \(endpoint)"
            ) {
                try makeClient(endpoint: endpoint)
            }
        }
    }

    @Test func mountValidation() throws {
        let good = try makeClient(mount: "my-mount_1/nested")
        #expect(good.mount == "my-mount_1/nested")
        for mount in ["", "/secret", "secret/", "a//b", ".", "..", "a/../b", "bad mount", "m\n", "m\0", "sécret"] {
            #expect(throws: VaultConfigurationError.invalidMount, "rejects \(mount)") {
                try makeClient(mount: mount)
            }
        }
    }

    @Test func emptyCredentialsRejected() {
        #expect(throws: VaultConfigurationError.emptyToken) {
            try makeClient(auth: .token(""))
        }
        #expect(throws: VaultConfigurationError.emptyRoleID) {
            try makeClient(auth: .appRole(roleID: "", secretID: "s"))
        }
        #expect(throws: VaultConfigurationError.emptySecretID) {
            try makeClient(auth: .appRole(roleID: "r", secretID: ""))
        }
    }

    @Test func pinValidation() throws {
        let ok = try makeClient(tls: .pinnedLeafDER(Data(repeating: 1, count: 256)))
        #expect(ok.tls.matches(leafDER: Data(repeating: 1, count: 256)))
        for count in [0, 1, 127, 16_385, 100_000] {
            #expect(throws: VaultConfigurationError.invalidPin, "rejects \(count) bytes") {
                try makeClient(tls: .pinnedLeafDER(Data(repeating: 2, count: count)))
            }
        }
    }

    @Test func timeoutValidation() {
        for timeout in [0.0, -1.0, Double.nan, Double.infinity, 61.0] {
            #expect(throws: VaultConfigurationError.invalidTimeout, "rejects \(timeout)") {
                try makeClient(timeout: timeout)
            }
        }
    }

    @Test func liveSystemInitSucceeds() throws {
        let live = try VaultHTTPClient(
            endpoint: URL(string: "https://vault.example.com:8200")!,
            auth: .token("root")
        )
        #expect(live.id == "vault-http")
        #expect(live.mount == "secret")
    }

    @Test func livePinnedPlatformBehavior() throws {
#if os(macOS)
        let pinned = Data(repeating: 9, count: 512)
        let live = try VaultHTTPClient(
            endpoint: URL(string: "https://vault.example.com:8200")!,
            auth: .token("root"), tls: .pinnedLeafDER(pinned)
        )
        #expect(live.tls == .pinnedLeafDER(pinned))
#else
        #expect(throws: VaultConfigurationError.pinningUnavailable) {
            try VaultHTTPClient(
                endpoint: URL(string: "https://vault.example.com:8200")!,
                auth: .token("root"),
                tls: .pinnedLeafDER(Data(repeating: 9, count: 512))
            )
        }
#endif
    }

    @Test func tokenResolvesValueKey() async throws {
        setStubHandler(healthyHandler(kvFields: "\"value\":\"s3cr3t\""))
        let client = try makeClient()
        let value = try await client.resolve(SecretRef(provider: "vault-http", item: "api/token"))
        #expect(value == .text("s3cr3t"))
        #expect(await client.health() == ProviderHealth(ok: true))
    }

    @Test func tokenResolvesSingleKey() async throws {
        setStubHandler(healthyHandler(kvFields: "\"token\":\"abc-123\""))
        let client = try makeClient()
        let value = try await client.resolve(SecretRef(provider: "vault-http", item: "deploy"))
        #expect(value == .text("abc-123"))
    }

    @Test func tokenResolvesField() async throws {
        setStubHandler(healthyHandler(kvFields: "\"public\":\"x\",\"private\":\"key-material\""))
        let client = try makeClient()
        let value = try await client.resolve(
            SecretRef(provider: "vault-http", item: "deploy", field: "private")
        )
        #expect(value == .text("key-material"))
    }

    @Test func scalarsStringify() async throws {
        setStubHandler(healthyHandler(kvFields: "\"n\":42,\"b\":true,\"d\":3.5"))
        let client = try makeClient()
        #expect(
            try await client.resolve(SecretRef(provider: "vault-http", item: "m", field: "n"))
                == .text("42")
        )
        #expect(
            try await client.resolve(SecretRef(provider: "vault-http", item: "m", field: "b"))
                == .text("true")
        )
        #expect(
            try await client.resolve(SecretRef(provider: "vault-http", item: "m", field: "d"))
                == .text("3.5")
        )
    }

    @Test func objectReencodesAsSortedJSON() async throws {
        setStubHandler(healthyHandler(kvFields: "\"cfg\":{\"b\":2,\"a\":1}"))
        let client = try makeClient()
        let value = try await client.resolve(
            SecretRef(provider: "vault-http", item: "app", field: "cfg")
        )
        #expect(value == .text("{\"a\":1,\"b\":2}"))
    }

    @Test func unicodeItemResolves() async throws {
        setStubHandler(healthyHandler(kvFields: "\"value\":\"uni-ok\""))
        let client = try makeClient()
        let value = try await client.resolve(
            SecretRef(provider: "vault-http", item: "tökén-🔑-名前")
        )
        #expect(value == .text("uni-ok"))
        let urls = recordedRequests().compactMap(\.url?.absoluteString)
        #expect(urls.contains(where: { $0.contains("/v1/secret/data/") }))
        #expect(urls.allSatisfy { $0.contains("uni-ok") == false })
    }

    @Test func dotToolNameAndSlashesNormalize() async throws {
        setStubHandler(healthyHandler(kvFields: "\"value\":\"dot-ok\""))
        let client = try makeClient()
        #expect(
            try await client.resolve(SecretRef(provider: "vault-http", item: "my.tool.v2"))
                == .text("dot-ok")
        )
        #expect(
            try await client.resolve(SecretRef(provider: "vault-http", item: "/a/b/"))
                == .text("dot-ok")
        )
        let paths = recordedRequests().compactMap(\.url?.path)
        #expect(paths.contains("/v1/secret/data/my.tool.v2"))
        #expect(paths.contains("/v1/secret/data/a/b"))
    }

    @Test func missingFieldIsNotFound() async throws {
        setStubHandler(healthyHandler(kvFields: "\"public\":\"x\""))
        let client = try makeClient()
        await #expect(throws: SecretsError.notFound("vault-http")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "d", field: "private"))
        }
    }

    @Test func ambiguousWithoutFieldIsNotFound() async throws {
        setStubHandler(healthyHandler(kvFields: "\"a\":\"1\",\"b\":\"2\""))
        let client = try makeClient()
        await #expect(throws: SecretsError.notFound("vault-http")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "multi"))
        }
    }

    @Test func destroyedAndDeletedAreNotFound() async throws {
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (200, kvData("\"value\":\"x\"", destroyed: true))
        }
        let client = try makeClient()
        await #expect(throws: SecretsError.notFound("vault-http")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "gone"))
        }
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (200, kvData("\"value\":\"x\"", deletionTime: "2026-01-01T00:00:00Z"))
        }
        await #expect(throws: SecretsError.notFound("vault-http")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "gone"))
        }
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (200, kvData("\"k\":null"))
        }
        await #expect(throws: SecretsError.notFound("vault-http")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "gone", field: "k"))
        }
    }

    @Test func kv404IsNotFound() async throws {
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (404, Data("{\"errors\":[\"not found\"]}".utf8))
        }
        let client = try makeClient()
        await #expect(throws: SecretsError.notFound("vault-http")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "absent"))
        }
    }

    @Test func kv400IsInvalidRef() async throws {
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (400, Data("{\"errors\":[\"bad request\"]}".utf8))
        }
        let client = try makeClient()
        await #expect(throws: SecretsError.invalidRef("vault-http")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "bad"))
        }
    }

    @Test func providerMismatchMakesNoRequest() async throws {
        setStubHandler(healthyHandler())
        let client = try makeClient()
        await #expect(throws: SecretsError.invalidRef("vault-http")) {
            try await client.resolve(SecretRef(provider: "file", item: "x"))
        }
        #expect(recordedRequests().isEmpty)
    }

    @Test func hostileItemsRejectedWithoutRequest() async throws {
        setStubHandler(healthyHandler())
        let client = try makeClient()
        for item in ["a\0b", "a//b", "..", "a/../b", "/", ".", "a/./b"] {
            await #expect(throws: SecretsError.invalidRef("vault-http"), "rejects \(item)") {
                try await client.resolve(SecretRef(provider: "vault-http", item: item))
            }
        }
        #expect(recordedRequests().isEmpty)
    }

    @Test func sealedHealthIsSealed() async throws {
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" {
                return (503, healthData(sealedValue: true))
            }
            return (200, kvData("\"value\":\"x\""))
        }
        let client = try makeClient()
        await #expect(throws: SecretsError.providerDown("vault-http:sealed")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
        #expect(await client.health() == ProviderHealth(ok: false))
    }

    @Test func sealedKVRaceIsSealed() async throws {
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (503, Data("{\"errors\":[\"Vault is sealed\"]}".utf8))
        }
        let client = try makeClient()
        await #expect(throws: SecretsError.providerDown("vault-http:sealed")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
    }

    @Test func uninitializedHealthIsUninitialized() async throws {
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (501, Data("{}".utf8)) }
            return (200, kvData("\"value\":\"x\""))
        }
        let client = try makeClient()
        await #expect(throws: SecretsError.providerDown("vault-http:uninitialized")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
        #expect(await client.health() == ProviderHealth(ok: false))
    }

    @Test func uninitializedKVRaceIsUninitialized() async throws {
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (501, Data("{}".utf8))
        }
        let client = try makeClient()
        await #expect(throws: SecretsError.providerDown("vault-http:uninitialized")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
    }

    @Test func forbiddenMapsToForbidden() async throws {
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (403, Data("{}".utf8)) }
            return (200, kvData("\"value\":\"x\""))
        }
        let client = try makeClient()
        await #expect(throws: SecretsError.providerDown("vault-http:forbidden")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (403, Data("{\"errors\":[\"permission denied\"]}".utf8))
        }
        await #expect(throws: SecretsError.providerDown("vault-http:forbidden")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (401, Data("{}".utf8))
        }
        await #expect(throws: SecretsError.providerDown("vault-http:forbidden")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
    }

    @Test func rateLimitedMapsToRateLimited() async throws {
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (429, Data("{}".utf8)) }
            return (200, kvData("\"value\":\"x\""))
        }
        let client = try makeClient()
        await #expect(throws: SecretsError.providerDown("vault-http:rateLimited")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (429, Data("{}".utf8))
        }
        await #expect(throws: SecretsError.providerDown("vault-http:rateLimited")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
    }

    @Test func standbyMapsToStandby() async throws {
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" {
                return (429, healthData(standby: true))
            }
            return (200, kvData("\"value\":\"x\""))
        }
        let client = try makeClient()
        await #expect(throws: SecretsError.providerDown("vault-http:standby")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (307, Data("{}".utf8))
        }
        await #expect(throws: SecretsError.providerDown("vault-http:standby")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (472, Data("{}".utf8)) }
            return (200, kvData("\"value\":\"x\""))
        }
        await #expect(throws: SecretsError.providerDown("vault-http:standby")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
        for status in [472, 473] {
            setStubHandler { request in
                if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
                return (status, Data("{}".utf8))
            }
            await #expect(throws: SecretsError.providerDown("vault-http:standby"), "kv \(status) is standby") {
                try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
            }
        }
    }

    @Test func versionOldRejected() async throws {
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData(version: "1.14.9")) }
            return (200, kvData("\"value\":\"x\""))
        }
        let client = try makeClient()
        await #expect(throws: SecretsError.providerDown("vault-http:version")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
        #expect(await client.health() == ProviderHealth(ok: false))
    }

    @Test func versionMissingInvalidRejected() async throws {
        for version in [nil, "not-a-version", ""] {
            setStubHandler { request in
                if request.url?.path == "/v1/sys/health" {
                    return (200, healthData(version: version))
                }
                return (200, kvData("\"value\":\"x\""))
            }
            let client = try makeClient()
            await #expect(throws: SecretsError.providerDown("vault-http:version")) {
                try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
            }
        }
        for version in ["1.15.0", "1.15.1", "1.18.2", "v1.15.0+ent"] {
            setStubHandler { request in
                if request.url?.path == "/v1/sys/health" {
                    return (200, healthData(version: version))
                }
                return (200, kvData("\"value\":\"ok\""))
            }
            let client = try makeClient()
            #expect(
                try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
                    == .text("ok")
            )
        }
    }

    @Test func healthDecodeFailure() async throws {
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, Data("{not json".utf8)) }
            return (200, kvData("\"value\":\"x\""))
        }
        let client = try makeClient()
        await #expect(throws: SecretsError.providerDown("vault-http:decode")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (200, Data("{not json".utf8))
        }
        await #expect(throws: SecretsError.providerDown("vault-http:decode")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (200, Data("{\"data\":{}}".utf8))
        }
        await #expect(throws: SecretsError.providerDown("vault-http:decode")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
    }

    @Test func serverErrorsMapToServer() async throws {
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (500, Data("{}".utf8)) }
            return (200, kvData("\"value\":\"x\""))
        }
        let client = try makeClient()
        await #expect(throws: SecretsError.providerDown("vault-http:server")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (502, Data("{}".utf8))
        }
        await #expect(throws: SecretsError.providerDown("vault-http:server")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (418, Data("{}".utf8))
        }
        await #expect(throws: SecretsError.providerDown("vault-http:server")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
    }

    @Test func unreachableMapsToUnreachable() async throws {
        for code: URLError.Code in [.cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet] {
            setStubHandler { _ in throw URLError(code) }
            let client = try makeClient()
            await #expect(
                throws: SecretsError.providerDown("vault-http:unreachable"),
                "maps \(code)"
            ) {
                try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
            }
            #expect(await client.health() == ProviderHealth(ok: false))
        }
        struct Foreign: Error {}
        setStubHandler { _ in throw Foreign() }
        let client = try makeClient()
        await #expect(throws: SecretsError.providerDown("vault-http:unreachable")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
    }

    @Test func tlsMapsToTLS() async throws {
        for code: URLError.Code in [.serverCertificateUntrusted, .secureConnectionFailed, .serverCertificateHasBadDate] {
            setStubHandler { _ in throw URLError(code) }
            let client = try makeClient()
            await #expect(throws: SecretsError.providerDown("vault-http:tls"), "maps \(code)") {
                try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
            }
        }
    }

    @Test func timeoutMapsToTimeout() async throws {
        setStubHandler { _ in throw URLError(.timedOut) }
        let client = try makeClient()
        await #expect(throws: SecretsError.timeout("vault-http")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
    }

    @Test func cancellationPropagates() async throws {
        let client = try makeDirectClient(throwing: CancellationError())
        await #expect(throws: CancellationError.self) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
    }

    @Test func secretsErrorPassthrough() async throws {
        let client = try makeDirectClient(throwing: SecretsError.policyDenied)
        await #expect(throws: SecretsError.policyDenied) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
    }

    @Test func appRoleLoginSuccessUsesMintedToken() async throws {
        setStubHandler { request in
            let path = request.url?.path ?? ""
            if path == "/v1/sys/health" { return (200, healthData()) }
            if path == "/v1/auth/approle/login" {
                return (200, loginData(token: "s.minted", accessor: "acc-9", ttl: 600))
            }
            if path.hasPrefix("/v1/secret/data/") { return (200, kvData("\"value\":\"via-approle\"")) }
            return (404, Data("{}".utf8))
        }
        let client = try makeClient(auth: .appRole(roleID: "role-1", secretID: "secret-1"))
        let value = try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        #expect(value == .text("via-approle"))
        let requests = recordedRequests()
        #expect(requests.count == 3)
        let login = try #require(requests.first { $0.url?.path == "/v1/auth/approle/login" })
        #expect(login.httpMethod == "POST")
        #expect(login.value(forHTTPHeaderField: "X-Vault-Token") == nil)
        let body = try #require(requestBody(login).flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.contains("role-1"))
        #expect(body.contains("secret-1"))
        let kv = try #require(requests.first { ($0.url?.path ?? "").hasPrefix("/v1/secret/data/") })
        #expect(kv.value(forHTTPHeaderField: "X-Vault-Token") == "s.minted")
    }

    @Test func appRoleBadCredentialsAreAuth() async throws {
        for status in [400, 404] {
            setStubHandler { request in
                if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
                if request.url?.path == "/v1/auth/approle/login" { return (status, Data("{}".utf8)) }
                return (200, kvData("\"value\":\"x\""))
            }
            let client = try makeClient(auth: .appRole(roleID: "r", secretID: "bad"))
            await #expect(throws: SecretsError.providerDown("vault-http:auth")) {
                try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
            }
        }
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            if request.url?.path == "/v1/auth/approle/login" { return (403, Data("{}".utf8)) }
            return (200, kvData("\"value\":\"x\""))
        }
        let forbidden = try makeClient(auth: .appRole(roleID: "r", secretID: "s"))
        await #expect(throws: SecretsError.providerDown("vault-http:forbidden")) {
            try await forbidden.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
    }

    @Test func login401IsForbidden() async throws {
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            if request.url?.path == "/v1/auth/approle/login" { return (401, Data("{}".utf8)) }
            return (200, kvData("\"value\":\"must-not-read\""))
        }
        let client = try makeClient(auth: .appRole(roleID: "r", secretID: "s"))
        await #expect(throws: SecretsError.providerDown("vault-http:forbidden")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
        let paths = recordedRequests().compactMap(\.url?.path)
        #expect(paths.allSatisfy { $0.hasPrefix("/v1/secret/data/") == false })
    }

    @Test func appRoleMissingTokenAccessorTTLAreAuth() async throws {
        let bodies = [
            "{\"auth\":{\"client_token\":\"\",\"accessor\":\"a\",\"lease_duration\":600}}",
            "{\"auth\":{\"client_token\":\"t\",\"accessor\":\"\",\"lease_duration\":600}}",
            "{\"auth\":{\"client_token\":\"t\",\"accessor\":\"a\",\"lease_duration\":0}}",
            "{\"auth\":{\"client_token\":\"t\",\"accessor\":\"a\",\"lease_duration\":3601}}",
            "{\"auth\":{\"client_token\":\"t\",\"accessor\":\"a\",\"lease_duration\":-5}}",
            "{}",
            "{not json",
        ]
        for body in bodies {
            setStubHandler { request in
                if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
                if request.url?.path == "/v1/auth/approle/login" {
                    return (200, Data(body.utf8))
                }
                return (200, kvData("\"value\":\"x\""))
            }
            let client = try makeClient(auth: .appRole(roleID: "r", secretID: "s"))
            await #expect(throws: SecretsError.providerDown("vault-http:auth"), "rejects \(body)") {
                try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
            }
        }
    }

    @Test func appRoleTTLEdgesAccepted() async throws {
        for ttl in [1, 3_600] {
            setStubHandler { request in
                if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
                if request.url?.path == "/v1/auth/approle/login" {
                    return (200, loginData(ttl: ttl))
                }
                return (200, kvData("\"value\":\"ok\""))
            }
            let client = try makeClient(auth: .appRole(roleID: "r", secretID: "s"))
            #expect(
                try await client.resolve(SecretRef(provider: "vault-http", item: "x")) == .text("ok"),
                "accepts ttl \(ttl)"
            )
        }
    }

    @Test func appRoleFailureMakesNoKVRequest() async throws {
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            if request.url?.path == "/v1/auth/approle/login" { return (400, Data("{}".utf8)) }
            return (200, kvData("\"value\":\"must-not-read\""))
        }
        let client = try makeClient(auth: .appRole(roleID: "r", secretID: "bad"))
        await #expect(throws: SecretsError.providerDown("vault-http:auth")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
        let paths = recordedRequests().compactMap(\.url?.path)
        #expect(paths.contains("/v1/sys/health"))
        #expect(paths.contains("/v1/auth/approle/login"))
        #expect(paths.allSatisfy { $0.hasPrefix("/v1/secret/data/") == false })
    }

    @Test func tokenMakesNoLoginRequest() async throws {
        setStubHandler(healthyHandler())
        let client = try makeClient(auth: .token("direct-token"))
        _ = try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        let paths = recordedRequests().compactMap(\.url?.path)
        #expect(paths.contains("/v1/sys/health"))
        #expect(paths.contains(where: { $0.hasPrefix("/v1/secret/data/") }))
        #expect(paths.contains("/v1/auth/approle/login") == false)
    }

    @Test func precheckFailureMakesNoLoginOrKV() async throws {
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (503, healthData(sealedValue: true)) }
            return (200, kvData("\"value\":\"must-not-read\""))
        }
        let client = try makeClient(auth: .appRole(roleID: "r", secretID: "s"))
        await #expect(throws: SecretsError.providerDown("vault-http:sealed")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
        #expect(recordedRequests().count == 1)
        #expect(recordedRequests().first?.url?.path == "/v1/sys/health")
    }

    @Test func headersAndURLsNeverCarrySecrets() async throws {
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            if request.url?.path == "/v1/auth/approle/login" {
                return (200, loginData(token: "s.minted", accessor: "a", ttl: 60))
            }
            return (200, kvData("\"value\":\"P@ssw0rd!\""))
        }
        let client = try makeClient(auth: .appRole(roleID: "role-9", secretID: "secret-9"))
        _ = try await client.resolve(SecretRef(provider: "vault-http", item: "api/key"))
        for request in recordedRequests() {
            #expect(request.value(forHTTPHeaderField: "X-Vault-Wrap-TTL") == nil)
            let url = request.url?.absoluteString ?? ""
            #expect(url.contains("s.minted") == false)
            #expect(url.contains("secret-9") == false)
            #expect(url.contains("role-9") == false)
            #expect(url.contains("P@ssw0rd!") == false)
        }
        let health = try #require(recordedRequests().first { $0.url?.path == "/v1/sys/health" })
        #expect(health.value(forHTTPHeaderField: "X-Vault-Token") == nil)
        #expect(health.httpShouldHandleCookies == false)
        let kv = try #require(recordedRequests().first { ($0.url?.path ?? "").hasPrefix("/v1/secret/data/") })
        #expect(kv.value(forHTTPHeaderField: "X-Vault-Token") == "s.minted")
    }

    @Test func errorsNeverEchoSecrets() async throws {
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (403, Data("{\"errors\":[\"hunter2token P@ssw0rd! super-secret-item\"]}".utf8))
        }
        let client = try makeClient(auth: .token("hunter2token"))
        do {
            _ = try await client.resolve(
                SecretRef(provider: "vault-http", item: "super-secret-item", field: "password-field")
            )
            Issue.record("expected forbidden")
        } catch {
            let text = String(describing: error)
            #expect(text.contains("hunter2token") == false)
            #expect(text.contains("P@ssw0rd!") == false)
            #expect(text.contains("super-secret-item") == false)
            #expect(text.contains("password-field") == false)
            #expect(text.contains("vault-http:forbidden"))
        }
        setStubHandler { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await client.resolve(SecretRef(provider: "vault-http", item: "super-secret-item"))
            Issue.record("expected unreachable")
        } catch {
            #expect(String(describing: error).contains("super-secret-item") == false)
        }
    }

    @Test func healthTrueAndFalse() async throws {
        setStubHandler { _ in (200, healthData(version: "1.18.2")) }
        let good = try makeClient()
        #expect(await good.health() == ProviderHealth(ok: true, identity: nil))
        let down: [(Int, Data)] = [
            (503, healthData(sealedValue: true)),
            (501, Data("{}".utf8)),
            (429, Data("{}".utf8)),
            (429, healthData(standby: true)),
            (403, Data("{}".utf8)),
            (500, Data("{}".utf8)),
            (418, Data("{}".utf8)),
            (200, healthData(version: "1.14.0")),
            (200, Data("{bad".utf8)),
        ]
        for (status, body) in down {
            setStubHandler { _ in (status, body) }
            #expect(await good.health() == ProviderHealth(ok: false), "unhealthy for \(status)")
        }
        setStubHandler { _ in throw URLError(.timedOut) }
        #expect(await good.health() == ProviderHealth(ok: false))
        setStubHandler { _ in throw CancellationError() }
        #expect(await good.health() == ProviderHealth(ok: false))
        setStubHandler { _ in throw SecretsError.timeout("vault-http") }
        #expect(await good.health() == ProviderHealth(ok: false))
    }

    @Test func oversizedBodiesFailClosed() async throws {
        let big = Data(repeating: 0x61, count: VaultHTTPClient.maximumResponseBytes + 1)
        setStubHandler { _ in (200, big) }
        let client = try makeClient()
        #expect(await client.health() == ProviderHealth(ok: false))
        await #expect(throws: SecretsError.oversized("vault-http")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            if request.url?.path == "/v1/auth/approle/login" { return (200, big) }
            return (200, kvData("\"value\":\"x\""))
        }
        let approle = try makeClient(auth: .appRole(roleID: "r", secretID: "s"))
        await #expect(throws: SecretsError.oversized("vault-http")) {
            try await approle.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (200, big)
        }
        await #expect(throws: SecretsError.oversized("vault-http")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
    }

    @Test func appRoleStoreValidAndTrim() throws {
        let dir = try makeTempDir(prefix: "rv-vault-approle")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeApproleFile(at: dir, json: #"{"version":1,"role_id":"role-1","secret_id":"secret-1"}"#)
        #expect(
            VaultAppRoleStore.load(from: dir)
                == .success(.appRole(roleID: "role-1", secretID: "secret-1"))
        )
        try writeApproleFile(
            at: dir, json: #"{"version":1,"role_id":"  role-2\n","secret_id":"\nsecret-2  "}"#
        )
        #expect(
            VaultAppRoleStore.load(from: dir)
                == .success(.appRole(roleID: "role-2", secretID: "secret-2"))
        )
    }

    @Test func appRoleStoreMissingIsUnreadable() throws {
        let dir = try makeTempDir(prefix: "rv-vault-approle")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(VaultAppRoleStore.load(from: dir) == .failure(.unreadable))
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-vault-approle-missing-\(UUID().uuidString)")
        #expect(VaultAppRoleStore.load(from: missing) == .failure(.unreadable))
    }

    @Test func appRoleStoreFileAsDirectoryIsUnreadable() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-vault-approle-fileasdir-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(VaultAppRoleStore.load(from: file) == .failure(.unreadable))
    }

    @Test func appRoleStoreUnsafePerms() throws {
        let dir = try makeTempDir(prefix: "rv-vault-approle")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeApproleFile(
            at: dir, json: #"{"version":1,"role_id":"r","secret_id":"s"}"#, mode: 0o640
        )
        #expect(VaultAppRoleStore.load(from: dir) == .failure(.unsafeLocation))
        try writeApproleFile(at: dir, json: #"{"version":1,"role_id":"r","secret_id":"s"}"#)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: dir.path)
        #expect(VaultAppRoleStore.load(from: dir) == .failure(.unsafeLocation))
    }

    @Test func appRoleStoreInvalidDocs() throws {
        let dir = try makeTempDir(prefix: "rv-vault-approle")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeApproleFile(at: dir, json: String(repeating: "x", count: 5_000))
        #expect(VaultAppRoleStore.load(from: dir) == .failure(.oversized))
        try writeApproleFile(at: dir, json: "{not json")
        #expect(VaultAppRoleStore.load(from: dir) == .failure(.invalidDocument))
        try writeApproleFile(
            at: dir, json: #"{"version":1,"role_id":"r","secret_id":"s","smuggled":"hunter2"}"#
        )
        #expect(VaultAppRoleStore.load(from: dir) == .failure(.invalidDocument))
        try writeApproleFile(at: dir, json: #"{"version":1,"role_id":"","secret_id":"s"}"#)
        #expect(VaultAppRoleStore.load(from: dir) == .failure(.invalidDocument))
        try writeApproleFile(at: dir, json: #"{"version":1,"role_id":"   ","secret_id":"s"}"#)
        #expect(VaultAppRoleStore.load(from: dir) == .failure(.invalidDocument))
        let long = String(repeating: "r", count: 3_000)
        try writeApproleFile(at: dir, json: #"{"version":1,"role_id":"\#(long)","secret_id":"s"}"#)
        #expect(VaultAppRoleStore.load(from: dir) == .failure(.invalidDocument))
        try writeApproleFile(at: dir, json: #"{"version":2,"role_id":"r","secret_id":"s"}"#)
        #expect(VaultAppRoleStore.load(from: dir) == .failure(.unsupportedVersion))
        #expect(
            VaultAppRoleStore.decode(Data(repeating: 0x61, count: 5_000)) == .failure(.oversized)
        )
    }

    @Test func appRoleStoreSymlinkDenied() throws {
        let dir = try makeTempDir(prefix: "rv-vault-approle")
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("real.json")
        try #"{"version":1,"role_id":"r","secret_id":"s"}"#.write(
            to: target, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent(VaultAppRoleStore.fileName),
            withDestinationURL: target
        )
        #expect(VaultAppRoleStore.load(from: dir) == .failure(.unreadable))
    }

    @Test func concurrentResolvesAllSucceed() async throws {
        setStubHandler(healthyHandler(kvFields: "\"value\":\"parallel-ok\""))
        let client = try makeClient()
        let ref = try SecretRef(provider: "vault-http", item: "shared")
        let results = await withTaskGroup(of: SecretValue.self, returning: [SecretValue].self) { group in
            for _ in 0..<50 {
                group.addTask { (try? await client.resolve(ref)) ?? .text("FAILED") }
            }
            var collected: [SecretValue] = []
            for await value in group { collected.append(value) }
            return collected
        }
        #expect(results.count == 50)
        #expect(results.allSatisfy { $0 == .text("parallel-ok") })
    }

    @Test func liveDevRoundtripIfAvailableElseSkip() async throws {
        guard let vault = findVaultBinary() else {
            let live = try VaultHTTPClient(
                endpoint: URL(string: "http://127.0.0.1:8200")!,
                auth: .token("root")
            )
            #expect(live.id == "vault-http")
            return
        }
        let port = 18_200 + Int.random(in: 0..<400)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: vault)
        process.arguments = [
            "server", "-dev",
            "-dev-root-token-id=root",
            "-dev-listen-address=127.0.0.1:\(port)",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }
        let live = try VaultHTTPClient(
            endpoint: URL(string: "http://127.0.0.1:\(port)")!,
            auth: .token("root"), timeoutSeconds: 2
        )
        var healthy = false
        for _ in 0..<50 {
            if await live.health().ok {
                healthy = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(healthy)
    }

    @Test func versionTwoPartPatchZero() {
        let parsed = VaultVersion(parsing: "1.15")
        #expect(parsed == VaultVersion(major: 1, minor: 15, patch: 0))
        #expect(parsed?.description == "1.15.0")
    }

    @Test func loginTransportThrowsMapped() async throws {
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            throw URLError(.cannotConnectToHost)
        }
        let unreachable = try makeClient(auth: .appRole(roleID: "r", secretID: "s"))
        await #expect(throws: SecretsError.providerDown("vault-http:unreachable")) {
            try await unreachable.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
        let url = URL(string: "https://vault.example.com:8200")!
        let cancelled: VaultTransport = { request in
            if request.url?.path == "/v1/sys/health" {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!
                return (healthData(), response)
            }
            throw CancellationError()
        }
        let cancelling = try VaultHTTPClient(
            endpoint: url, mount: "secret", auth: .appRole(roleID: "r", secretID: "s"),
            tls: .system, timeoutSeconds: 10, transport: cancelled
        )
        await #expect(throws: CancellationError.self) {
            try await cancelling.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
        let denied: VaultTransport = { request in
            if request.url?.path == "/v1/sys/health" {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!
                return (healthData(), response)
            }
            throw SecretsError.policyDenied
        }
        let passing = try VaultHTTPClient(
            endpoint: url, mount: "secret", auth: .appRole(roleID: "r", secretID: "s"),
            tls: .system, timeoutSeconds: 10, transport: denied
        )
        await #expect(throws: SecretsError.policyDenied) {
            try await passing.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
    }

    @Test func kvTransportThrowsMapped() async throws {
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            throw URLError(.dnsLookupFailed)
        }
        let client = try makeClient()
        await #expect(throws: SecretsError.providerDown("vault-http:unreachable")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
        let url = URL(string: "https://vault.example.com:8200")!
        let cancelled: VaultTransport = { request in
            if request.url?.path == "/v1/sys/health" {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!
                return (healthData(), response)
            }
            throw CancellationError()
        }
        let cancelling = try VaultHTTPClient(
            endpoint: url, mount: "secret", auth: .token("t"),
            tls: .system, timeoutSeconds: 10, transport: cancelled
        )
        await #expect(throws: CancellationError.self) {
            try await cancelling.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
        let denied: VaultTransport = { request in
            if request.url?.path == "/v1/sys/health" {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!
                return (healthData(), response)
            }
            throw SecretsError.policyDenied
        }
        let passing = try VaultHTTPClient(
            endpoint: url, mount: "secret", auth: .token("t"),
            tls: .system, timeoutSeconds: 10, transport: denied
        )
        await #expect(throws: SecretsError.policyDenied) {
            try await passing.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
    }

    @Test func loginStatusMappings() async throws {
        let cases: [(Int, SecretsError)] = [
            (429, .providerDown("vault-http:rateLimited")),
            (501, .providerDown("vault-http:uninitialized")),
            (503, .providerDown("vault-http:sealed")),
            (307, .providerDown("vault-http:standby")),
            (472, .providerDown("vault-http:standby")),
            (473, .providerDown("vault-http:standby")),
            (500, .providerDown("vault-http:server")),
            (418, .providerDown("vault-http:server")),
        ]
        for (status, error) in cases {
            setStubHandler { request in
                if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
                if request.url?.path == "/v1/auth/approle/login" {
                    return (status, Data("{}".utf8))
                }
                return (200, kvData("\"value\":\"x\""))
            }
            let client = try makeClient(auth: .appRole(roleID: "r", secretID: "s"))
            await #expect(throws: error, "login \(status)") {
                try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
            }
        }
    }

    @Test func health200DefensiveFlags() async throws {
        setStubHandler { _ in (200, healthData(initialized: false)) }
        let client = try makeClient()
        await #expect(throws: SecretsError.providerDown("vault-http:uninitialized")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
        setStubHandler { _ in (200, healthData(sealedValue: true)) }
        await #expect(throws: SecretsError.providerDown("vault-http:sealed")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
        setStubHandler { _ in (200, healthData(standby: true)) }
        await #expect(throws: SecretsError.providerDown("vault-http:standby")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
    }

    @Test func arrayValueReencodes() async throws {
        setStubHandler(healthyHandler(kvFields: "\"list\":[1,\"two\",true]"))
        let client = try makeClient()
        let value = try await client.resolve(
            SecretRef(provider: "vault-http", item: "app", field: "list")
        )
        #expect(value == .text("[1,\"two\",true]"))
    }

    @Test func allTypesRoundTrip() async throws {
        setStubHandler(healthyHandler(
            kvFields: "\"o\":{\"s\":\"x\",\"i\":1,\"d\":2.5,\"b\":false,\"n\":null,\"a\":[1],\"o\":{\"k\":\"v\"}}"
        ))
        let client = try makeClient()
        let value = try await client.resolve(
            SecretRef(provider: "vault-http", item: "app", field: "o")
        )
        #expect(value == .text("{\"a\":[1],\"b\":false,\"d\":2.5,\"i\":1,\"n\":null,\"o\":{\"k\":\"v\"},\"s\":\"x\"}"))
    }

    @Test func jsonValueDirect() {
        #expect(VaultJSONValue.string("a").stringified() == "a")
        #expect(VaultJSONValue.int(-3).stringified() == "-3")
        #expect(VaultJSONValue.double(2.5).stringified() == "2.5")
        #expect(VaultJSONValue.bool(true).stringified() == "true")
        #expect(VaultJSONValue.bool(false).stringified() == "false")
        #expect(VaultJSONValue.null.stringified() == nil)
        #expect(VaultJSONValue.array([.int(1)]).stringified() == "[1]")
        #expect(VaultJSONValue.object(["k": .string("v")]).stringified() == "{\"k\":\"v\"}")
    }

    @Test func selectValueFieldWithUnencodableObjectIsProviderDown() {
        #expect(throws: SecretsError.providerDown("vault-http:decode")) {
            try VaultHTTPClient.selectValue(
                values: ["f": .object(["x": .double(.nan)])], field: "f"
            )
        }
    }

    @Test func selectValueKeyWithUnencodableObjectIsProviderDown() {
        #expect(throws: SecretsError.providerDown("vault-http:decode")) {
            try VaultHTTPClient.selectValue(
                values: ["value": .object(["x": .double(.nan)])], field: nil
            )
        }
    }

    @Test func stringifiedUnencodableObjectIsNil() {
        #expect(VaultJSONValue.object(["x": .double(.nan)]).stringified() == nil)
    }

    @Test func approleKeyRejectsInt() {
        #expect(VaultAppRoleKey(intValue: 0) == nil)
        #expect(VaultAppRoleKey(intValue: 99) == nil)
        #expect(VaultAppRoleKey(stringValue: "version")?.stringValue == "version")
        #expect(VaultAppRoleKey("role_id").stringValue == "role_id")
    }

#if os(macOS)
    @Test func pinningDelegateCancelsWithoutTrust() {
        let delegate = VaultPinningDelegate(pinned: Data(repeating: 7, count: 256))
        let protection = URLProtectionSpace(
            host: "vault.example.com", port: 443, protocol: "https",
            realm: nil, authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: protection, proposedCredential: nil,
            previousFailureCount: 0, failureResponse: nil,
            error: nil, sender: FakeChallengeSender()
        )
        var disposition: URLSession.AuthChallengeDisposition?
        delegate.urlSession(URLSession.shared, didReceive: challenge) { kind, _ in
            disposition = kind
        }
        #expect(disposition == .cancelAuthenticationChallenge)
    }

    @Test func pinningDelegateRefusesRedirects() {
        let delegate = VaultPinningDelegate(pinned: Data(repeating: 7, count: 256))
        #expect(vaultRedirectForwarded(delegate: delegate) == nil)
    }
#endif

    @Test func systemDelegateRefusesRedirects() {
        #expect(vaultRedirectForwarded(delegate: VaultNoRedirectDelegate()) == nil)
    }

    @Test func versionIntOverflowFailsClosed() {
        #expect(VaultVersion(parsing: "9999999999999999999.15") == nil)
        #expect(VaultVersion(parsing: "1.9999999999999999999") == nil)
        #expect(VaultVersion(parsing: "1.15.9999999999999999999") == nil)
    }

    @Test func versionMajorDiffersOrdersByMajor() {
        #expect(VaultVersion(major: 1, minor: 99, patch: 99) < VaultVersion(major: 2, minor: 0, patch: 0))
        #expect((VaultVersion(major: 2, minor: 0, patch: 0) < VaultVersion(major: 1, minor: 99, patch: 99)) == false)
    }

    @Test func trailingSlashEndpointStripsInJoining() async throws {
        setStubHandler(healthyHandler(kvFields: "\"value\":\"slash-ok\""))
        let client = try makeClient(endpoint: "https://vault.example.com:8200/")
        let value = try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        #expect(value == .text("slash-ok"))
        let paths = recordedRequests().compactMap(\.url?.path)
        #expect(paths.contains("/v1/sys/health"))
    }

    @Test func joiningFallsBackToEndpointOnGarbage() throws {
        let client = try makeClient()
        #expect(client.joining(":not-a-port") == client.endpoint)
    }

    @Test func appRolePartialAuthObjectDefaultsAreAuth() async throws {
        let bodies = [
            #"{"auth":{}}"#,
            #"{"auth":{"client_token":1,"accessor":true,"lease_duration":"x"}}"#,
        ]
        for body in bodies {
            setStubHandler { request in
                if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
                if request.url?.path == "/v1/auth/approle/login" {
                    return (200, Data(body.utf8))
                }
                return (200, kvData("\"value\":\"x\""))
            }
            let client = try makeClient(auth: .appRole(roleID: "r", secretID: "s"))
            await #expect(throws: SecretsError.providerDown("vault-http:auth"), "rejects \(body)") {
                try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
            }
        }
    }

    @Test func unsupportedJSONValueThrowsDataCorrupted() throws {
        #expect(throws: DecodingError.self) {
            try VaultJSONValue(from: WaveDUnsupportedValueDecoder())
        }
        #expect(try JSONDecoder().decode(VaultJSONValue.self, from: Data("1".utf8)) == .int(1))
    }

    // MARK: - T6b leases, renewal, wrap

    @Test func leasedValueServedFromCache() async throws {
        let (tracker, _) = makeTracker()
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (200, kvLeaseData(fields: "\"value\":\"leased-secret\"", duration: 100))
        }
        let client = try makeClient(tracker: tracker)
        let ref = try SecretRef(provider: "vault-http", item: "db/creds")
        #expect(try await client.resolve(ref) == .text("leased-secret"))
        #expect(await tracker.leaseCount == 1)
        #expect(try await client.resolve(ref) == .text("leased-secret"))
        #expect(recordedRequests().count == 2)
    }

    @Test func renewalRefreshesExpiry() async throws {
        let (tracker, clock) = makeTracker()
        setStubHandler { request in
            let path = request.url?.path ?? ""
            if path == "/v1/sys/health" { return (200, healthData()) }
            if path == "/v1/sys/leases/renew" { return (200, renewData(duration: 200)) }
            return (200, kvLeaseData(fields: "\"value\":\"db-pass\"", duration: 100))
        }
        let client = try makeClient(tracker: tracker)
        let ref = try SecretRef(provider: "vault-http", item: "db/creds")
        #expect(try await client.resolve(ref) == .text("db-pass"))
        #expect(await tracker.dueLeases().isEmpty)
        clock.advance(by: 60)
        #expect(await tracker.dueLeases().count == 1)
        let outcomes = try await client.renewDueLeases()
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.leaseID == "lease-1")
        guard case .renewed(let expiresAt, let duration) = outcomes.first?.outcome else {
            Issue.record("expected renewed outcome")
            return
        }
        #expect(duration == 200)
        #expect(expiresAt == clock.now().addingTimeInterval(200))
        let renew = try #require(recordedRequests().first { $0.url?.path == "/v1/sys/leases/renew" })
        #expect(renew.httpMethod == "PUT")
        #expect(renew.value(forHTTPHeaderField: "X-Vault-Token") == "test-token")
        let renewBodyData = try #require(requestBody(renew))
        let renewBody = try #require(String(data: renewBodyData, encoding: .utf8))
        #expect(renewBody.contains("lease-1"))
        let renewObject = try JSONSerialization.jsonObject(with: renewBodyData)
        let renewJSON = try #require(renewObject as? [String: Any])
        #expect(renewJSON["increment"] as? Int == 100)
        clock.advance(by: 90)
        let before = recordedRequests().count
        #expect(try await client.resolve(ref) == .text("db-pass"))
        #expect(recordedRequests().count == before)
    }

    @Test func doubleRenewIsIdempotent() async throws {
        let (tracker, clock) = makeTracker()
        setStubHandler { request in
            let path = request.url?.path ?? ""
            if path == "/v1/sys/health" { return (200, healthData()) }
            if path == "/v1/sys/leases/renew" { return (200, renewData(duration: 200)) }
            return (200, kvLeaseData(fields: "\"value\":\"v\"", duration: 100))
        }
        let client = try makeClient(tracker: tracker)
        _ = try await client.resolve(try SecretRef(provider: "vault-http", item: "x"))
        clock.advance(by: 60)
        #expect(try await client.renewDueLeases().count == 1)
        #expect(try await client.renewDueLeases().isEmpty)
        #expect(recordedRequests().filter { $0.url?.path == "/v1/sys/leases/renew" }.count == 1)
    }

    @Test func nonRenewableLeaseCachedUntilExpiryThenThrows() async throws {
        let (tracker, clock) = makeTracker()
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (
                200,
                kvLeaseData(
                    fields: "\"value\":\"once\"", leaseID: "lease-nr",
                    renewable: false, duration: 100
                )
            )
        }
        let client = try makeClient(tracker: tracker)
        let ref = try SecretRef(provider: "vault-http", item: "db/creds")
        #expect(try await client.resolve(ref) == .text("once"))
        clock.advance(by: 60)
        #expect(await tracker.dueLeases().isEmpty)
        #expect(try await client.renewDueLeases().isEmpty)
        #expect(recordedRequests().allSatisfy { $0.url?.path != "/v1/sys/leases/renew" })
        #expect(try await client.resolve(ref) == .text("once"))
        clock.advance(by: 60)
        await #expect(throws: SecretsError.leaseExpired("vault-http")) {
            try await client.resolve(ref)
        }
    }

    @Test func zeroNegativeAndMissingLeaseUntracked() async throws {
        for duration in [0, -5] {
            let (tracker, _) = makeTracker()
            setStubHandler { request in
                if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
                return (200, kvLeaseData(fields: "\"value\":\"static\"", duration: duration))
            }
            let client = try makeClient(tracker: tracker)
            let ref = try SecretRef(provider: "vault-http", item: "x")
            #expect(try await client.resolve(ref) == .text("static"))
            #expect(await tracker.leaseCount == 0, "duration \(duration) untracked")
            #expect(try await client.resolve(ref) == .text("static"))
            #expect(recordedRequests().count == 4, "duration \(duration) always re-reads")
        }
        let (tracker, _) = makeTracker()
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (200, kvData("\"value\":\"static\""))
        }
        let plain = try makeClient(tracker: tracker)
        _ = try await plain.resolve(try SecretRef(provider: "vault-http", item: "x"))
        #expect(await tracker.leaseCount == 0)
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (200, kvLeaseData(fields: "\"value\":\"static\"", leaseID: "", duration: 100))
        }
        _ = try await plain.resolve(try SecretRef(provider: "vault-http", item: "y"))
        #expect(await tracker.leaseCount == 0)
    }

    @Test func renewAfterExpiryThrowsLeaseExpired() async throws {
        let (tracker, clock) = makeTracker()
        setStubHandler { request in
            let path = request.url?.path ?? ""
            if path == "/v1/sys/health" { return (200, healthData()) }
            if path == "/v1/sys/leases/renew" { return (200, renewData(duration: 200)) }
            return (200, kvLeaseData(fields: "\"value\":\"v1\"", duration: 60))
        }
        let client = try makeClient(tracker: tracker)
        let ref = try SecretRef(provider: "vault-http", item: "x")
        #expect(try await client.resolve(ref) == .text("v1"))
        clock.advance(by: 61)
        #expect(try await client.renewDueLeases().isEmpty)
        #expect(recordedRequests().allSatisfy { $0.url?.path != "/v1/sys/leases/renew" })
        await #expect(throws: SecretsError.leaseExpired("vault-http")) {
            try await client.resolve(ref)
        }
        #expect(try await client.resolve(ref) == .text("v1"))
        #expect(await tracker.leaseCount == 1)
    }

    @Test func expiryDuringCallCompletesThenNextThrows() async throws {
        let (tracker, clock) = makeTracker()
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (200, kvLeaseData(fields: "\"value\":\"call-arg\"", duration: 60))
        }
        let client = try makeClient(tracker: tracker)
        let ref = try SecretRef(provider: "vault-http", item: "x")
        let held = try await client.resolve(ref)
        clock.advance(by: 3600)
        #expect(held == .text("call-arg"))
        await #expect(throws: SecretsError.leaseExpired("vault-http")) {
            try await client.resolve(ref)
        }
    }

    @Test func sealedMidRunFailsDownButHeldUsable() async throws {
        let (tracker, _) = makeTracker()
        let sealed = Mutex(false)
        setStubHandler { request in
            let path = request.url?.path ?? ""
            if path == "/v1/sys/health" {
                return sealed.withLock({ $0 })
                    ? (503, healthData(sealedValue: true))
                    : (200, healthData())
            }
            if path == "/v1/sys/leases/renew" { return (503, Data("{}".utf8)) }
            return (200, kvLeaseData(fields: "\"value\":\"held\"", duration: 3600))
        }
        let client = try makeClient(tracker: tracker)
        let held = try SecretRef(provider: "vault-http", item: "held")
        #expect(try await client.resolve(held) == .text("held"))
        sealed.withLock { $0 = true }
        await #expect(throws: SecretsError.providerDown("vault-http:sealed")) {
            try await client.resolve(try SecretRef(provider: "vault-http", item: "other"))
        }
        let before = recordedRequests().count
        #expect(try await client.resolve(held) == .text("held"))
        #expect(recordedRequests().count == before)
    }

    @Test func renewFailureKeepsLeaseUntilExpiry() async throws {
        let (tracker, clock) = makeTracker()
        setStubHandler { request in
            let path = request.url?.path ?? ""
            if path == "/v1/sys/health" { return (200, healthData()) }
            if path == "/v1/sys/leases/renew" { return (503, Data("{}".utf8)) }
            return (200, kvLeaseData(fields: "\"value\":\"v\"", duration: 100))
        }
        let client = try makeClient(tracker: tracker)
        let ref = try SecretRef(provider: "vault-http", item: "x")
        _ = try await client.resolve(ref)
        clock.advance(by: 60)
        let outcomes = try await client.renewDueLeases()
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.outcome == .failed(.providerDown("vault-http:sealed")))
        #expect(await tracker.leaseCount == 1)
        #expect(await tracker.dueLeases().count == 1)
        #expect(try await client.resolve(ref) == .text("v"))
        clock.advance(by: 60)
        await #expect(throws: SecretsError.leaseExpired("vault-http")) {
            try await client.resolve(ref)
        }
    }

    @Test func renew400DropsLeaseAsExpired() async throws {
        let (tracker, clock) = makeTracker()
        setStubHandler { request in
            let path = request.url?.path ?? ""
            if path == "/v1/sys/health" { return (200, healthData()) }
            if path == "/v1/sys/leases/renew" {
                return (400, Data("{\"errors\":[\"lease not found\"]}".utf8))
            }
            return (200, kvLeaseData(fields: "\"value\":\"v\"", duration: 100))
        }
        let client = try makeClient(tracker: tracker)
        let ref = try SecretRef(provider: "vault-http", item: "x")
        _ = try await client.resolve(ref)
        clock.advance(by: 60)
        let outcomes = try await client.renewDueLeases()
        #expect(outcomes.first?.outcome == .failed(.leaseExpired("vault-http")))
        #expect(await tracker.leaseCount == 0)
        #expect(try await client.resolve(ref) == .text("v"))
        #expect(await tracker.leaseCount == 1)
    }

    @Test func renewStatusMappingsKeepLease() async throws {
        let cases: [(Int, SecretsError)] = [
            (401, .providerDown("vault-http:forbidden")),
            (403, .providerDown("vault-http:forbidden")),
            (429, .providerDown("vault-http:rateLimited")),
            (501, .providerDown("vault-http:uninitialized")),
            (307, .providerDown("vault-http:standby")),
            (472, .providerDown("vault-http:standby")),
            (473, .providerDown("vault-http:standby")),
            (500, .providerDown("vault-http:server")),
        ]
        for (status, error) in cases {
            let (tracker, clock) = makeTracker()
            setStubHandler { request in
                let path = request.url?.path ?? ""
                if path == "/v1/sys/health" { return (200, healthData()) }
                if path == "/v1/sys/leases/renew" { return (status, Data("{}".utf8)) }
                return (200, kvLeaseData(fields: "\"value\":\"v\"", duration: 100))
            }
            let client = try makeClient(tracker: tracker)
            _ = try await client.resolve(try SecretRef(provider: "vault-http", item: "x"))
            clock.advance(by: 60)
            let outcomes = try await client.renewDueLeases()
            #expect(outcomes.first?.outcome == .failed(error), "renew \(status)")
            #expect(await tracker.leaseCount == 1, "renew \(status) keeps lease")
        }
        let (tracker, clock) = makeTracker()
        setStubHandler { request in
            let path = request.url?.path ?? ""
            if path == "/v1/sys/health" { return (200, healthData()) }
            if path == "/v1/sys/leases/renew" { return (404, Data("{}".utf8)) }
            return (200, kvLeaseData(fields: "\"value\":\"v\"", duration: 100))
        }
        let client = try makeClient(tracker: tracker)
        _ = try await client.resolve(try SecretRef(provider: "vault-http", item: "x"))
        clock.advance(by: 60)
        #expect(
            try await client.renewDueLeases().first?.outcome
                == .failed(.leaseExpired("vault-http"))
        )
        #expect(await tracker.leaseCount == 0)
    }

    @Test func renewBadBodyKeepsLease() async throws {
        for body in ["{not json", "{\"lease_duration\":0}", "{\"lease_duration\":-3}", "{}"] {
            let (tracker, clock) = makeTracker()
            setStubHandler { request in
                let path = request.url?.path ?? ""
                if path == "/v1/sys/health" { return (200, healthData()) }
                if path == "/v1/sys/leases/renew" { return (200, Data(body.utf8)) }
                return (200, kvLeaseData(fields: "\"value\":\"v\"", duration: 100))
            }
            let client = try makeClient(tracker: tracker)
            _ = try await client.resolve(try SecretRef(provider: "vault-http", item: "x"))
            clock.advance(by: 60)
            #expect(
                try await client.renewDueLeases().first?.outcome
                    == .failed(.providerDown("vault-http:decode")),
                "body \(body)"
            )
            #expect(await tracker.leaseCount == 1)
        }
    }

    @Test func renewHonorsRenewableFlip() async throws {
        let (tracker, clock) = makeTracker()
        setStubHandler { request in
            let path = request.url?.path ?? ""
            if path == "/v1/sys/health" { return (200, healthData()) }
            if path == "/v1/sys/leases/renew" {
                return (200, renewData(renewable: false, duration: 200))
            }
            return (200, kvLeaseData(fields: "\"value\":\"v\"", duration: 100))
        }
        let client = try makeClient(tracker: tracker)
        let ref = try SecretRef(provider: "vault-http", item: "x")
        _ = try await client.resolve(ref)
        clock.advance(by: 60)
        #expect(try await client.renewDueLeases().count == 1)
        #expect(await tracker.dueLeases().isEmpty)
        clock.advance(by: 1000)
        await #expect(throws: SecretsError.leaseExpired("vault-http")) {
            try await client.resolve(ref)
        }
    }

    @Test func renewTransportMappedAndCancellationPropagates() async throws {
        let (tracker, clock) = makeTracker()
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            if request.url?.path == "/v1/sys/leases/renew" { throw URLError(.timedOut) }
            return (200, kvLeaseData(fields: "\"value\":\"v\"", duration: 100))
        }
        let client = try makeClient(tracker: tracker)
        _ = try await client.resolve(try SecretRef(provider: "vault-http", item: "x"))
        clock.advance(by: 60)
        #expect(
            try await client.renewDueLeases().first?.outcome
                == .failed(.timeout("vault-http"))
        )
        let url = URL(string: "https://vault.example.com:8200")!
        let (tracker2, clock2) = makeTracker()
        let cancelling = try VaultHTTPClient(
            endpoint: url, mount: "secret", auth: .token("t"),
            tls: .system, timeoutSeconds: 10,
            transport: { request in
                guard let url = request.url else { throw URLError(.badURL) }
                guard
                    let response = HTTPURLResponse(
                        url: url, statusCode: 200, httpVersion: nil, headerFields: nil
                    )
                else {
                    throw URLError(.badServerResponse)
                }
                if request.url?.path == "/v1/sys/health" { return (healthData(), response) }
                if request.url?.path == "/v1/sys/leases/renew" { throw CancellationError() }
                return (kvLeaseData(fields: "\"value\":\"v\"", duration: 100), response)
            },
            tracker: tracker2
        )
        _ = try await cancelling.resolve(try SecretRef(provider: "vault-http", item: "x"))
        clock2.advance(by: 60)
        await #expect(throws: CancellationError.self) {
            try await cancelling.renewDueLeases()
        }
    }

    @Test func renewUsesAppRoleLogin() async throws {
        let (tracker, clock) = makeTracker()
        setStubHandler { request in
            let path = request.url?.path ?? ""
            if path == "/v1/sys/health" { return (200, healthData()) }
            if path == "/v1/auth/approle/login" {
                return (200, loginData(token: "s.renew", accessor: "acc-r", ttl: 600))
            }
            if path == "/v1/sys/leases/renew" { return (200, renewData(duration: 200)) }
            return (200, kvLeaseData(fields: "\"value\":\"v\"", duration: 100))
        }
        let client = try makeClient(auth: .appRole(roleID: "r", secretID: "s"), tracker: tracker)
        _ = try await client.resolve(try SecretRef(provider: "vault-http", item: "x"))
        clock.advance(by: 60)
        #expect(try await client.renewDueLeases().count == 1)
        let renews = recordedRequests().filter { $0.url?.path == "/v1/sys/leases/renew" }
        #expect(renews.count == 1)
        #expect(renews.first?.value(forHTTPHeaderField: "X-Vault-Token") == "s.renew")
        #expect(recordedRequests().filter { $0.url?.path == "/v1/auth/approle/login" }.count == 2)
    }

    @Test func renewalLoopRenewsDueLeasesUntilCancelled() async throws {
        let (tracker, clock) = makeTracker()
        setStubHandler { request in
            let path = request.url?.path ?? ""
            if path == "/v1/sys/health" { return (200, healthData()) }
            if path == "/v1/sys/leases/renew" { return (200, renewData(duration: 200)) }
            return (200, kvLeaseData(fields: "\"value\":\"v\"", duration: 100))
        }
        let client = try makeClient(tracker: tracker)
        _ = try await client.resolve(try SecretRef(provider: "vault-http", item: "x"))
        clock.advance(by: 60)
        let loop = Task { await client.runRenewalLoop(checkIntervalSeconds: 0.05) }
        var renewed = false
        for _ in 0..<200 {
            if await tracker.dueLeases().isEmpty { renewed = true; break }
            try await Task.sleep(for: .milliseconds(25))
        }
        loop.cancel()
        await loop.value
        #expect(renewed)
        #expect(recordedRequests().contains { $0.url?.path == "/v1/sys/leases/renew" })
    }

    @Test func wrapTTLUnwrapsAfterCommitExactlyOnce() async throws {
        let (tracker, _) = makeTracker()
        setStubHandler { request in
            let path = request.url?.path ?? ""
            if path == "/v1/sys/health" { return (200, healthData()) }
            if path == "/v1/sys/wrapping/unwrap" {
                return (
                    200,
                    kvLeaseData(
                        fields: "\"value\":\"wrapped-secret\"",
                        leaseID: "lease-w", duration: 300
                    )
                )
            }
            if path.hasPrefix("/v1/secret/data/") { return (200, wrapData()) }
            return (404, Data("{}".utf8))
        }
        let client = try makeClient(wrapTTL: "5m", tracker: tracker)
        let ref = try SecretRef(provider: "vault-http", item: "x")
        #expect(try await client.resolve(ref) == .text("wrapped-secret"))
        let requests = recordedRequests()
        let kv = try #require(requests.first { ($0.url?.path ?? "").hasPrefix("/v1/secret/data/") })
        #expect(kv.value(forHTTPHeaderField: "X-Vault-Wrap-TTL") == "5m")
        let unwraps = requests.filter { $0.url?.path == "/v1/sys/wrapping/unwrap" }
        #expect(unwraps.count == 1)
        #expect(unwraps.first?.httpMethod == "PUT")
        #expect(unwraps.first?.value(forHTTPHeaderField: "X-Vault-Token") == "test-token")
        let unwrapBody = try #require(
            unwraps.first.flatMap(requestBody).flatMap { String(data: $0, encoding: .utf8) }
        )
        #expect(unwrapBody.contains("wrapping-token-1"))
        let kvIndex = try #require(
            requests.firstIndex { ($0.url?.path ?? "").hasPrefix("/v1/secret/data/") }
        )
        let unwrapIndex = try #require(
            requests.firstIndex { $0.url?.path == "/v1/sys/wrapping/unwrap" }
        )
        #expect(kvIndex < unwrapIndex)
        #expect(await tracker.leaseCount == 1)
        let before = requests.count
        #expect(try await client.resolve(ref) == .text("wrapped-secret"))
        #expect(recordedRequests().count == before)
    }

    @Test func unwrapFailureIsDownWithoutRetry() async throws {
        for status in [400, 404] {
            setStubHandler { request in
                let path = request.url?.path ?? ""
                if path == "/v1/sys/health" { return (200, healthData()) }
                if path == "/v1/sys/wrapping/unwrap" { return (status, Data("{}".utf8)) }
                return (200, wrapData())
            }
            let client = try makeClient(wrapTTL: "30s")
            await #expect(throws: SecretsError.providerDown("vault-http:wrap"), "unwrap \(status)") {
                try await client.resolve(try SecretRef(provider: "vault-http", item: "x"))
            }
            #expect(
                recordedRequests().filter { $0.url?.path == "/v1/sys/wrapping/unwrap" }.count == 1
            )
        }
        setStubHandler { request in
            let path = request.url?.path ?? ""
            if path == "/v1/sys/health" { return (200, healthData()) }
            if path == "/v1/sys/wrapping/unwrap" { return (503, Data("{}".utf8)) }
            return (200, wrapData())
        }
        let sealed = try makeClient(wrapTTL: "30s")
        await #expect(throws: SecretsError.providerDown("vault-http:sealed")) {
            try await sealed.resolve(try SecretRef(provider: "vault-http", item: "x"))
        }
    }

    @Test func wrapMissingTokenIsWrapDown() async throws {
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (200, Data("{\"wrap_info\":{\"ttl\":300}}".utf8))
        }
        let client = try makeClient(wrapTTL: "5m")
        await #expect(throws: SecretsError.providerDown("vault-http:wrap")) {
            try await client.resolve(try SecretRef(provider: "vault-http", item: "x"))
        }
        #expect(recordedRequests().allSatisfy { $0.url?.path != "/v1/sys/wrapping/unwrap" })
    }

    @Test func unwrappedFieldSelectsLikeDirectRead() async throws {
        setStubHandler { request in
            let path = request.url?.path ?? ""
            if path == "/v1/sys/health" { return (200, healthData()) }
            if path == "/v1/sys/wrapping/unwrap" {
                return (200, Data("{\"data\":{\"data\":{\"a\":\"1\",\"b\":\"2\"}}}".utf8))
            }
            return (200, wrapData())
        }
        let client = try makeClient(wrapTTL: "5m")
        #expect(
            try await client.resolve(try SecretRef(provider: "vault-http", item: "x", field: "b"))
                == .text("2")
        )
        await #expect(throws: SecretsError.notFound("vault-http")) {
            try await client.resolve(try SecretRef(provider: "vault-http", item: "y"))
        }
    }

    @Test func wrapTTLWithInlineDataServesDirectly() async throws {
        let (tracker, _) = makeTracker()
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (200, kvLeaseData(fields: "\"value\":\"inline\"", duration: 100))
        }
        let client = try makeClient(wrapTTL: "5m", tracker: tracker)
        #expect(
            try await client.resolve(try SecretRef(provider: "vault-http", item: "x"))
                == .text("inline")
        )
        let kv = try #require(
            recordedRequests().first { ($0.url?.path ?? "").hasPrefix("/v1/secret/data/") }
        )
        #expect(kv.value(forHTTPHeaderField: "X-Vault-Wrap-TTL") == "5m")
        #expect(recordedRequests().allSatisfy { $0.url?.path != "/v1/sys/wrapping/unwrap" })
        #expect(await tracker.leaseCount == 1)
    }

    @Test func invalidWrapTTLRejected() throws {
        for ttl in ["", "0", "5", "5x", "x5m", "-5m", "5 m", "0s", "100000s", "999999h"] {
            #expect(throws: VaultConfigurationError.invalidWrapTTL, "rejects \(ttl)") {
                try makeClient(wrapTTL: ttl)
            }
        }
        for ttl in ["1s", "30s", "5m", "1h", "24h"] {
            #expect(try makeClient(wrapTTL: ttl).wrapTTL == ttl, "accepts \(ttl)")
        }
        #expect(try makeClient().wrapTTL == nil)
        let live = try VaultHTTPClient(
            endpoint: URL(string: "https://vault.example.com:8200")!,
            auth: .token("root"), wrapTTL: "5m"
        )
        #expect(live.wrapTTL == "5m")
    }

    @Test func jitterBoundsAndClamping() {
        let policy = VaultLeasePolicy(
            maxTrackedLeases: 64, renewFraction: 0.5, maxJitterFraction: 0.1
        )
        #expect(abs(policy.renewDelay(leaseDurationSeconds: 100, jitterUnit: 0) - 50) < 0.000001)
        #expect(abs(policy.renewDelay(leaseDurationSeconds: 100, jitterUnit: 1) - 55) < 0.000001)
        #expect(abs(policy.renewDelay(leaseDurationSeconds: 100, jitterUnit: -1) - 45) < 0.000001)
        #expect(abs(policy.renewDelay(leaseDurationSeconds: 100, jitterUnit: 5) - 55) < 0.000001)
        #expect(abs(policy.renewDelay(leaseDurationSeconds: 100, jitterUnit: -5) - 45) < 0.000001)
        #expect(policy.renewDelay(leaseDurationSeconds: 0, jitterUnit: 0) == 0)
        #expect(policy.renewDelay(leaseDurationSeconds: -10, jitterUnit: 1) == 0)
        let tiny = policy.renewDelay(leaseDurationSeconds: 1, jitterUnit: 1)
        #expect(tiny >= 0 && tiny <= 1)
        #expect(
            VaultLeasePolicy(maxTrackedLeases: 0, renewFraction: 9, maxJitterFraction: -2)
                == VaultLeasePolicy(maxTrackedLeases: 1, renewFraction: 1, maxJitterFraction: 0)
        )
        #expect(VaultLeasePolicy.defaultMaxTrackedLeases == 64)
        #expect(VaultLeasePolicy.defaultRenewFraction == 0.5)
        #expect(VaultLeasePolicy.defaultMaxJitterFraction == 0.1)
    }

    @Test func trackerJitterSourceClamped() async throws {
        let tracker = VaultLeaseTracker(jitter: { 99 })
        _ = await tracker.track(
            refKey: "k", value: .text("v"), leaseID: "l",
            renewable: true, leaseDuration: 100
        )
        let lease = try #require(await tracker.lease(forKey: "k"))
        #expect(lease.renewsAt >= lease.trackedAt)
        #expect(lease.renewsAt <= lease.expiresAt)
        #expect(lease.expiresAt == lease.trackedAt.addingTimeInterval(100))
    }

    @Test func cardinalityCapBoundsTracking() async throws {
        let (tracker, _) = makeTracker(policy: VaultLeasePolicy(maxTrackedLeases: 2))
        setStubHandler { request in
            let path = request.url?.path ?? ""
            if path == "/v1/sys/health" { return (200, healthData()) }
            let id = path.split(separator: "/").last.map(String.init) ?? "x"
            return (
                200,
                kvLeaseData(
                    fields: "\"value\":\"\(id)-secret\"", leaseID: "lease-\(id)",
                    duration: 3600
                )
            )
        }
        let client = try makeClient(tracker: tracker)
        for item in ["a", "b", "c"] {
            let value = try await client.resolve(try SecretRef(provider: "vault-http", item: item))
            #expect(value == .text("\(item)-secret"))
        }
        #expect(await tracker.leaseCount == 2)
        #expect(await tracker.trackedLeaseIDs() == ["lease-a", "lease-b"])
        let before = recordedRequests().count
        #expect(
            try await client.resolve(try SecretRef(provider: "vault-http", item: "a"))
                == .text("a-secret")
        )
        #expect(
            try await client.resolve(try SecretRef(provider: "vault-http", item: "b"))
                == .text("b-secret")
        )
        #expect(recordedRequests().count == before)
        #expect(
            try await client.resolve(try SecretRef(provider: "vault-http", item: "c"))
                == .text("c-secret")
        )
        #expect(recordedRequests().count == before + 2)
    }

    @Test func cardinalityCapEvictsExpiredFirst() async throws {
        let (tracker, clock) = makeTracker(policy: VaultLeasePolicy(maxTrackedLeases: 1))
        setStubHandler { request in
            let path = request.url?.path ?? ""
            if path == "/v1/sys/health" { return (200, healthData()) }
            let id = path.split(separator: "/").last.map(String.init) ?? "x"
            return (
                200,
                kvLeaseData(
                    fields: "\"value\":\"\(id)\"", leaseID: "lease-\(id)", duration: 60
                )
            )
        }
        let client = try makeClient(tracker: tracker)
        _ = try await client.resolve(try SecretRef(provider: "vault-http", item: "a"))
        clock.advance(by: 61)
        _ = try await client.resolve(try SecretRef(provider: "vault-http", item: "b"))
        #expect(await tracker.trackedLeaseIDs() == ["lease-b"])
    }

    @Test func leaseExpiredNeverEchoes() async throws {
        let (tracker, clock) = makeTracker()
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (
                200,
                kvLeaseData(
                    fields: "\"password-field\":\"P@ssw0rd!\"",
                    leaseID: "lease-hunter2-db",
                    duration: 60
                )
            )
        }
        let client = try makeClient(tracker: tracker)
        _ = try await client.resolve(
            try SecretRef(provider: "vault-http", item: "super-secret-item", field: "password-field")
        )
        clock.advance(by: 61)
        do {
            _ = try await client.resolve(
                try SecretRef(
                    provider: "vault-http", item: "super-secret-item", field: "password-field"
                )
            )
            Issue.record("expected leaseExpired")
        } catch {
            let text = String(describing: error)
            #expect(text.contains("leaseExpired"))
            #expect(text.contains("P@ssw0rd!") == false)
            #expect(text.contains("super-secret-item") == false)
            #expect(text.contains("password-field") == false)
            #expect(text.contains("lease-hunter2-db") == false)
        }
    }

    @Test func rogueLeaseDurationsClampToPolicyMaximum() async throws {
        let max = VaultLeasePolicy.defaultMaximumLeaseDurationSeconds
        #expect(max == 86_400)
        let box = ClockBox()
        let tracker = VaultLeaseTracker(
            policy: VaultLeasePolicy(), clock: { box.now() }, jitter: { 0 }
        )
        #expect(
            await tracker.track(
                refKey: "k", value: .text("v"), leaseID: "rogue",
                renewable: true, leaseDuration: 10_000_000
            )
        )
        let lease = try #require(await tracker.lease(forKey: "k"))
        #expect(lease.leaseDuration == max)
        #expect(lease.expiresAt == lease.trackedAt.addingTimeInterval(Double(max)))
        #expect(lease.renewsAt < lease.expiresAt)
        let updated = try #require(
            await tracker.didRenew(leaseID: "rogue", renewable: true, leaseDuration: 10_000_000)
        )
        #expect(updated.leaseDuration == max)
        #expect(updated.expiresAt == updated.trackedAt.addingTimeInterval(Double(max)))
        let (cached, cachedClock) = makeTracker()
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (200, kvLeaseData(fields: "\"value\":\"v\"", duration: 31_556_952))
        }
        let yearLease = try makeClient(tracker: cached)
        let ref = try SecretRef(provider: "vault-http", item: "x")
        #expect(try await yearLease.resolve(ref) == .text("v"))
        cachedClock.advance(by: Double(max) + 1)
        await #expect(throws: SecretsError.leaseExpired("vault-http")) {
            try await yearLease.resolve(ref)
        }
        let (renewed, renewClock) = makeTracker()
        setStubHandler { request in
            let path = request.url?.path ?? ""
            if path == "/v1/sys/health" { return (200, healthData()) }
            if path == "/v1/sys/leases/renew" { return (200, renewData(duration: 9_999_999)) }
            return (200, kvLeaseData(fields: "\"value\":\"v\"", duration: 100))
        }
        let renewing = try makeClient(tracker: renewed)
        _ = try await renewing.resolve(try SecretRef(provider: "vault-http", item: "x"))
        renewClock.advance(by: 60)
        let outcomes = try await renewing.renewDueLeases()
        guard case .renewed(let expiresAt, let duration) = outcomes.first?.outcome else {
            Issue.record("expected renewed outcome")
            return
        }
        #expect(duration == max)
        #expect(expiresAt == renewClock.now().addingTimeInterval(Double(max)))
    }

    @Test func renewLoginFailureFailsAllDueWithoutThrowing() async throws {
        let (tracker, clock) = makeTracker()
        setStubHandler { request in
            let path = request.url?.path ?? ""
            if path == "/v1/sys/health" { return (200, healthData()) }
            if path == "/v1/auth/approle/login" { return (403, Data("{}".utf8)) }
            if path == "/v1/sys/leases/renew" { return (200, renewData(duration: 200)) }
            return (200, kvLeaseData(fields: "\"value\":\"v\"", duration: 100))
        }
        let client = try makeClient(auth: .appRole(roleID: "r", secretID: "s"), tracker: tracker)
        _ = await tracker.track(
            refKey: "a", value: .text("va"), leaseID: "lease-a",
            renewable: true, leaseDuration: 100
        )
        _ = await tracker.track(
            refKey: "b", value: .text("vb"), leaseID: "lease-b",
            renewable: true, leaseDuration: 100
        )
        clock.advance(by: 60)
        #expect(await tracker.dueLeases().count == 2)
        let outcomes = try await client.renewDueLeases()
        #expect(outcomes.count == 2)
        #expect(outcomes.allSatisfy { $0.outcome == .failed(.providerDown("vault-http:forbidden")) })
        #expect(outcomes.map(\.leaseID).sorted() == ["lease-a", "lease-b"])
        #expect(recordedRequests().filter { $0.url?.path == "/v1/sys/leases/renew" }.count == 0)
        #expect(recordedRequests().filter { $0.url?.path == "/v1/auth/approle/login" }.count == 1)
        #expect(await tracker.leaseCount == 2)
        #expect(await tracker.dueLeases().count == 2)
        let loginURL = URL(string: "https://vault.example.com:8200")!
        let (cancelTracker, cancelClock) = makeTracker()
        _ = await cancelTracker.track(
            refKey: "c", value: .text("vc"), leaseID: "lease-c",
            renewable: true, leaseDuration: 100
        )
        cancelClock.advance(by: 60)
        let cancellingLogin: VaultTransport = { request in
            if request.url?.path == "/v1/auth/approle/login" { throw CancellationError() }
            throw URLError(.badServerResponse)
        }
        let cancelling = try VaultHTTPClient(
            endpoint: loginURL, mount: "secret", auth: .appRole(roleID: "r", secretID: "s"),
            tls: .system, timeoutSeconds: 10, transport: cancellingLogin,
            tracker: cancelTracker
        )
        await #expect(throws: CancellationError.self) {
            try await cancelling.renewDueLeases()
        }
    }

    @Test func unwrapStatusMappings() async throws {
        let cases: [(Int, SecretsError)] = [
            (400, .providerDown("vault-http:wrap")),
            (404, .providerDown("vault-http:wrap")),
            (401, .providerDown("vault-http:forbidden")),
            (403, .providerDown("vault-http:forbidden")),
            (429, .providerDown("vault-http:rateLimited")),
            (501, .providerDown("vault-http:uninitialized")),
            (503, .providerDown("vault-http:sealed")),
            (307, .providerDown("vault-http:standby")),
            (472, .providerDown("vault-http:standby")),
            (473, .providerDown("vault-http:standby")),
            (500, .providerDown("vault-http:server")),
            (418, .providerDown("vault-http:server")),
        ]
        for (status, error) in cases {
            setStubHandler { request in
                let path = request.url?.path ?? ""
                if path == "/v1/sys/health" { return (200, healthData()) }
                if path == "/v1/sys/wrapping/unwrap" { return (status, Data("{}".utf8)) }
                return (200, wrapData())
            }
            let client = try makeClient(wrapTTL: "30s")
            await #expect(throws: error, "unwrap \(status)") {
                try await client.resolve(try SecretRef(provider: "vault-http", item: "x"))
            }
            #expect(
                recordedRequests().filter { $0.url?.path == "/v1/sys/wrapping/unwrap" }.count == 1,
                "unwrap \(status) single-shot"
            )
        }
        for body in ["{not json", "{}"] {
            setStubHandler { request in
                let path = request.url?.path ?? ""
                if path == "/v1/sys/health" { return (200, healthData()) }
                if path == "/v1/sys/wrapping/unwrap" { return (200, Data(body.utf8)) }
                return (200, wrapData())
            }
            let client = try makeClient(wrapTTL: "30s")
            await #expect(throws: SecretsError.providerDown("vault-http:decode"), "unwrap body \(body)") {
                try await client.resolve(try SecretRef(provider: "vault-http", item: "x"))
            }
        }
        setStubHandler { request in
            let path = request.url?.path ?? ""
            if path == "/v1/sys/health" { return (200, healthData()) }
            if path == "/v1/sys/wrapping/unwrap" {
                return (200, Data(repeating: 0x41, count: VaultHTTPClient.maximumResponseBytes + 1))
            }
            return (200, wrapData())
        }
        let oversized = try makeClient(wrapTTL: "30s")
        await #expect(throws: SecretsError.oversized("vault-http")) {
            try await oversized.resolve(try SecretRef(provider: "vault-http", item: "x"))
        }
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            if request.url?.path == "/v1/sys/wrapping/unwrap" { throw URLError(.timedOut) }
            return (200, wrapData())
        }
        let timedOut = try makeClient(wrapTTL: "30s")
        await #expect(throws: SecretsError.timeout("vault-http")) {
            try await timedOut.resolve(try SecretRef(provider: "vault-http", item: "x"))
        }
        let cancelURL = URL(string: "https://vault.example.com:8200")!
        let cancellingUnwrap: VaultTransport = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            guard
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil
                )
            else {
                throw URLError(.badServerResponse)
            }
            if request.url?.path == "/v1/sys/health" { return (healthData(), response) }
            if request.url?.path == "/v1/sys/wrapping/unwrap" { throw CancellationError() }
            return (wrapData(), response)
        }
        let cancelling = try VaultHTTPClient(
            endpoint: cancelURL, mount: "secret", auth: .token("t"),
            tls: .system, timeoutSeconds: 10, transport: cancellingUnwrap,
            wrapTTL: "30s"
        )
        await #expect(throws: CancellationError.self) {
            try await cancelling.resolve(try SecretRef(provider: "vault-http", item: "x"))
        }
    }

    @Test func concurrentLeasedResolvesShareOneTrackedLease() async throws {
        let (tracker, _) = makeTracker()
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (
                200,
                kvLeaseData(
                    fields: "\"value\":\"leased-ok\"", leaseID: "lease-shared",
                    duration: 3600
                )
            )
        }
        let client = try makeClient(tracker: tracker)
        let ref = try SecretRef(provider: "vault-http", item: "shared")
        let results = await withTaskGroup(of: SecretValue.self, returning: [SecretValue].self) { group in
            for _ in 0..<50 {
                group.addTask { (try? await client.resolve(ref)) ?? .text("FAILED") }
            }
            var collected: [SecretValue] = []
            for await value in group { collected.append(value) }
            return collected
        }
        #expect(results.count == 50)
        #expect(results.allSatisfy { $0 == .text("leased-ok") })
        #expect(await tracker.leaseCount == 1)
        #expect(await tracker.trackedLeaseIDs() == ["lease-shared"])
    }

    @Test func trackRejectsEmptyLeaseIDAndNonpositiveDuration() async {
        let (tracker, _) = makeTracker()
        #expect(
            await tracker.track(
                refKey: "empty-id", value: .text("v"), leaseID: "",
                renewable: true, leaseDuration: 100
            ) == false
        )
        #expect(
            await tracker.track(
                refKey: "zero", value: .text("v"), leaseID: "lease-zero",
                renewable: true, leaseDuration: 0
            ) == false
        )
        #expect(
            await tracker.track(
                refKey: "negative", value: .text("v"), leaseID: "lease-neg",
                renewable: true, leaseDuration: -5
            ) == false
        )
        #expect(await tracker.leaseCount == 0)
    }

    @Test func didRenewReturnsNilForUnknownLeaseAndNonpositiveDuration() async {
        let (tracker, _) = makeTracker()
        #expect(
            await tracker.didRenew(leaseID: "unknown", renewable: true, leaseDuration: 100) == nil
        )
        _ = await tracker.track(
            refKey: "k", value: .text("v"), leaseID: "lease-1",
            renewable: true, leaseDuration: 100
        )
        #expect(
            await tracker.didRenew(leaseID: "lease-1", renewable: true, leaseDuration: 0) == nil
        )
        #expect(
            await tracker.didRenew(leaseID: "unknown", renewable: true, leaseDuration: 0) == nil
        )
        #expect(await tracker.leaseCount == 1)
    }

    @Test func kv200WithNullDataAndNullWrapInfoIsDecodeDown() async throws {
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (200, Data("{}".utf8))
        }
        let client = try makeClient()
        await #expect(throws: SecretsError.providerDown("vault-http:decode")) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
    }

    @Test func unwrapSecretsErrorRethrown() async throws {
        let url = URL(string: "https://vault.example.com:8200")!
        let probe: VaultTransport = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let path = request.url?.path ?? ""
            if path == "/v1/sys/health" { return (healthData(), response) }
            if path == "/v1/sys/wrapping/unwrap" { throw SecretsError.policyDenied }
            return (wrapData(), response)
        }
        let client = try VaultHTTPClient(
            endpoint: url, mount: "secret", auth: .token("t"),
            tls: .system, timeoutSeconds: 10, transport: probe,
            wrapTTL: "30s"
        )
        await #expect(throws: SecretsError.policyDenied) {
            try await client.resolve(SecretRef(provider: "vault-http", item: "x"))
        }
    }

    @Test func trackedLeaseDefaultsMissingRenewableToFalse() async throws {
        let (tracker, clock) = makeTracker()
        setStubHandler { request in
            if request.url?.path == "/v1/sys/health" { return (200, healthData()) }
            return (
                200,
                kvLeaseData(
                    fields: "\"value\":\"v\"", leaseID: "lease-nr",
                    renewable: nil, duration: 100
                )
            )
        }
        let client = try makeClient(tracker: tracker)
        #expect(
            try await client.resolve(try SecretRef(provider: "vault-http", item: "x")) == .text("v")
        )
        #expect(await tracker.leaseCount == 1)
        let key = VaultHTTPClient.refKey(item: "x", field: nil)
        #expect(await tracker.lease(forKey: key)?.renewable == false)
        clock.advance(by: 60)
        #expect(await tracker.dueLeases().isEmpty)
    }

    @Test func renewLoginTransportTimeoutFailsAllDueLeases() async throws {
        let (tracker, clock) = makeTracker()
        setStubHandler { request in
            let path = request.url?.path ?? ""
            if path == "/v1/sys/health" { return (200, healthData()) }
            if path == "/v1/auth/approle/login" { throw URLError(.timedOut) }
            if path == "/v1/sys/leases/renew" { return (200, renewData(duration: 200)) }
            return (200, kvLeaseData(fields: "\"value\":\"v\"", duration: 100))
        }
        let client = try makeClient(auth: .appRole(roleID: "r", secretID: "s"), tracker: tracker)
        _ = await tracker.track(
            refKey: "a", value: .text("va"), leaseID: "lease-a",
            renewable: true, leaseDuration: 100
        )
        _ = await tracker.track(
            refKey: "b", value: .text("vb"), leaseID: "lease-b",
            renewable: true, leaseDuration: 100
        )
        clock.advance(by: 60)
        #expect(await tracker.dueLeases().count == 2)
        let outcomes = try await client.renewDueLeases()
        #expect(outcomes.count == 2)
        #expect(outcomes.allSatisfy { $0.outcome == .failed(.timeout("vault-http")) })
        #expect(recordedRequests().filter { $0.url?.path == "/v1/sys/leases/renew" }.count == 0)
        #expect(await tracker.leaseCount == 2)
    }

    @Test func renewSecretsErrorBecomesFailedOutcome() async throws {
        let (tracker, clock) = makeTracker()
        let url = URL(string: "https://vault.example.com:8200")!
        let probe: VaultTransport = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let path = request.url?.path ?? ""
            if path == "/v1/sys/health" { return (healthData(), response) }
            if path == "/v1/sys/leases/renew" { throw SecretsError.policyDenied }
            return (kvLeaseData(fields: "\"value\":\"v\"", duration: 100), response)
        }
        let client = try VaultHTTPClient(
            endpoint: url, mount: "secret", auth: .token("t"),
            tls: .system, timeoutSeconds: 10, transport: probe,
            tracker: tracker
        )
        _ = try await client.resolve(try SecretRef(provider: "vault-http", item: "x"))
        clock.advance(by: 60)
        let outcomes = try await client.renewDueLeases()
        #expect(outcomes.first?.outcome == .failed(.policyDenied))
        #expect(await tracker.leaseCount == 1)
        #expect(await tracker.dueLeases().count == 1)
    }

    @Test func renewOversizedBodyBecomesFailedOutcome() async throws {
        let (tracker, clock) = makeTracker()
        setStubHandler { request in
            let path = request.url?.path ?? ""
            if path == "/v1/sys/health" { return (200, healthData()) }
            if path == "/v1/sys/leases/renew" {
                return (
                    200,
                    Data(repeating: 0x41, count: VaultHTTPClient.maximumResponseBytes + 1)
                )
            }
            return (200, kvLeaseData(fields: "\"value\":\"v\"", duration: 100))
        }
        let client = try makeClient(tracker: tracker)
        _ = try await client.resolve(try SecretRef(provider: "vault-http", item: "x"))
        clock.advance(by: 60)
        let outcomes = try await client.renewDueLeases()
        #expect(outcomes.first?.outcome == .failed(.oversized("vault-http")))
        #expect(await tracker.leaseCount == 1)
    }

    @Test func renewResponseDefaultsMissingRenewableToFalse() async throws {
        let (tracker, clock) = makeTracker()
        setStubHandler { request in
            let path = request.url?.path ?? ""
            if path == "/v1/sys/health" { return (200, healthData()) }
            if path == "/v1/sys/leases/renew" {
                return (200, Data("{\"lease_id\":\"lease-1\",\"lease_duration\":200}".utf8))
            }
            return (200, kvLeaseData(fields: "\"value\":\"v\"", duration: 100))
        }
        let client = try makeClient(tracker: tracker)
        _ = try await client.resolve(try SecretRef(provider: "vault-http", item: "x"))
        clock.advance(by: 60)
        let outcomes = try await client.renewDueLeases()
        guard case .renewed(_, let duration) = outcomes.first?.outcome else {
            Issue.record("expected renewed outcome")
            return
        }
        #expect(duration == 200)
        let key = VaultHTTPClient.refKey(item: "x", field: nil)
        #expect(await tracker.lease(forKey: key)?.renewable == false)
        #expect(await tracker.dueLeases().isEmpty)
    }

    @Test func renewOneUntrackedLeaseReportsLeaseExpired() async throws {
        let (tracker, _) = makeTracker()
        _ = await tracker.track(
            refKey: "k", value: .text("v"), leaseID: "lease-gone",
            renewable: true, leaseDuration: 100
        )
        let lease = try #require(await tracker.lease(forKey: "k"))
        await tracker.drop(leaseID: "lease-gone")
        setStubHandler { request in
            if request.url?.path == "/v1/sys/leases/renew" {
                return (200, renewData(leaseID: "lease-gone", duration: 200))
            }
            return (404, Data("{}".utf8))
        }
        let client = try makeClient(tracker: tracker)
        let renewal = try await client.renewOne(lease, token: "test-token")
        #expect(renewal.leaseID == "lease-gone")
        #expect(renewal.outcome == .failed(.leaseExpired("vault-http")))
        #expect(await tracker.leaseCount == 0)
    }

    @Test func renewalLoopCancelledDuringRenewReturnsCleanly() async throws {
        let (tracker, clock) = makeTracker()
        let entered = Mutex(false)
        let url = URL(string: "https://vault.example.com:8200")!
        let parking: VaultTransport = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let path = request.url?.path ?? ""
            if path == "/v1/sys/health" { return (healthData(), response) }
            if path == "/v1/sys/leases/renew" {
                entered.withLock { $0 = true }
                try await Task.sleep(for: .seconds(30))
                return (renewData(duration: 200), response)
            }
            return (kvLeaseData(fields: "\"value\":\"v\"", duration: 100), response)
        }
        let client = try VaultHTTPClient(
            endpoint: url, mount: "secret", auth: .token("t"),
            tls: .system, timeoutSeconds: 10, transport: parking,
            tracker: tracker
        )
        _ = try await client.resolve(try SecretRef(provider: "vault-http", item: "x"))
        clock.advance(by: 60)
        #expect(await tracker.dueLeases().count == 1)
        let loop = Task { await client.runRenewalLoop(checkIntervalSeconds: 0.05) }
        for _ in 0..<200 {
            if entered.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let didEnterRenew = entered.withLock { $0 }
        #expect(didEnterRenew)
        loop.cancel()
        await loop.value
        #expect(await tracker.leaseCount == 1)
    }
}

private struct RedirectCapture: Sendable {
    var called = false
    var forwarded: URLRequest?
}

private func vaultRedirectForwarded(delegate: URLSessionTaskDelegate) -> URLRequest? {
    let session = URLSession.shared
    let target = URL(string: "https://collector.example/v1/sys/health")!
    let task = session.dataTask(with: URL(string: "https://vault.example.com/v1/sys/health")!)
    let response = HTTPURLResponse(
        url: target, statusCode: 307, httpVersion: "HTTP/1.1",
        headerFields: ["Location": target.absoluteString]
    )!
    let box = Mutex(RedirectCapture())
    delegate.urlSession?(
        session, task: task, willPerformHTTPRedirection: response,
        newRequest: URLRequest(url: target)
    ) { request in
        box.withLock {
            $0.called = true
            $0.forwarded = request
        }
    }
    let capture = box.withLock { $0 }
    #expect(capture.called)
    return capture.forwarded
}

private enum WaveDFakeDecodeError: Error {
    case unsupported
}

/// Decoder presenting a value of no known JSON kind: nil is false and
/// every typed decode throws, so `VaultJSONValue` reaches its
/// data-corrupted throw. (Unrepresentable JSON numbers such as 1e999 fail
/// the document parse before the value initializer runs, so they cannot
/// exercise that throw through JSONDecoder.)
private struct WaveDUnsupportedValueDecoder: Decoder {
    var codingPath: [any CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        throw WaveDFakeDecodeError.unsupported
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw WaveDFakeDecodeError.unsupported
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        WaveDUnsupportedSingleValueContainer()
    }
}

private struct WaveDUnsupportedSingleValueContainer: SingleValueDecodingContainer {
    var codingPath: [any CodingKey] { [] }

    func decodeNil() -> Bool { false }
    func decode(_ type: Bool.Type) throws -> Bool { throw WaveDFakeDecodeError.unsupported }
    func decode(_ type: String.Type) throws -> String { throw WaveDFakeDecodeError.unsupported }
    func decode(_ type: Double.Type) throws -> Double { throw WaveDFakeDecodeError.unsupported }
    func decode(_ type: Float.Type) throws -> Float { throw WaveDFakeDecodeError.unsupported }
    func decode(_ type: Int.Type) throws -> Int { throw WaveDFakeDecodeError.unsupported }
    func decode(_ type: Int8.Type) throws -> Int8 { throw WaveDFakeDecodeError.unsupported }
    func decode(_ type: Int16.Type) throws -> Int16 { throw WaveDFakeDecodeError.unsupported }
    func decode(_ type: Int32.Type) throws -> Int32 { throw WaveDFakeDecodeError.unsupported }
    func decode(_ type: Int64.Type) throws -> Int64 { throw WaveDFakeDecodeError.unsupported }
    func decode(_ type: UInt.Type) throws -> UInt { throw WaveDFakeDecodeError.unsupported }
    func decode(_ type: UInt8.Type) throws -> UInt8 { throw WaveDFakeDecodeError.unsupported }
    func decode(_ type: UInt16.Type) throws -> UInt16 { throw WaveDFakeDecodeError.unsupported }
    func decode(_ type: UInt32.Type) throws -> UInt32 { throw WaveDFakeDecodeError.unsupported }
    func decode(_ type: UInt64.Type) throws -> UInt64 { throw WaveDFakeDecodeError.unsupported }
    func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
        throw WaveDFakeDecodeError.unsupported
    }
}
