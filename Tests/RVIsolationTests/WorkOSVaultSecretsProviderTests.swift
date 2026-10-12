import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(SQLite3)
import SQLite3
#endif
import RVDomain
import Synchronization
import Testing
@testable import RVIsolation

// MARK: - Stub infrastructure

/// One fake vault object: id, name, value, monotonic version.
private struct FakeVaultObject: Sendable {
    var id: String
    var name: String
    var value: String
    var version: Int
}

/// In-memory WorkOS Vault double (executor `makeFakeClient` port).
///
/// Default behavior mirrors the executor fake: creates 409 on
/// duplicates, reads 404 when missing, updates 409 on version
/// mismatch (nil or empty checks skip the check), deletes 404 on
/// unknown ids. Fault knobs mirror the executor options
/// (`conflictOnNextSecretUpdate`, `rejectNamesWithColon`,
/// `rejectReadNamesLongerThan`) plus KEK counters the executor
/// suite never needed. A `script` override answers first when set,
/// returning nil to fall through to default behavior.
private actor FakeVaultServer {
    var objectsByName: [String: FakeVaultObject] = [:]
    var requests: [URLRequest] = []
    var sequence = 0
    var conflictOnNextSecretUpdate = false
    var rejectNamesWithColon = false
    var rejectReadNamesLongerThan: Int?
    var kekReadsRemaining = 0
    var kekWritesRemaining = 0
    var updatesAlwaysConflict = false
    var updatesAlwaysStale400 = false
    var vanishAfterVersionedPuts: Int?
    var versionedPutsSeen = 0
    var script: (@Sendable (URLRequest) -> (Int, Data)?)?

    func respond(to request: URLRequest) -> (Int, Data) {
        requests.append(request)
        if let script, let scripted = script(request) {
            return scripted
        }
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        switch method {
        case "POST" where path == "/vault/v1/kv":
            return create(request)
        case "GET" where path.hasPrefix("/vault/v1/kv/name/"):
            return readByName(path)
        case "GET" where path == "/vault/v1/kv":
            return list()
        case "PUT" where path.hasPrefix("/vault/v1/kv/"):
            return update(id: String(path.dropFirst("/vault/v1/kv/".count)), request)
        case "DELETE" where path.hasPrefix("/vault/v1/kv/"):
            return delete(id: String(path.dropFirst("/vault/v1/kv/".count)))
        default:
            return (404, errorJSON("no fake route for \(method) \(path)"))
        }
    }

    func object(named name: String) -> FakeVaultObject? {
        objectsByName[name]
    }

    func objectCount() -> Int {
        objectsByName.count
    }

    func setConflictOnce() {
        conflictOnNextSecretUpdate = true
    }

    func setRejectNamesWithColon() {
        rejectNamesWithColon = true
    }

    func setRejectReadNamesLongerThan(_ cap: Int) {
        rejectReadNamesLongerThan = cap
    }

    func setKEK(reads: Int, writes: Int) {
        kekReadsRemaining = reads
        kekWritesRemaining = writes
    }

    func setUpdatesAlwaysConflict() {
        updatesAlwaysConflict = true
    }

    func setUpdatesAlwaysStale400() {
        updatesAlwaysStale400 = true
    }

    func setVanishAfterVersionedPuts(_ count: Int) {
        vanishAfterVersionedPuts = count
    }

    func setScript(_ script: (@Sendable (URLRequest) -> (Int, Data)?)?) {
        self.script = script
    }

    private func nextID() -> String {
        sequence += 1
        return "secret_\(sequence)"
    }

    private func create(_ request: URLRequest) -> (Int, Data) {
        if kekWritesRemaining > 0 {
            kekWritesRemaining -= 1
            return (500, errorJSON(kekMessage()))
        }
        guard let body = request.httpBody,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let name = json["name"] as? String,
            let value = json["value"] as? String
        else {
            return (400, errorJSON("malformed create body"))
        }
        if rejectNamesWithColon && name.contains(":") {
            return (400, errorJSON("Invalid object name \"\(name)\""))
        }
        if objectsByName[name] != nil {
            return (409, errorJSON("Object \"\(name)\" already exists"))
        }
        let id = nextID()
        objectsByName[name] = FakeVaultObject(id: id, name: name, value: value, version: 1)
        return (200, createJSON(id: id, version: 1))
    }

    private func readByName(_ path: String) -> (Int, Data) {
        if kekReadsRemaining > 0 {
            kekReadsRemaining -= 1
            return (500, errorJSON(kekMessage()))
        }
        // `URL.path` already decoded the wire encoding, so the
        // remainder IS the object name (`%2F` restored to `/`, the
        // name's own `%3A` escapes intact). No second decode: one
        // more `removingPercentEncoding` would corrupt `%`-names.
        let name = String(path.dropFirst("/vault/v1/kv/name/".count))
        if rejectNamesWithColon && name.contains(":") {
            return (400, errorJSON("Invalid object name \"\(name)\""))
        }
        // UTF-16 units, like the executor fake's JS `.length`: the
        // server-side 200 limit was measured in those units.
        if let cap = rejectReadNamesLongerThan, name.utf16.count > cap {
            return (400, errorJSON("Invalid object name \"\(name)\""))
        }
        if let threshold = vanishAfterVersionedPuts, versionedPutsSeen >= threshold {
            vanishAfterVersionedPuts = nil
            objectsByName.removeValue(forKey: name)
        }
        guard let object = objectsByName[name] else {
            return (404, errorJSON("Object \"\(name)\" not found"))
        }
        return (200, objectJSON(object))
    }

    private func list() -> (Int, Data) {
        let items = objectsByName.values.sorted { $0.id < $1.id }.map(objectJSONFragment)
        return (200, Data("{\"data\":[\(items.joined(separator: ","))]}".utf8))
    }

    private func update(id: String, _ request: URLRequest) -> (Int, Data) {
        if kekWritesRemaining > 0 {
            kekWritesRemaining -= 1
            return (500, errorJSON(kekMessage()))
        }
        guard let entry = objectsByName.first(where: { $0.value.id == id }) else {
            return (404, errorJSON("Object \"\(id)\" not found"))
        }
        let peek = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()))
            as? [String: Any]
        if let check = peek?["version_check"] as? String, check.isEmpty == false {
            versionedPutsSeen += 1
        }
        if updatesAlwaysConflict {
            return (409, errorJSON("Version mismatch for \"\(id)\""))
        }
        if updatesAlwaysStale400 {
            return (400, errorJSON("Version is several generations behind for \"\(id)\""))
        }
        let body = request.httpBody ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let check = json?["version_check"] as? String
        if conflictOnNextSecretUpdate && entry.value.name.hasSuffix("/secrets/conflict") {
            conflictOnNextSecretUpdate = false
            return (409, errorJSON("Injected conflict for \"\(id)\""))
        }
        if let check, check.isEmpty == false, check != "v\(entry.value.version)" {
            return (409, errorJSON("Version mismatch for \"\(id)\""))
        }
        guard let value = json?["value"] as? String else {
            return (400, errorJSON("malformed update body"))
        }
        var object = entry.value
        object.value = value
        object.version += 1
        objectsByName[entry.key] = object
        return (200, objectJSON(object))
    }

    private func delete(id: String) -> (Int, Data) {
        guard let entry = objectsByName.first(where: { $0.value.id == id }) else {
            return (404, errorJSON("Object \"\(id)\" not found"))
        }
        objectsByName.removeValue(forKey: entry.key)
        return (200, Data("{\"name\":\"\(entry.value.name)\",\"success\":true}".utf8))
    }

    private func kekMessage() -> String {
        "Upstream vault error: KEK was created but is not yet ready. This request can be retried."
    }
}

private func objectJSON(_ object: FakeVaultObject) -> Data {
    Data(objectJSONFragment(object).utf8)
}

private func objectJSONFragment(_ object: FakeVaultObject) -> String {
    "{\"id\":\"\(jsonEscape(object.id))\",\"name\":\"\(jsonEscape(object.name))\"," +
        "\"value\":\"\(jsonEscape(object.value))\",\"metadata\":{\"version_id\":\"v\(object.version)\"}}"
}

private func jsonEscape(_ text: String) -> String {
    var escaped = ""
    escaped.reserveCapacity(text.utf8.count)
    for scalar in text.unicodeScalars {
        switch scalar.value {
        case 0x22:
            escaped.append("\\\"")
        case 0x5C:
            escaped.append("\\\\")
        case 0x0A:
            escaped.append("\\n")
        case 0x0D:
            escaped.append("\\r")
        case 0x09:
            escaped.append("\\t")
        case 0x00..<0x20:
            escaped.append(String(format: "\\u%04x", scalar.value))
        default:
            escaped.append(Character(scalar))
        }
    }
    return escaped
}

private func vaultTransport(_ server: FakeVaultServer) -> WorkOSVaultTransport {
    { request in
        let (status, data) = await server.respond(to: request)
        let url = request.url ?? URL(string: "https://api.workos.com/")!
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}

private func makeWorkOSClient(
    server: FakeVaultServer,
    endpoint: String = "https://api.workos.com",
    apiKey: String = "test-key",
    timeout: Double = 10
) throws -> WorkOSVaultHTTPClient {
    try WorkOSVaultHTTPClient(
        endpoint: URL(string: endpoint)!, apiKey: apiKey,
        timeoutSeconds: timeout, transport: vaultTransport(server)
    )
}

/// Recorded backoff delays for one provider under test.
private final class SleepBox: Sendable {
    let mutex = Mutex<[Double]>([])

    func record(_ seconds: Double) {
        mutex.withLock { $0.append(seconds) }
    }

    var delays: [Double] {
        mutex.withLock { $0 }
    }
}

/// Mutable clock box for deterministic metadata timestamps.
private final class WorkOSClockBox: Sendable {
    let mutex: Mutex<Date>

    init(_ date: Date) {
        mutex = Mutex(date)
    }

    func now() -> Date { mutex.withLock { $0 } }

    func advance(by seconds: Double) {
        mutex.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

private struct WorkOSProviderHarness: Sendable {
    let provider: WorkOSVaultSecretsProvider
    let store: WorkOSVaultMetadataStore
    let server: FakeVaultServer
    let sleeps: SleepBox
}

private func makeWorkOSProvider(
    server: FakeVaultServer? = nil,
    binding: WorkOSVaultOwnerBinding = WorkOSVaultOwnerBinding(tenant: "tenant-a"),
    store: WorkOSVaultMetadataStore? = nil,
    objectPrefix: String = "executor",
    retryPolicy: WorkOSVaultRetryPolicy = WorkOSVaultRetryPolicy(),
    jitterUnit: Double = 0,
    clock: WorkOSClockBox? = nil
) async throws -> WorkOSProviderHarness {
    let server = server ?? FakeVaultServer()
    let client = try makeWorkOSClient(server: server)
    let store = try store ?? WorkOSVaultMetadataStore(path: ":memory:")
    let sleeps = SleepBox()
    let jitter: WorkOSVaultJitterSource = { jitterUnit }
    let sleeper: WorkOSVaultSleeper = { seconds in sleeps.record(seconds) }
    var now: WorkOSVaultClock?
    if let clock {
        now = { clock.now() }
    }
    let provider = try WorkOSVaultSecretsProvider(
        client: client, store: store, binding: binding,
        objectPrefix: objectPrefix, retryPolicy: retryPolicy,
        jitter: jitter, sleeper: sleeper, now: now
    )
    return WorkOSProviderHarness(provider: provider, store: store, server: server, sleeps: sleeps)
}

/// Metadata double that throws a scripted error on every op.
private actor ThrowingMetadataStore: WorkOSVaultMetadata {
    let error: Error

    init(error: Error) {
        self.error = error
    }

    func get(id: String, tenant: String, subject: String?) async throws -> WorkOSVaultMetadataRow? {
        throw error
    }

    func upsert(
        _ row: WorkOSVaultMetadataRow, tenant: String, owner: WorkOSVaultOwner, subject: String?
    ) async throws {
        throw error
    }

    func remove(
        id: String, tenant: String, subject: String?
    ) async throws -> Bool {
        throw error
    }

    func list(tenant: String, subject: String?) async throws -> [WorkOSVaultMetadataRow] {
        throw error
    }
}

private struct FakeStoreDefect: Error {}

private func makeTempWorkOSDir(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
}

#if canImport(SQLite3)
private func workOSPosixPermissions(of url: URL) throws -> Int {
    let raw = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    return try #require(raw) & 0o777
}

/// Runs raw SQL on a second connection to a store file, for sabotage tests.
private func sabotageExec(path: String, sql: String) -> Int32 {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
        if let db { _ = sqlite3_close(db) }
        return -1
    }
    defer { _ = sqlite3_close(db) }
    return sql.withCString { sqlite3_exec(db, $0, nil, nil, nil) }
}
#endif

@Suite("WorkOSVault configuration", .serialized)
struct WorkOSVaultConfigurationTests {
    @Test func idIsWorkOSVault() async throws {
        let harness = try await makeWorkOSProvider()
        #expect(harness.provider.id == "workos-vault")
    }

    @Test func defaultConstants() {
        #expect(WorkOSVaultHTTPClient.defaultEndpoint == "https://api.workos.com")
        #expect(WorkOSVaultHTTPClient.defaultTimeoutSeconds == 10)
        #expect(WorkOSVaultHTTPClient.maximumResponseBytes == 1_048_576)
        #expect(WorkOSVaultObjectNaming.defaultPrefix == "executor")
        #expect(WorkOSVaultObjectNaming.maximumNameLength == 200)
        #expect(WorkOSVaultMetadataStore.fileName == "workos-vault-metadata.sqlite")
        #expect(WorkOSVaultAPIKeyStore.fileName == "workos-vault-apikey.json")
    }

    @Test func liveInitSucceeds() throws {
        let live = try WorkOSVaultHTTPClient(
            endpoint: URL(string: "https://api.workos.com")!, apiKey: "sk-live"
        )
        #expect(live.endpoint.host == "api.workos.com")
        #expect(live.timeoutSeconds == 10)
    }

    @Test func endpointRejectsMalformed() throws {
        let server = FakeVaultServer()
        for endpoint in [
            "ftp://api.workos.com",
            "https://user:pass@api.workos.com",
            "https://api.workos.com?x=1",
            "https://api.workos.com#frag",
            "https://api.workos.com/vault",
            "gopher://api.workos.com",
        ] {
            #expect(
                throws: WorkOSVaultConfigurationError.invalidEndpoint,
                "rejects \(endpoint)"
            ) {
                try makeWorkOSClient(server: server, endpoint: endpoint)
            }
        }
    }

    @Test func httpLoopbackAllowed() throws {
        let server = FakeVaultServer()
        for endpoint in ["http://127.0.0.1:5392", "http://localhost:5392", "http://[::1]:5392"] {
            let client = try makeWorkOSClient(server: server, endpoint: endpoint)
            #expect(client.endpoint.absoluteString.hasPrefix("http://"))
        }
    }

    @Test func httpNonLoopbackRejected() throws {
        let server = FakeVaultServer()
        for endpoint in ["http://api.workos.com", "http://10.0.0.1:5392"] {
            #expect(
                throws: WorkOSVaultConfigurationError.httpNotAllowedForNonLoopback,
                "rejects \(endpoint)"
            ) {
                try makeWorkOSClient(server: server, endpoint: endpoint)
            }
        }
    }

    @Test func emptyAPIKeyRejected() throws {
        #expect(throws: WorkOSVaultConfigurationError.emptyAPIKey) {
            try makeWorkOSClient(server: FakeVaultServer(), apiKey: "")
        }
    }

    @Test func timeoutValidation() throws {
        let server = FakeVaultServer()
        let edge = try makeWorkOSClient(server: server, timeout: 60)
        #expect(edge.timeoutSeconds == 60)
        for timeout in [0.0, -1.0, Double.nan, Double.infinity, 60.0001] {
            #expect(
                throws: WorkOSVaultConfigurationError.invalidTimeout,
                "rejects \(timeout)"
            ) {
                try makeWorkOSClient(server: server, timeout: timeout)
            }
        }
    }

    @Test func prefixValidation() async throws {
        let server = FakeVaultServer()
        let client = try makeWorkOSClient(server: server)
        let store = try WorkOSVaultMetadataStore(path: ":memory:")
        let binding = WorkOSVaultOwnerBinding(tenant: "tenant-a")
        let good = try WorkOSVaultSecretsProvider(client: client, store: store, binding: binding)
        #expect(good.id == "workos-vault")
        for prefix in ["", "a/b", "has space", "tab\there", "nl\n", "nul\0", "with/slash/"] {
            #expect(
                throws: WorkOSVaultConfigurationError.invalidPrefix,
                "rejects \(prefix.debugDescription)"
            ) {
                try WorkOSVaultSecretsProvider(
                    client: client, store: store, binding: binding, objectPrefix: prefix
                )
            }
        }
    }

    @Test func emptyTenantRejected() async throws {
        let server = FakeVaultServer()
        let client = try makeWorkOSClient(server: server)
        let store = try WorkOSVaultMetadataStore(path: ":memory:")
        #expect(throws: WorkOSVaultConfigurationError.emptyTenant) {
            try WorkOSVaultSecretsProvider(
                client: client, store: store,
                binding: WorkOSVaultOwnerBinding(tenant: "")
            )
        }
    }

    @Test func defaultSeamsWork() async throws {
        // Nil seams install the production defaults (random jitter,
        // wall-clock sleep and time). A conflicted write sleeps for
        // real once (25-50 ms) and succeeds.
        let server = FakeVaultServer()
        await server.setConflictOnce()
        let client = try makeWorkOSClient(server: server)
        let store = try WorkOSVaultMetadataStore(path: ":memory:")
        let provider = try WorkOSVaultSecretsProvider(
            client: client, store: store,
            binding: WorkOSVaultOwnerBinding(tenant: "tenant-a"),
            jitter: nil, sleeper: nil, now: nil
        )
        try await provider.set("conflict", value: "v1")
        try await provider.set("conflict", value: "v2")
        #expect(try await provider.value(forItem: "conflict") == "v2")
    }
}

@Suite("WorkOSVault ownership and naming", .serialized)
struct WorkOSVaultNamingTests {
    @Test func embeddedOwnerScoped() {
        for prefix in ["connection", "oauth", "oauth-client"] {
            #expect(WorkOSVaultItemOwner.embedded(in: "\(prefix):org:a:b") == .org)
            #expect(WorkOSVaultItemOwner.embedded(in: "\(prefix):user:a:b") == .user)
        }
        // Only the second segment matters, like the executor split.
        #expect(WorkOSVaultItemOwner.embedded(in: "connection:org") == .org)
        #expect(WorkOSVaultItemOwner.embedded(in: "oauth:user:x:refresh:store-probe") == .user)
    }

    @Test func embeddedOwnerLegacy() {
        for id in [
            "secret_abc123", "github-token", "", ":", "connection:", "connection::x",
            "connection:ORG:x", "connection:orgx:x", "conn:org:x", "oauth2:org:x",
            "CONNECTION:org:x", "connection: org:x",
        ] {
            #expect(WorkOSVaultItemOwner.embedded(in: id) == nil, "legacy \(id.debugDescription)")
        }
    }

    @Test func ownerForItemFallsBackToBinding() {
        let user = WorkOSVaultOwnerBinding(tenant: "t", subject: "s")
        let org = WorkOSVaultOwnerBinding(tenant: "t")
        #expect(WorkOSVaultItemOwner.ownerForItem(id: "token", binding: user) == .user)
        #expect(WorkOSVaultItemOwner.ownerForItem(id: "token", binding: org) == .org)
        #expect(WorkOSVaultItemOwner.ownerForItem(id: "secret_x", binding: user) == .user)
        // Embedded owners win over the caller binding.
        #expect(WorkOSVaultItemOwner.ownerForItem(id: "connection:org:a:b:c", binding: user) == .org)
        #expect(WorkOSVaultItemOwner.ownerForItem(id: "connection:user:a:b:c", binding: org) == .user)
    }

    @Test func scopeSegmentsShapes() {
        let user = WorkOSVaultOwnerBinding(tenant: "tenant-a", subject: "subject-a")
        let org = WorkOSVaultOwnerBinding(tenant: "tenant-a")
        #expect(
            WorkOSVaultObjectNaming.scopeSegments(id: "connection:user:n:c:t", binding: user)
                == ["user", "tenant-a", "subject-a"]
        )
        #expect(
            WorkOSVaultObjectNaming.scopeSegments(id: "connection:org:n:c:t", binding: user)
                == ["org", "tenant-a"]
        )
        #expect(WorkOSVaultObjectNaming.scopeSegments(id: "secret_x", binding: user) == nil)
        #expect(WorkOSVaultObjectNaming.scopeSegments(id: "secret_x", binding: org) == nil)
        // A user-owned id under an automation binding files an empty subject.
        #expect(
            WorkOSVaultObjectNaming.scopeSegments(id: "oauth:user:i:n", binding: org)
                == ["user", "tenant-a", ""]
        )
    }

    @Test func objectNameShapes() {
        let user = WorkOSVaultOwnerBinding(tenant: "tenant-a", subject: "subject-a")
        #expect(
            WorkOSVaultObjectNaming.objectName(prefix: "executor", id: "github-token", binding: user)
                == "executor/secrets/github-token"
        )
        #expect(
            WorkOSVaultObjectNaming.objectName(
                prefix: "executor", id: "connection:org:exa:ws:token", binding: user
            ) == "executor/org/tenant-a/secrets/connection%3Aorg%3Aexa%3Aws%3Atoken"
        )
        #expect(
            WorkOSVaultObjectNaming.objectName(
                prefix: "executor", id: "connection:user:no:pe:token", binding: user
            ) == "executor/user/tenant-a/subject-a/secrets/connection%3Auser%3Ano%3Ape%3Atoken"
        )
        #expect(
            WorkOSVaultObjectNaming.objectName(prefix: "p9", id: "x", binding: user)
                == "p9/secrets/x"
        )
    }

    @Test func encodeSegmentMatchesJS() {
        // Vectors pinned against JS `encodeURIComponent`.
        let vectors: [(String, String)] = [
            ("user-org:u1:org42", "user-org%3Au1%3Aorg42"),
            ("a/b c+d?e=f&g#h", "a%2Fb%20c%2Bd%3Fe%3Df%26g%23h"),
            ("sécret-ünïcödé", "s%C3%A9cret-%C3%BCn%C3%AFc%C3%B6d%C3%A9"),
            ("AZaz09-_.!~*'()", "AZaz09-_.!~*'()"),
            ("100%", "100%25"),
            ("", ""),
            ("日本語", "%E6%97%A5%E6%9C%AC%E8%AA%9E"),
        ]
        for (plain, encoded) in vectors {
            #expect(
                WorkOSVaultObjectNaming.encodeSegment(plain) == encoded,
                "encodes \(plain.debugDescription)"
            )
        }
    }

    @Test func pathSegmentEncoding() {
        #expect(
            WorkOSVaultHTTPClient.encodePathSegment("a/b:c% d")
                == "a%2Fb%3Ac%25%20d"
        )
        #expect(WorkOSVaultHTTPClient.encodePathSegment("AZaz09-._~") == "AZaz09-._~")
        // encodeURIComponent survivors that RFC 3986 encodes.
        #expect(WorkOSVaultHTTPClient.encodePathSegment("!'()*") == "%21%27%28%29%2A")
        #expect(WorkOSVaultHTTPClient.encodePathSegment("") == "")
    }

    @Test func percentEncoderNibbles() {
        #expect(WorkOSVaultObjectNaming.nibbleChar(0) == "0")
        #expect(WorkOSVaultObjectNaming.nibbleChar(9) == "9")
        #expect(WorkOSVaultObjectNaming.nibbleChar(10) == "A")
        #expect(WorkOSVaultObjectNaming.nibbleChar(15) == "F")
        #expect(WorkOSVaultObjectNaming.isAllowed(0x41, in: .rfc3986Unreserved))
        #expect(WorkOSVaultObjectNaming.isAllowed(0x2D, in: .rfc3986Unreserved))
        #expect(WorkOSVaultObjectNaming.isAllowed(0x27, in: .encodeURIComponent))
        #expect(WorkOSVaultObjectNaming.isAllowed(0x27, in: .rfc3986Unreserved) == false)
        #expect(WorkOSVaultObjectNaming.isAllowed(0x2F, in: .encodeURIComponent) == false)
        #expect(WorkOSVaultObjectNaming.isAllowed(0x80, in: .encodeURIComponent) == false)
    }

    @Test func sha256Base64URLVectors() {
        // NIST vectors through the base64url projection.
        #expect(
            WorkOSVaultObjectNaming.sha256Base64URL("")
                == "47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU"
        )
        #expect(
            WorkOSVaultObjectNaming.sha256Base64URL("abc")
                == "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0"
        )
        let digest = WorkOSVaultObjectNaming.sha256Base64URL("abc")
        #expect(digest.count == 43)
        #expect(digest.contains("+") == false)
        #expect(digest.contains("/") == false)
        #expect(digest.contains("=") == false)
    }

    @Test func hexBytesTotal() {
        #expect(WorkOSVaultObjectNaming.hexBytes("") == [])
        #expect(WorkOSVaultObjectNaming.hexBytes("00ff7A") == [0x00, 0xFF, 0x7A])
        #expect(WorkOSVaultObjectNaming.hexBytes("ABCDEF") == [0xAB, 0xCD, 0xEF])
        // Non-nibbles decode as zero; a trailing lone nibble drops.
        #expect(WorkOSVaultObjectNaming.hexBytes("zz") == [0x00])
        #expect(WorkOSVaultObjectNaming.hexBytes("0") == [])
        #expect(WorkOSVaultObjectNaming.hexBytes("0g1") == [0x00])
        #expect(WorkOSVaultObjectNaming.nibbleValue("0") == 0)
        #expect(WorkOSVaultObjectNaming.nibbleValue("9") == 9)
        #expect(WorkOSVaultObjectNaming.nibbleValue("a") == 10)
        #expect(WorkOSVaultObjectNaming.nibbleValue("f") == 15)
        #expect(WorkOSVaultObjectNaming.nibbleValue("A") == 10)
        #expect(WorkOSVaultObjectNaming.nibbleValue("F") == 15)
        #expect(WorkOSVaultObjectNaming.nibbleValue("z") == 0)
        #expect(WorkOSVaultObjectNaming.nibbleValue(Unicode.Scalar(0xE9)!) == 0)
        #expect(WorkOSVaultObjectNaming.nibbleValue(Unicode.Scalar(0x1F600)!) == 0)
    }

    @Test func objectNameCapBoundary() {
        let binding = WorkOSVaultOwnerBinding(tenant: "t")
        // Flat head "executor/secrets/" is 17 chars; pad the tail.
        let atCap = String(repeating: "a", count: 183)
        let literal = WorkOSVaultObjectNaming.objectName(prefix: "executor", id: atCap, binding: binding)
        #expect(literal == "executor/secrets/\(atCap)")
        #expect(literal.count == 200)
        let overCap = String(repeating: "a", count: 184)
        let hashed = WorkOSVaultObjectNaming.objectName(prefix: "executor", id: overCap, binding: binding)
        #expect(hashed.hasPrefix("executor/secrets/h~"))
        #expect(hashed.count < 200)
        // Deterministic, id-sensitive, and partition-attributable.
        #expect(hashed == WorkOSVaultObjectNaming.objectName(prefix: "executor", id: overCap, binding: binding))
        let other = WorkOSVaultObjectNaming.objectName(prefix: "executor", id: overCap + "b", binding: binding)
        #expect(other != hashed)
        // A non-ASCII long id measures its encoded (ASCII) length.
        let wide = String(repeating: "é", count: 100)
        let wideName = WorkOSVaultObjectNaming.objectName(prefix: "executor", id: wide, binding: binding)
        #expect(wideName.hasPrefix("executor/secrets/h~"))
        // Scoped heads keep their literal partition under hashing.
        let user = WorkOSVaultOwnerBinding(tenant: "tenant-a", subject: "subject-a")
        let scoped = WorkOSVaultObjectNaming.objectName(
            prefix: "executor", id: "connection:user:\(String(repeating: "n", count: 300))",
            binding: user
        )
        #expect(scoped.hasPrefix("executor/user/tenant-a/subject-a/secrets/h~"))
        #expect(scoped.count < 200)
    }

    @Test func objectNameCapCountsUTF16Units() {
        // Executor parity: JS `.length` counts UTF-16 units, so the
        // 200 cap must too. Prefix "p" + 91 astral emoji: 92
        // graphemes but 183 UTF-16 units. With "/secrets/" (9) and a
        // 9-char tail the name is 110 graphemes (fits) but 201
        // UTF-16 units (hashes); an 8-char tail is exactly 200 and
        // stays literal.
        let prefix = "p" + String(repeating: "\u{1F600}", count: 91)
        let binding = WorkOSVaultOwnerBinding(tenant: "t")
        let hashed = WorkOSVaultObjectNaming.objectName(
            prefix: prefix, id: String(repeating: "a", count: 9), binding: binding
        )
        #expect(hashed.hasPrefix("\(prefix)/secrets/h~"))
        // The partition head stays literal (executor parity), so a
        // giant head keeps the hashed name long too: only the tail
        // is capped, to the 43-char digest.
        let digest = hashed.dropFirst("\(prefix)/secrets/h~".count)
        #expect(digest.count == 43)
        let tail8 = String(repeating: "a", count: 8)
        let literal = WorkOSVaultObjectNaming.objectName(
            prefix: prefix, id: tail8, binding: binding
        )
        #expect(literal == "\(prefix)/secrets/\(tail8)")
        #expect(literal.utf16.count == 200)
    }

    @Test func contextShapes() {
        let user = WorkOSVaultOwnerBinding(tenant: "tenant-a", subject: "subject-a")
        let org = WorkOSVaultOwnerBinding(tenant: "tenant-a")
        #expect(
            WorkOSVaultObjectNaming.contextFor(id: "secret_x", binding: user)
                == ["app": "executor"]
        )
        #expect(
            WorkOSVaultObjectNaming.contextFor(id: "connection:org:i:n:v", binding: user)
                == ["app": "executor", "organization_id": "tenant-a"]
        )
        #expect(
            WorkOSVaultObjectNaming.contextFor(id: "oauth:user:i:n", binding: user)
                == ["app": "executor", "organization_id": "tenant-a", "user_id": "subject-a"]
        )
        #expect(
            WorkOSVaultObjectNaming.contextFor(id: "oauth:user:i:n", binding: org)
                == ["app": "executor", "organization_id": "tenant-a", "user_id": ""]
        )
        // Context passes tenant/subject through verbatim; the
        // colon-free rule is a property of the id scheme (tenant and
        // subject ids contain no `:`), asserted by the naming tests
        // above, not enforced here.
        let hostile = WorkOSVaultOwnerBinding(tenant: "a:b", subject: "c:d")
        let context = WorkOSVaultObjectNaming.contextFor(id: "connection:user:i:n:v", binding: hostile)
        #expect(context["organization_id"] == "a:b")
        #expect(context["user_id"] == "c:d")
    }
}

@Suite("WorkOSVault HTTP client", .serialized)
struct WorkOSVaultClientTests {
    @Test func descriptionRedactsAPIKey() throws {
        let client = try makeWorkOSClient(server: FakeVaultServer(), apiKey: "sk_live_secret_xyz")
        for rendered in [String(describing: client), String(reflecting: client)] {
            #expect(rendered.contains("sk_live_secret_xyz") == false)
            #expect(rendered == "WorkOSVaultHTTPClient(<redacted>)")
        }
    }

    @Test func slowTransportTimeoutMapsToTimeout() async throws {
        // A slow server surfaces as the transport's timed-out outcome
        // (what URLSession raises past `timeoutIntervalForRequest`); the
        // client maps it to the timeout kind, and the provider to the
        // typed timeout — never missing, never a silent nil.
        let transport: WorkOSVaultTransport = { _ in
            try await Task.sleep(nanoseconds: 50_000_000)
            throw URLError(.timedOut)
        }
        let client = try WorkOSVaultHTTPClient(
            endpoint: URL(string: "https://api.workos.com")!, apiKey: "k",
            timeoutSeconds: 10, transport: transport
        )
        do {
            _ = try await client.readObjectByName("executor/secrets/k")
            Issue.record("expected timeout")
        } catch let error as WorkOSVaultClientError {
            #expect(error.kind == .timeout)
        }
        let store = try WorkOSVaultMetadataStore(path: ":memory:")
        try await store.upsert(
            WorkOSVaultMetadataRow(
                id: "k", name: "k", purpose: nil,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            tenant: "t", owner: .org, subject: nil
        )
        let provider = try WorkOSVaultSecretsProvider(
            client: client, store: store,
            binding: WorkOSVaultOwnerBinding(tenant: "t")
        )
        await #expect(throws: SecretsError.timeout("workos-vault")) {
            _ = try await provider.value(forItem: "k")
        }
    }

    @Test func createRoundTrip() async throws {
        let server = FakeVaultServer()
        let client = try makeWorkOSClient(server: server)
        let metadata = try await client.createObject(
            name: "executor/secrets/k", value: "v", context: ["app": "executor"]
        )
        #expect(metadata.id == "secret_1")
        #expect(metadata.versionID == "v1")
        let requests = await server.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/vault/v1/kv")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.timeoutInterval == 10)
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["name"] as? String == "executor/secrets/k")
        #expect(json["value"] as? String == "v")
        #expect(json["key_context"] as? [String: String] == ["app": "executor"])
        #expect(request.url?.absoluteString.contains("test-key") == false)
    }

    @Test func createAcceptsAny2xx() async throws {
        let server = FakeVaultServer()
        await server.setScript { request in
            guard request.httpMethod == "POST" else { return nil }
            return (201, createJSON(id: "secret_9", version: 3))
        }
        let client = try makeWorkOSClient(server: server)
        let metadata = try await client.createObject(name: "n", value: "v", context: [:])
        #expect(metadata.id == "secret_9")
        #expect(metadata.versionID == "v3")
    }

    @Test func createDecodeFailures() async throws {
        for body in [
            Data("not json".utf8),
            Data("{\"id\":\"\"}".utf8),
            Data("{\"noid\":true}".utf8),
            Data("{\"id\":\"secret_1\"}".utf8),
            Data("{\"id\":\"secret_1\",\"metadata\":{}}".utf8),
            Data("{\"id\":\"secret_1\",\"metadata\":{\"version_id\":\"\"}}".utf8),
            Data(),
        ] {
            let server = FakeVaultServer()
            await server.setScript { _ in (200, body) }
            let client = try makeWorkOSClient(server: server)
            await #expect(throws: WorkOSVaultClientError(
                operation: "create_object", kind: .decode, retryKind: nil
            )) {
                try await client.createObject(name: "n", value: "v", context: [:])
            }
        }
    }

    @Test func create409Surfaces() async throws {
        let server = FakeVaultServer()
        let client = try makeWorkOSClient(server: server)
        _ = try await client.createObject(name: "dup", value: "v1", context: [:])
        await #expect(throws: WorkOSVaultClientError(
            operation: "create_object", kind: .httpStatus(409), retryKind: nil
        )) {
            try await client.createObject(name: "dup", value: "v2", context: [:])
        }
    }

    @Test func readRoundTripSingleSegment() async throws {
        let server = FakeVaultServer()
        let client = try makeWorkOSClient(server: server)
        _ = try await client.createObject(
            name: "executor/org/tenant-a/secrets/a%3Ab", value: "s3cr3t", context: [:]
        )
        let object = try await client.readObjectByName("executor/org/tenant-a/secrets/a%3Ab")
        #expect(object.id == "secret_1")
        #expect(object.value == "s3cr3t")
        #expect(object.metadata.versionID == "v1")
        let requests = await server.requests
        let read = try #require(requests.last)
        #expect(read.httpMethod == "GET")
        #expect(read.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        // The scoped name travels as ONE segment: slashes and the
        // literal `%` of `%3A` are re-encoded. (`absoluteString`
        // preserves the wire encoding; `.path` would decode it.)
        #expect(
            read.url?.absoluteString
                == "https://api.workos.com/vault/v1/kv/name/executor%2Forg%2Ftenant-a%2Fsecrets%2Fa%253Ab"
        )
    }

    @Test func readStatusErrors() async throws {
        for status in [400, 404, 409, 429, 500] {
            let server = FakeVaultServer()
            await server.setScript { _ in (status, errorJSON("boom")) }
            let client = try makeWorkOSClient(server: server)
            await #expect(throws: WorkOSVaultClientError(
                operation: "read_object_by_name", kind: .httpStatus(status), retryKind: nil
            )) {
                try await client.readObjectByName("whatever")
            }
        }
    }

    @Test func readDecodeFailures() async throws {
        for body in [
            Data("not json".utf8),
            Data("{\"id\":\"\",\"metadata\":{\"version_id\":\"v1\"}}".utf8),
            Data("{\"id\":\"secret_1\"}".utf8),
            Data("{\"id\":\"secret_1\",\"metadata\":{\"version_id\":\"\"}}".utf8),
        ] {
            let server = FakeVaultServer()
            await server.setScript { _ in (200, body) }
            let client = try makeWorkOSClient(server: server)
            await #expect(throws: WorkOSVaultClientError(
                operation: "read_object_by_name", kind: .decode, retryKind: nil
            )) {
                try await client.readObjectByName("whatever")
            }
        }
    }

    @Test func objectValidation() {
        let good = WorkOSVaultObjectResponse(
            id: "secret_1", name: "n", value: "v",
            metadata: WorkOSVaultMetadataResponse(versionID: "v2")
        )
        #expect(WorkOSVaultObject(validating: good)?.metadata.versionID == "v2")
        #expect(WorkOSVaultObject(validating: good)?.name == "n")
        let nameless = WorkOSVaultObjectResponse(
            id: "secret_1", name: nil, value: nil,
            metadata: WorkOSVaultMetadataResponse(versionID: "v2")
        )
        #expect(WorkOSVaultObject(validating: nameless)?.name == "")
        #expect(WorkOSVaultObject(validating: nameless)?.value == nil)
        for bad in [
            WorkOSVaultObjectResponse(
                id: "", name: nil, value: nil,
                metadata: WorkOSVaultMetadataResponse(versionID: "v1")
            ),
            WorkOSVaultObjectResponse(
                id: "secret_1", name: nil, value: nil, metadata: nil
            ),
            WorkOSVaultObjectResponse(
                id: "secret_1", name: nil, value: nil,
                metadata: WorkOSVaultMetadataResponse(versionID: "")
            ),
            WorkOSVaultObjectResponse(
                id: "secret_1", name: nil, value: nil,
                metadata: WorkOSVaultMetadataResponse(versionID: nil)
            ),
        ] {
            #expect(WorkOSVaultObject(validating: bad) == nil)
        }
        #expect(WorkOSVaultClientError(operation: "op", kind: .httpStatus(404), retryKind: nil).status == 404)
        #expect(WorkOSVaultClientError(operation: "op", kind: .timeout, retryKind: nil).status == nil)
    }

    @Test func updateRoundTrip() async throws {
        let server = FakeVaultServer()
        let client = try makeWorkOSClient(server: server)
        _ = try await client.createObject(name: "u", value: "v1", context: [:])
        let updated = try await client.updateObject(id: "secret_1", value: "v2", versionCheck: "v1")
        #expect(updated.metadata.versionID == "v2")
        #expect(updated.value == "v2")
        let requests = await server.requests
        let request = try #require(requests.last)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/vault/v1/kv/secret_1")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["value"] as? String == "v2")
        #expect(json["version_check"] as? String == "v1")
    }

    @Test func updateOmitsNilVersionCheck() async throws {
        let server = FakeVaultServer()
        let client = try makeWorkOSClient(server: server)
        _ = try await client.createObject(name: "u", value: "v1", context: [:])
        _ = try await client.updateObject(id: "secret_1", value: "v2")
        let requests = await server.requests
        let last = try #require(requests.last)
        let body = try #require(last.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["version_check"] == nil)
    }

    @Test func updateStatusErrors() async throws {
        for status in [400, 404, 409, 429, 500] {
            let server = FakeVaultServer()
            await server.setScript { _ in (status, errorJSON("boom")) }
            let client = try makeWorkOSClient(server: server)
            await #expect(throws: WorkOSVaultClientError(
                operation: "update_object", kind: .httpStatus(status), retryKind: nil
            )) {
                try await client.updateObject(id: "secret_1", value: "v")
            }
        }
    }

    @Test func updateDecodeFailures() async throws {
        let server = FakeVaultServer()
        await server.setScript { _ in (200, Data("{\"nope\":true}".utf8)) }
        let client = try makeWorkOSClient(server: server)
        await #expect(throws: WorkOSVaultClientError(
            operation: "update_object", kind: .decode, retryKind: nil
        )) {
            try await client.updateObject(id: "secret_1", value: "v")
        }
    }

    @Test func deleteRoundTrip() async throws {
        let server = FakeVaultServer()
        let client = try makeWorkOSClient(server: server)
        _ = try await client.createObject(name: "gone", value: "v", context: [:])
        try await client.deleteObject(id: "secret_1")
        #expect(await server.objectCount() == 0)
        let requests = await server.requests
        let request = try #require(requests.last)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/vault/v1/kv/secret_1")
    }

    @Test func deleteIgnoresBody() async throws {
        for body in [Data(), Data("garbage".utf8), Data("{}".utf8)] {
            let server = FakeVaultServer()
            await server.setScript { _ in (200, body) }
            let client = try makeWorkOSClient(server: server)
            try await client.deleteObject(id: "secret_1")
        }
    }

    @Test func deleteStatusErrors() async throws {
        for status in [400, 404, 409, 500] {
            let server = FakeVaultServer()
            await server.setScript { _ in (status, errorJSON("boom")) }
            let client = try makeWorkOSClient(server: server)
            await #expect(throws: WorkOSVaultClientError(
                operation: "delete_object", kind: .httpStatus(status), retryKind: nil
            )) {
                try await client.deleteObject(id: "secret_1")
            }
        }
    }

    @Test func listShapes() async throws {
        let server = FakeVaultServer()
        let client = try makeWorkOSClient(server: server)
        _ = try await client.createObject(name: "a", value: "1", context: [:])
        _ = try await client.createObject(name: "b", value: "2", context: [:])
        let objects = try await client.listObjects(limit: 1)
        #expect(objects.count == 2)
        let requests = await server.requests
        #expect(try #require(requests.last?.url?.absoluteString).contains("limit=1"))
        // Bare-array shape decodes too.
        let bare = FakeVaultServer()
        await bare.setScript { _ in
            (200, Data("[{\"id\":\"secret_1\",\"metadata\":{\"version_id\":\"v1\"}}]".utf8))
        }
        let bareClient = try makeWorkOSClient(server: bare)
        #expect(try await bareClient.listObjects().count == 1)
    }

    @Test func listDecodeFailures() async throws {
        let bodies: [Data] = [
            Data("not json".utf8),
            Data("{\"data\":[{\"id\":\"\",\"metadata\":{\"version_id\":\"v1\"}}]}".utf8),
            Data("[{\"id\":\"secret_1\"}]".utf8),
            Data("{\"data\":[]}".utf8),
        ]
        for (index, body) in bodies.enumerated() {
            let server = FakeVaultServer()
            await server.setScript { _ in (200, body) }
            let client = try makeWorkOSClient(server: server)
            if index == 3 {
                #expect(try await client.listObjects() == [])
            } else {
                await #expect(throws: WorkOSVaultClientError(
                    operation: "list_objects", kind: .decode, retryKind: nil
                )) {
                    try await client.listObjects()
                }
            }
        }
    }

    @Test func listStatusErrorsAndClamp() async throws {
        let server = FakeVaultServer()
        await server.setScript { _ in (500, errorJSON("boom")) }
        let client = try makeWorkOSClient(server: server)
        await #expect(throws: WorkOSVaultClientError(
            operation: "list_objects", kind: .httpStatus(500), retryKind: nil
        )) {
            try await client.listObjects()
        }
        let probe = FakeVaultServer()
        let probeClient = try makeWorkOSClient(server: probe)
        _ = try await probeClient.listObjects(limit: 0)
        _ = try await probeClient.listObjects(limit: 500)
        let requests = await probe.requests
        #expect(requests[0].url?.absoluteString.contains("limit=1") == true)
        #expect(requests[1].url?.absoluteString.contains("limit=100") == true)
    }

    @Test func joiningStripsBaseSlash() throws {
        let trailing = try makeWorkOSClient(
            server: FakeVaultServer(), endpoint: "https://api.workos.com/"
        )
        #expect(trailing.joining("/vault/v1/kv").absoluteString == "https://api.workos.com/vault/v1/kv")
    }

    @Test func transportMapping() async throws {
        struct Boom: Error {}
        let vectors: [(Error, WorkOSVaultClientError.Kind)] = [
            (URLError(.timedOut), .timeout),
            (URLError(.serverCertificateUntrusted), .tls),
            (URLError(.serverCertificateHasBadDate), .tls),
            (URLError(.serverCertificateHasUnknownRoot), .tls),
            (URLError(.serverCertificateNotYetValid), .tls),
            (URLError(.clientCertificateRejected), .tls),
            (URLError(.clientCertificateRequired), .tls),
            (URLError(.secureConnectionFailed), .tls),
            (URLError(.cannotConnectToHost), .unreachable),
            (URLError(.networkConnectionLost), .unreachable),
            (URLError(.badServerResponse), .unreachable),
            (Boom(), .unreachable),
        ]
        for (failure, kind) in vectors {
            let transport: WorkOSVaultTransport = { _ in throw failure }
            let client = try WorkOSVaultHTTPClient(
                endpoint: URL(string: "https://api.workos.com")!, apiKey: "k",
                timeoutSeconds: 10, transport: transport
            )
            await #expect(throws: WorkOSVaultClientError(
                operation: "read_object_by_name", kind: kind, retryKind: nil
            )) {
                try await client.readObjectByName("x")
            }
        }
    }

    @Test func transportCancellationPropagates() async throws {
        let transport: WorkOSVaultTransport = { _ in throw CancellationError() }
        let client = try WorkOSVaultHTTPClient(
            endpoint: URL(string: "https://api.workos.com")!, apiKey: "k",
            timeoutSeconds: 10, transport: transport
        )
        await #expect(throws: CancellationError.self) {
            try await client.readObjectByName("x")
        }
    }

    @Test func transportSecretsErrorPassesThrough() async throws {
        let transport: WorkOSVaultTransport = { _ in throw SecretsError.policyDenied }
        let client = try WorkOSVaultHTTPClient(
            endpoint: URL(string: "https://api.workos.com")!, apiKey: "k",
            timeoutSeconds: 10, transport: transport
        )
        await #expect(throws: SecretsError.policyDenied) {
            try await client.readObjectByName("x")
        }
    }

    @Test func oversizedBody() async throws {
        let big = Data(repeating: 0x61, count: WorkOSVaultHTTPClient.maximumResponseBytes + 1)
        let server = FakeVaultServer()
        await server.setScript { _ in (200, big) }
        let client = try makeWorkOSClient(server: server)
        await #expect(throws: WorkOSVaultClientError(
            operation: "read_object_by_name", kind: .oversized, retryKind: nil
        )) {
            try await client.readObjectByName("x")
        }
        // Oversize wins over status handling: a 404 with a huge body
        // is oversized, not missing.
        await server.setScript { _ in (404, big) }
        await #expect(throws: WorkOSVaultClientError(
            operation: "read_object_by_name", kind: .oversized, retryKind: nil
        )) {
            try await client.readObjectByName("x")
        }
    }

    @Test func kekDetection() {
        let suffix = WorkOSVaultClientError.kekNotReadySuffix
        #expect(suffix == "KEK was created but is not yet ready. This request can be retried.")
        #expect(WorkOSVaultHTTPClient.retryKind(forBody: errorJSON(suffix)) == .kekNotReady)
        #expect(
            WorkOSVaultHTTPClient.retryKind(forBody: errorJSON("Upstream: \(suffix)")) == .kekNotReady
        )
        // Near misses are not KEK errors.
        #expect(WorkOSVaultHTTPClient.retryKind(forBody: errorJSON("boom")) == nil)
        #expect(WorkOSVaultHTTPClient.retryKind(forBody: errorJSON("\(suffix) (retry 1)")) == nil)
        #expect(WorkOSVaultHTTPClient.retryKind(forBody: Data("not json".utf8)) == nil)
        #expect(WorkOSVaultHTTPClient.retryKind(forBody: Data("{\"code\":500}".utf8)) == nil)
        #expect(WorkOSVaultHTTPClient.retryKind(forBody: Data("{}".utf8)) == nil)
        #expect(WorkOSVaultHTTPClient.retryKind(forBody: Data()) == nil)
    }

    @Test func kekSurfacesOnAnyStatus() async throws {
        for status in [400, 409, 500, 503] {
            let server = FakeVaultServer()
            await server.setScript { _ in
                (status, errorJSON("x \(WorkOSVaultClientError.kekNotReadySuffix)"))
            }
            let client = try makeWorkOSClient(server: server)
            await #expect(throws: WorkOSVaultClientError(
                operation: "create_object", kind: .httpStatus(status), retryKind: .kekNotReady
            )) {
                try await client.createObject(name: "n", value: "v", context: [:])
            }
        }
    }
}

@Suite("WorkOSVault retry policy", .serialized)
struct WorkOSVaultRetryPolicyTests {
    @Test func defaultConstants() {
        let policy = WorkOSVaultRetryPolicy()
        #expect(policy.maxWriteAttempts == 5)
        #expect(policy.conflictBackoffBaseMs == 50)
        #expect(policy.conflictBackoffCapMs == 800)
        #expect(policy.maxKEKAttempts == 20)
        #expect(policy.kekBackoffMs == 1_000)
        #expect(policy.kekBackoffSeconds == 1)
    }

    @Test func backoffMath() {
        let policy = WorkOSVaultRetryPolicy()
        // Attempt 1: ceiling 50ms, draw from [25, 50) ms.
        #expect(policy.conflictBackoffSeconds(attempt: 1, jitterUnit: 0) == 0.025)
        #expect(policy.conflictBackoffSeconds(attempt: 1, jitterUnit: 1) == 0.05)
        #expect(policy.conflictBackoffSeconds(attempt: 1, jitterUnit: 0.5) == 0.0375)
        // Attempt 2: ceiling 100ms.
        #expect(policy.conflictBackoffSeconds(attempt: 2, jitterUnit: 0) == 0.05)
        // Attempt 5: ceiling 800ms (capped, not 1600).
        #expect(policy.conflictBackoffSeconds(attempt: 5, jitterUnit: 0) == 0.4)
        #expect(policy.conflictBackoffSeconds(attempt: 99, jitterUnit: 1) == 0.8)
        // Defensive clamps: attempt floor, jitter unit clamp.
        #expect(policy.conflictBackoffSeconds(attempt: 0, jitterUnit: 0) == 0.025)
        #expect(policy.conflictBackoffSeconds(attempt: -3, jitterUnit: 0) == 0.025)
        #expect(policy.conflictBackoffSeconds(attempt: 1, jitterUnit: -2) == 0.025)
        #expect(policy.conflictBackoffSeconds(attempt: 1, jitterUnit: 2) == 0.05)
    }

    @Test func policyClamps() {
        let policy = WorkOSVaultRetryPolicy(
            maxWriteAttempts: 0, conflictBackoffBaseMs: -1,
            conflictBackoffCapMs: -1, maxKEKAttempts: -5, kekBackoffMs: -9
        )
        #expect(policy.maxWriteAttempts == 1)
        #expect(policy.conflictBackoffBaseMs == 0)
        #expect(policy.conflictBackoffCapMs == 0)
        #expect(policy.maxKEKAttempts == 1)
        #expect(policy.kekBackoffMs == 0)
        #expect(policy.kekBackoffSeconds == 0)
    }

    @Test func writeContentionRule() {
        let contention = { (status: Int) in
            WorkOSVaultSecretsProvider.isWriteContention(
                WorkOSVaultClientError(operation: "update_object", kind: .httpStatus(status), retryKind: nil)
            )
        }
        #expect(contention(409))
        #expect(contention(400))
        #expect(contention(404) == false)
        #expect(contention(500) == false)
        #expect(WorkOSVaultSecretsProvider.isWriteContention(
            WorkOSVaultClientError(operation: "update_object", kind: .timeout, retryKind: nil)
        ) == false)
    }
}

@Suite("WorkOSVault metadata store", .serialized)
struct WorkOSVaultMetadataStoreTests {
    #if canImport(SQLite3)
    @Test func databaseFileIsOwnerOnly() throws {
        let dir = try makeTempWorkOSDir(prefix: "rv-workos-mode")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(WorkOSVaultMetadataStore.fileName)
        _ = try WorkOSVaultMetadataStore(path: url.path)
        #expect(try workOSPosixPermissions(of: url) == 0o600)
        // A pre-existing lax file tightens on open.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        _ = try WorkOSVaultMetadataStore(path: url.path)
        #expect(try workOSPosixPermissions(of: url) == 0o600)
    }

    @Test func databaseInMissingDirectoryFailsClosed() throws {
        let dir = try makeTempWorkOSDir(prefix: "rv-workos-mode")
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir
            .appendingPathComponent("no-such-dir")
            .appendingPathComponent(WorkOSVaultMetadataStore.fileName)
        #expect(throws: WorkOSVaultStoreError.storeFailure) {
            _ = try WorkOSVaultMetadataStore(path: missing.path)
        }
    }
    #endif

    @Test func crudRoundTrip() async throws {
        let store = try WorkOSVaultMetadataStore(path: ":memory:")
        let row = WorkOSVaultMetadataRow(
            id: "k", name: "display", purpose: "login",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(try await store.get(id: "k", tenant: "t", subject: nil) == nil)
        try await store.upsert(row, tenant: "t", owner: .org, subject: nil)
        #expect(try await store.get(id: "k", tenant: "t", subject: nil) == row)
        #expect(try await store.remove(id: "k", tenant: "t", subject: nil))
        #expect(try await store.get(id: "k", tenant: "t", subject: nil) == nil)
        #expect(try await store.remove(id: "k", tenant: "t", subject: nil) == false)
    }

    @Test func upsertReplacesAndNullPurpose() async throws {
        let store = try WorkOSVaultMetadataStore(path: ":memory:")
        let first = WorkOSVaultMetadataRow(
            id: "k", name: "one", purpose: "p", createdAt: Date(timeIntervalSince1970: 100)
        )
        let second = WorkOSVaultMetadataRow(
            id: "k", name: "two", purpose: nil, createdAt: Date(timeIntervalSince1970: 200)
        )
        try await store.upsert(first, tenant: "t", owner: .org, subject: nil)
        try await store.upsert(second, tenant: "t", owner: .org, subject: nil)
        let read = try #require(try await store.get(id: "k", tenant: "t", subject: nil))
        #expect(read == second)
        #expect(read.purpose == nil)
    }

    @Test func listSortedOldestFirst() async throws {
        let store = try WorkOSVaultMetadataStore(path: ":memory:")
        for (id, seconds) in [("c", 300.0), ("a", 100.0), ("b", 200.0)] {
            try await store.upsert(
                WorkOSVaultMetadataRow(
                    id: id, name: id, purpose: nil,
                    createdAt: Date(timeIntervalSince1970: seconds)
                ),
                tenant: "t", owner: .org, subject: nil
            )
        }
        let listed = try await store.list(tenant: "t", subject: nil)
        #expect(listed.map(\.id) == ["a", "b", "c"])
    }

    @Test func listTieBreaksByInsertion() async throws {
        let store = try WorkOSVaultMetadataStore(path: ":memory:")
        let same = Date(timeIntervalSince1970: 1_700_000_000)
        for id in ["second", "first", "third"] {
            try await store.upsert(
                WorkOSVaultMetadataRow(id: id, name: id, purpose: nil, createdAt: same),
                tenant: "t", owner: .org, subject: nil
            )
        }
        // Equal timestamps keep insertion order (rowid tiebreak).
        #expect(try await store.list(tenant: "t", subject: nil).map(\.id) == ["second", "first", "third"])
    }

    @Test func visibilityRules() async throws {
        let store = try WorkOSVaultMetadataStore(path: ":memory:")
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.upsert(
            WorkOSVaultMetadataRow(id: "shared", name: "shared", purpose: nil, createdAt: at),
            tenant: "t", owner: .org, subject: "subject-a"
        )
        try await store.upsert(
            WorkOSVaultMetadataRow(id: "mine", name: "mine", purpose: nil, createdAt: at),
            tenant: "t", owner: .user, subject: "subject-a"
        )
        // Bound subject sees its own user rows plus org rows.
        #expect(try await store.get(id: "shared", tenant: "t", subject: "subject-a") != nil)
        #expect(try await store.get(id: "mine", tenant: "t", subject: "subject-a") != nil)
        #expect(try await store.get(id: "mine", tenant: "t", subject: "subject-b") == nil)
        #expect(try await store.get(id: "shared", tenant: "t", subject: "subject-b") != nil)
        // Automation sees org rows only.
        #expect(try await store.get(id: "shared", tenant: "t", subject: nil) != nil)
        #expect(try await store.get(id: "mine", tenant: "t", subject: nil) == nil)
        #expect(try await store.list(tenant: "t", subject: "subject-a").count == 2)
        #expect(try await store.list(tenant: "t", subject: "subject-b").map(\.id) == ["shared"])
        #expect(try await store.list(tenant: "t", subject: nil).map(\.id) == ["shared"])
    }

    @Test func tenantIsolation() async throws {
        let store = try WorkOSVaultMetadataStore(path: ":memory:")
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.upsert(
            WorkOSVaultMetadataRow(id: "k", name: "one", purpose: nil, createdAt: at),
            tenant: "tenant-1", owner: .org, subject: nil
        )
        #expect(try await store.get(id: "k", tenant: "tenant-2", subject: nil) == nil)
        #expect(try await store.list(tenant: "tenant-2", subject: nil) == [])
    }

    @Test func userPrefersOwnRow() async throws {
        let store = try WorkOSVaultMetadataStore(path: ":memory:")
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.upsert(
            WorkOSVaultMetadataRow(id: "k", name: "org-row", purpose: nil, createdAt: at),
            tenant: "t", owner: .org, subject: nil
        )
        try await store.upsert(
            WorkOSVaultMetadataRow(id: "k", name: "user-row", purpose: nil, createdAt: at),
            tenant: "t", owner: .user, subject: "s"
        )
        // Same id in both partitions: a bound subject reads its own first.
        #expect(try await store.get(id: "k", tenant: "t", subject: "s")?.name == "user-row")
        #expect(try await store.get(id: "k", tenant: "t", subject: nil)?.name == "org-row")
    }

    @Test func removeDeletesFoundPartition() async throws {
        // A legacy id filed by automation (org partition), removed
        // through a bound subject's view: removal targets the visible
        // org row — the row `get` returns — not the caller's empty
        // user partition. Deleting the computed partition instead
        // would report success while orphaning the row.
        let store = try WorkOSVaultMetadataStore(path: ":memory:")
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.upsert(
            WorkOSVaultMetadataRow(id: "k", name: "k", purpose: nil, createdAt: at),
            tenant: "t", owner: .org, subject: nil
        )
        #expect(try await store.remove(id: "k", tenant: "t", subject: "subject-a"))
        #expect(try await store.get(id: "k", tenant: "t", subject: nil) == nil)
        #expect(try await store.list(tenant: "t", subject: nil) == [])
        #expect(try await store.remove(id: "k", tenant: "t", subject: "subject-a") == false)
    }

    @Test func removePrefersOwnRow() async throws {
        // Same id in both partitions: a bound subject's remove
        // deletes its own user row first, leaving the org row for a
        // second remove (mirroring `get` order).
        let store = try WorkOSVaultMetadataStore(path: ":memory:")
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.upsert(
            WorkOSVaultMetadataRow(id: "k", name: "org-row", purpose: nil, createdAt: at),
            tenant: "t", owner: .org, subject: nil
        )
        try await store.upsert(
            WorkOSVaultMetadataRow(id: "k", name: "user-row", purpose: nil, createdAt: at),
            tenant: "t", owner: .user, subject: "s"
        )
        #expect(try await store.remove(id: "k", tenant: "t", subject: "s"))
        #expect(try await store.get(id: "k", tenant: "t", subject: "s")?.name == "org-row")
        #expect(try await store.remove(id: "k", tenant: "t", subject: "s"))
        #expect(try await store.get(id: "k", tenant: "t", subject: "s") == nil)
    }

    @Test func nulBytesRoundTripThroughStore() async throws {
        // NUL bytes are data, not terminators: ids differing at or
        // after a NUL stay distinct rows with exact ids.
        let store = try WorkOSVaultMetadataStore(path: ":memory:")
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        for id in ["a\0b", "a", "\0", "a\0"] {
            try await store.upsert(
                WorkOSVaultMetadataRow(id: id, name: "n-\(id)", purpose: nil, createdAt: at),
                tenant: "t", owner: .org, subject: nil
            )
        }
        for id in ["a\0b", "a", "\0", "a\0"] {
            #expect(try await store.get(id: id, tenant: "t", subject: nil)?.id == id)
        }
        #expect(try await store.list(tenant: "t", subject: nil).count == 4)
    }

    // SQLite persistence semantics: cross-instance file sharing is
    // meaningless for the in-memory fallback (Linux), which ignores
    // paths by design.
    #if canImport(SQLite3)
    @Test func filePersistence() async throws {
        let dir = try makeTempWorkOSDir(prefix: "rv-workos-meta")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent(WorkOSVaultMetadataStore.fileName).path
        let first = try WorkOSVaultMetadataStore(path: path)
        try await first.upsert(
            WorkOSVaultMetadataRow(
                id: "k", name: "n", purpose: "p",
                createdAt: Date(timeIntervalSince1970: 42)
            ),
            tenant: "t", owner: .org, subject: nil
        )
        let second = try WorkOSVaultMetadataStore(path: path)
        #expect(try await second.get(id: "k", tenant: "t", subject: nil)?.name == "n")
        #expect(try await second.list(tenant: "t", subject: nil).count == 1)
    }
    #endif

    // SQLite open semantics: the in-memory fallback (Linux) never
    // touches the filesystem, so path-based open failures cannot occur.
    #if canImport(SQLite3)
    @Test func initFailures() throws {
        // Missing parent directory: open fails.
        #expect(throws: WorkOSVaultStoreError.storeFailure) {
            try WorkOSVaultMetadataStore(
                path: "/nonexistent-dir-\(UUID().uuidString)/meta.sqlite"
            )
        }
        // Garbage file: open succeeds, table creation fails.
        let garbage = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-workos-garbage-\(UUID().uuidString).sqlite")
        try Data("this is not a database".utf8).write(to: garbage)
        defer { try? FileManager.default.removeItem(at: garbage) }
        #expect(throws: WorkOSVaultStoreError.storeFailure) {
            try WorkOSVaultMetadataStore(path: garbage.path)
        }
    }
    #endif

    @Test func partitionHelpers() {
        #expect(WorkOSVaultMetadataStore.visibleOwners(subject: "s").count == 2)
        #expect(WorkOSVaultMetadataStore.visibleOwners(subject: nil).count == 1)
        let bound = WorkOSVaultMetadataStore.visibleOwners(subject: "s")
        #expect(bound[0].owner == .user && bound[0].subject == "s")
        #expect(bound[1].owner == .org && bound[1].subject == "")
        #expect(WorkOSVaultMetadataStore.storedSubject(owner: .org, subject: "s") == "")
        #expect(WorkOSVaultMetadataStore.storedSubject(owner: .user, subject: "s") == "s")
        #expect(WorkOSVaultMetadataStore.storedSubject(owner: .user, subject: nil) == "")
    }

    @Test func corruptRowDecode() {
        #expect(WorkOSVaultMetadataStore.decodeSelectedRow(
            id: "k", name: "n", purpose: "p", createdAtMs: 1_700_000_000_000
        )?.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(WorkOSVaultMetadataStore.decodeSelectedRow(
            id: "k", name: "n", purpose: nil, createdAtMs: 0
        ) != nil)
        // Corrupt tuples read as missing.
        #expect(WorkOSVaultMetadataStore.decodeSelectedRow(
            id: "", name: "n", purpose: nil, createdAtMs: 1
        ) == nil)
        #expect(WorkOSVaultMetadataStore.decodeSelectedRow(
            id: "k", name: "", purpose: nil, createdAtMs: 1
        ) == nil)
        #expect(WorkOSVaultMetadataStore.decodeSelectedRow(
            id: "k", name: "n", purpose: nil, createdAtMs: -1
        ) == nil)
        #expect(WorkOSVaultMetadataStore.decodeSelectedRow(
            id: nil, name: "n", purpose: nil, createdAtMs: 1
        ) == nil)
        #expect(WorkOSVaultMetadataStore.decodeSelectedRow(
            id: "k", name: nil, purpose: nil, createdAtMs: 1
        ) == nil)
    }

    @Test func unicodeAndHostileIds() async throws {
        let store = try WorkOSVaultMetadataStore(path: ":memory:")
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        // Quotes and SQL keywords travel as bound values, never syntax.
        let hostile = ["'; DROP TABLE metadata; --", "a\"b", "x\ny", "日本語🎉", "a:b/c?d=e&f"]
        for id in hostile {
            try await store.upsert(
                WorkOSVaultMetadataRow(id: id, name: id, purpose: nil, createdAt: at),
                tenant: "t", owner: .org, subject: nil
            )
        }
        for id in hostile {
            #expect(try await store.get(id: id, tenant: "t", subject: nil)?.id == id)
        }
        #expect(try await store.list(tenant: "t", subject: nil).count == hostile.count)
    }

    @Test func concurrentUpserts() async throws {
        let store = try WorkOSVaultMetadataStore(path: ":memory:")
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    try? await store.upsert(
                        WorkOSVaultMetadataRow(
                            id: "k\(index)", name: "k\(index)", purpose: nil, createdAt: at
                        ),
                        tenant: "t", owner: .org, subject: nil
                    )
                }
            }
        }
        #expect(try await store.list(tenant: "t", subject: nil).count == 50)
    }

    #if canImport(SQLite3)
    @Test func droppedTableReadsMissingWritesFail() async throws {
        let dir = try makeTempWorkOSDir(prefix: "rv-workos-drop")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("meta.sqlite").path
        let store = try WorkOSVaultMetadataStore(path: path)
        try await store.upsert(
            WorkOSVaultMetadataRow(
                id: "k", name: "n", purpose: nil,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            tenant: "t", owner: .org, subject: nil
        )
        #expect(sabotageExec(path: path, sql: "DROP TABLE metadata") == SQLITE_OK)
        // Reads fail soft (missing / empty); writes fail hard.
        #expect(try await store.get(id: "k", tenant: "t", subject: nil) == nil)
        #expect(try await store.list(tenant: "t", subject: nil) == [])
        await #expect(throws: WorkOSVaultStoreError.storeFailure) {
            try await store.upsert(
                WorkOSVaultMetadataRow(
                    id: "k", name: "n", purpose: nil,
                    createdAt: Date(timeIntervalSince1970: 1)
                ),
                tenant: "t", owner: .org, subject: nil
            )
        }
        // Remove short-circuits on the missing read: no throw, false.
        #expect(try await store.remove(id: "k", tenant: "t", subject: nil) == false)
    }

    #if canImport(SQLite3)
    @Test func corruptStoredRowsReadMissingAndListSkips() async throws {
        let dir = try makeTempWorkOSDir(prefix: "rv-workos-corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("meta.sqlite").path
        let store = try WorkOSVaultMetadataStore(path: path)
        try await store.upsert(
            WorkOSVaultMetadataRow(
                id: "good", name: "good", purpose: nil,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            tenant: "t", owner: .org, subject: nil
        )
        // Inject corrupt rows behind the store's back: an empty name
        // and a negative timestamp.
        #expect(
            sabotageExec(
                path: path,
                sql: "INSERT INTO metadata VALUES ('t','org','','badname','',NULL,1000)"
            ) == SQLITE_OK
        )
        #expect(
            sabotageExec(
                path: path,
                sql: "INSERT INTO metadata VALUES ('t','org','','badtime','n',NULL,-5)"
            ) == SQLITE_OK
        )
        #expect(try await store.get(id: "badname", tenant: "t", subject: nil) == nil)
        #expect(try await store.get(id: "badtime", tenant: "t", subject: nil) == nil)
        #expect(try await store.get(id: "good", tenant: "t", subject: nil) != nil)
        #expect(try await store.list(tenant: "t", subject: nil).map(\.id) == ["good"])
    }
    #endif

    // SQLite filesystem semantics: permission-driven write
    // failures cannot occur for the in-memory fallback (Linux).
    #if canImport(SQLite3)
    @Test func readonlyFileWritesFailReadsWork() async throws {
        let dir = try makeTempWorkOSDir(prefix: "rv-workos-ro")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let path = dir.appendingPathComponent("meta.sqlite").path
        let store = try WorkOSVaultMetadataStore(path: path)
        try await store.upsert(
            WorkOSVaultMetadataRow(
                id: "k", name: "n", purpose: nil,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            tenant: "t", owner: .org, subject: nil
        )
        // A read-only directory blocks journal creation, so writes
        // fail while reads (which need no journal) keep working. (A
        // chmod on the file itself would not stop the open handle.)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        #expect(try await store.get(id: "k", tenant: "t", subject: nil)?.name == "n")
        await #expect(throws: WorkOSVaultStoreError.storeFailure) {
            try await store.upsert(
                WorkOSVaultMetadataRow(
                    id: "k2", name: "n", purpose: nil,
                    createdAt: Date(timeIntervalSince1970: 1)
                ),
                tenant: "t", owner: .org, subject: nil
            )
        }
        await #expect(throws: WorkOSVaultStoreError.storeFailure) {
            try await store.remove(id: "k", tenant: "t", subject: nil)
        }
    }
    #endif

    @Test func sqlitePrimitives() throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(":memory:", &db) == SQLITE_OK)
        let handle = try #require(db)
        defer { _ = sqlite3_close(handle) }
        #expect(WorkOSVaultMetadataStore.execute("NOT VALID SQL", on: handle) == false)
        #expect(WorkOSVaultMetadataStore.execute("SELECT 1", on: handle))
        #expect(WorkOSVaultMetadataStore.executeBound(
            "NOT VALID SQL", on: handle, bindings: []
        ) == false)
        // More bindings than placeholders fails the bind.
        #expect(WorkOSVaultMetadataStore.executeBound(
            "SELECT 1", on: handle, bindings: [.text("stray")]
        ) == false)
        // A SELECT run through the no-rows path ends on ROW, not DONE.
        #expect(WorkOSVaultMetadataStore.executeBound(
            "SELECT 1", on: handle, bindings: []
        ) == false)
        #expect(WorkOSVaultMetadataStore.executeBound(
            "CREATE TABLE t (a TEXT)", on: handle, bindings: []
        ))
        var statement: OpaquePointer?
        "SELECT ?, NULL".withCString { sql in
            #expect(sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK)
        }
        let prepared = try #require(statement)
        defer { _ = sqlite3_finalize(prepared) }
        #expect(WorkOSVaultMetadataStore.bind(.text("x"), at: 1, on: prepared))
        #expect(WorkOSVaultMetadataStore.bind(.text(nil), at: 1, on: prepared))
        #expect(WorkOSVaultMetadataStore.bind(.int(7), at: 1, on: prepared))
        // Out-of-range index fails the bind.
        #expect(WorkOSVaultMetadataStore.bind(.text("x"), at: 99, on: prepared) == false)
        #expect(sqlite3_step(prepared) == SQLITE_ROW)
        #expect(WorkOSVaultMetadataStore.columnText(prepared, 0) == "7")
        #expect(WorkOSVaultMetadataStore.columnText(prepared, 1) == nil)
    }
    #endif
}

// Oracle citations below name executor
// `packages/plugins/workos-vault/src/sdk/secret-store.test.ts` titles
// verbatim (see /tmp/x1-explore/oracles.md §workos-vault).

@Suite("WorkOSVault provider oracles", .serialized)
struct WorkOSVaultProviderOracleTests {
    @Test func storesAndResolvesValuesThroughWorkOSVault() async throws {
        let harness = try await makeWorkOSProvider()
        try await harness.provider.set("github-token", value: "ghp_secret")
        #expect(try await harness.provider.value(forItem: "github-token") == "ghp_secret")
        let listed = try await harness.provider.list()
        #expect(listed.count == 1)
        #expect(listed.first?.id == "github-token")
        #expect(listed.first?.name == "github-token")
    }

    @Test func updatesValuesInPlace() async throws {
        let harness = try await makeWorkOSProvider()
        try await harness.provider.set("api-key", value: "v1")
        try await harness.provider.set("api-key", value: "v2")
        #expect(try await harness.provider.value(forItem: "api-key") == "v2")
        #expect(try await harness.provider.list().count == 1)
        #expect(await harness.server.objectCount() == 1)
    }

    @Test func getReturnsNullForUnknownId() async throws {
        let harness = try await makeWorkOSProvider()
        #expect(try await harness.provider.value(forItem: "absent") == nil)
        // No metadata, no network.
        #expect(await harness.server.requests.count == 0)
    }

    @Test func hasReflectsPresence() async throws {
        let harness = try await makeWorkOSProvider()
        #expect(try await harness.provider.has("k") == false)
        try await harness.provider.set("k", value: "v")
        #expect(try await harness.provider.has("k"))
        // `has` never touches Vault: one create round trip total... two
        // (read-miss then create), and none for either `has`.
        #expect(await harness.server.requests.count == 2)
    }

    @Test func removesValuesFromVaultAndMetadataStore() async throws {
        let harness = try await makeWorkOSProvider()
        try await harness.provider.set("remove-me", value: "gone soon")
        #expect(try await harness.provider.value(forItem: "remove-me") == "gone soon")
        try await harness.provider.delete("remove-me")
        #expect(try await harness.provider.value(forItem: "remove-me") == nil)
        #expect(try await harness.provider.list() == [])
        #expect(await harness.server.objectCount() == 0)
        // Delete is idempotent and returns void.
        try await harness.provider.delete("remove-me")
        #expect(try await harness.provider.has("remove-me") == false)
    }

    @Test func treatsInvalidVaultObjectNamesAsMissingOnRead() async throws {
        let server = FakeVaultServer()
        await server.setRejectReadNamesLongerThan(40)
        let harness = try await makeWorkOSProvider(server: server)
        let longId =
            "openapi-oauth-example-api-oauth2-user-org-user-01kp6xm1zpvqvtpj77f0yv4eax.access_token"
        try await harness.provider.set(longId, value: "token")
        // The metadata row exists; the vault value read is missing.
        #expect(try await harness.provider.value(forItem: longId) == nil)
        try await harness.provider.delete(longId)
        #expect(try await harness.provider.list() == [])
    }

    @Test func retriesValueWritesOn409VersionConflicts() async throws {
        let server = FakeVaultServer()
        await server.setConflictOnce()
        let harness = try await makeWorkOSProvider(server: server, jitterUnit: 0)
        try await harness.provider.set("conflict", value: "initial")
        try await harness.provider.set("conflict", value: "retry-me")
        #expect(try await harness.provider.value(forItem: "conflict") == "retry-me")
        #expect(try await harness.provider.list().map(\.id) == ["conflict"])
        // One backoff: attempt 1, jitter 0 → 25 ms.
        #expect(harness.sleeps.delays == [0.025])
        let updates = await server.requests.filter { $0.httpMethod == "PUT" }
        #expect(updates.count == 2)
    }

    @Test func encodesIdsWithColonsBeforeVaultObjectNames() async throws {
        let server = FakeVaultServer()
        await server.setRejectNamesWithColon()
        let harness = try await makeWorkOSProvider(server: server)
        try await harness.provider.set("user-org:u1:org42", value: "personal")
        #expect(try await harness.provider.value(forItem: "user-org:u1:org42") == "personal")
        // No raw colon reached Vault: the name carries `%3A`, and the
        // read path re-encodes it to `%253A`.
        let requests = await server.requests
        let bodies = requests.compactMap { $0.httpBody }
        #expect(bodies.isEmpty == false)
        for body in bodies {
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            if let name = json["name"] as? String {
                #expect(name.contains(":") == false)
                #expect(name.contains("%3A"))
            }
        }
    }

    @Test func idWithoutEmbeddedOwnerFallsBackToCallerBinding() async throws {
        let harness = try await makeWorkOSProvider(
            binding: WorkOSVaultOwnerBinding(tenant: "tenant-a", subject: "subject-a")
        )
        try await harness.provider.set("token", value: "v")
        #expect(try await harness.provider.value(forItem: "token") == "v")
        // Filed under the user's own partition (caller fallback).
        #expect(try await harness.store.get(id: "token", tenant: "tenant-a", subject: "subject-a") != nil)
        #expect(try await harness.store.get(id: "token", tenant: "tenant-a", subject: nil) == nil)
    }

    @Test func workspaceConnectionCreatedByOneMemberResolvesForAnother() async throws {
        let server = FakeVaultServer()
        let store = try WorkOSVaultMetadataStore(path: ":memory:")
        let creator = try await makeWorkOSProvider(
            server: server, binding: WorkOSVaultOwnerBinding(tenant: "tenant-a", subject: "subject-a"),
            store: store
        )
        let other = try await makeWorkOSProvider(
            server: server, binding: WorkOSVaultOwnerBinding(tenant: "tenant-a", subject: "subject-b"),
            store: store
        )
        let automation = try await makeWorkOSProvider(
            server: server, binding: WorkOSVaultOwnerBinding(tenant: "tenant-a"),
            store: store
        )
        try await creator.provider.set("connection:org:exa_search_api:workspaceexa:token", value: "exa_secret")
        #expect(
            try await other.provider.value(
                forItem: "connection:org:exa_search_api:workspaceexa:token"
            ) == "exa_secret"
        )
        #expect(
            try await automation.provider.value(
                forItem: "connection:org:exa_search_api:workspaceexa:token"
            ) == "exa_secret"
        )
    }

    @Test func personalConnectionStaysPrivateToOwner() async throws {
        let server = FakeVaultServer()
        let store = try WorkOSVaultMetadataStore(path: ":memory:")
        let userA = try await makeWorkOSProvider(
            server: server, binding: WorkOSVaultOwnerBinding(tenant: "tenant-a", subject: "subject-a"),
            store: store
        )
        let userB = try await makeWorkOSProvider(
            server: server, binding: WorkOSVaultOwnerBinding(tenant: "tenant-a", subject: "subject-b"),
            store: store
        )
        try await userA.provider.set("connection:user:notion:personal:token", value: "private_secret")
        #expect(
            try await userA.provider.value(forItem: "connection:user:notion:personal:token")
                == "private_secret"
        )
        #expect(
            try await userB.provider.value(forItem: "connection:user:notion:personal:token") == nil
        )
        #expect(try await userB.provider.has("connection:user:notion:personal:token") == false)
    }

    @Test func oauthAndOAuthClientIdsPartitionedByEmbeddedOwner() async throws {
        let server = FakeVaultServer()
        let store = try WorkOSVaultMetadataStore(path: ":memory:")
        let creator = try await makeWorkOSProvider(
            server: server, binding: WorkOSVaultOwnerBinding(tenant: "tenant-a", subject: "subject-a"),
            store: store
        )
        let other = try await makeWorkOSProvider(
            server: server, binding: WorkOSVaultOwnerBinding(tenant: "tenant-a", subject: "subject-b"),
            store: store
        )
        try await creator.provider.set("oauth:org:slack:workspace", value: "access_tok")
        try await creator.provider.set("oauth-client:org:my_app:secret", value: "client_sec")
        #expect(try await other.provider.value(forItem: "oauth:org:slack:workspace") == "access_tok")
        #expect(
            try await other.provider.value(forItem: "oauth-client:org:my_app:secret") == "client_sec"
        )
    }

    @Test func sameOrgItemIdInTwoTenantsDoesNotShareVaultObject() async throws {
        let server = FakeVaultServer()
        let tenantOne = try await makeWorkOSProvider(
            server: server, binding: WorkOSVaultOwnerBinding(tenant: "org-1")
        )
        let tenantTwo = try await makeWorkOSProvider(
            server: server, binding: WorkOSVaultOwnerBinding(tenant: "org-2")
        )
        let sharedId = "connection:org:websets:workspacewebsets:token"
        try await tenantOne.provider.set(sharedId, value: "org-1-key")
        try await tenantTwo.provider.set(sharedId, value: "org-2-key")
        #expect(try await tenantOne.provider.value(forItem: sharedId) == "org-1-key")
        #expect(try await tenantTwo.provider.value(forItem: sharedId) == "org-2-key")
        #expect(await server.objectCount() == 2)
    }

    @Test func samePersonalItemIdForTwoUsersDoesNotShareVaultObject() async throws {
        let server = FakeVaultServer()
        let userA = try await makeWorkOSProvider(
            server: server, binding: WorkOSVaultOwnerBinding(tenant: "t", subject: "subject-a")
        )
        let userB = try await makeWorkOSProvider(
            server: server, binding: WorkOSVaultOwnerBinding(tenant: "t", subject: "subject-b")
        )
        let sharedId = "connection:user:dealcloud:personaldealcloud:token"
        try await userA.provider.set(sharedId, value: "a-token")
        try await userB.provider.set(sharedId, value: "b-token")
        #expect(try await userA.provider.value(forItem: sharedId) == "a-token")
        #expect(try await userB.provider.value(forItem: sharedId) == "b-token")
        #expect(await server.objectCount() == 2)
    }

    @Test func longItemIdRoundtripsThroughCappedHashedTailObjectName() async throws {
        let server = FakeVaultServer()
        await server.setRejectReadNamesLongerThan(200)
        let longId =
            "oauth:user:microsoft_graph_v1_0_sharepoint_files_excel_outlook_combined_curated:" +
            "personalmicrosoftgraphv10sharepointfilesexceloutlookcombinedcurated:refresh"
        let siblingId =
            "oauth:user:microsoft_graph_v1_0_sharepoint_files_excel_outlook_combined_curated:" +
            "personalmicrosoftgraphv10sharepointfilesexceloutlookcombinedcurated"
        let userA = try await makeWorkOSProvider(
            server: server,
            binding: WorkOSVaultOwnerBinding(
                tenant: "org_01KP6XMWC2WGC2960Y63FGP7BM",
                subject: "user_01KP6XM1ZPVQVTPJ77F0YV4EAX"
            )
        )
        let userB = try await makeWorkOSProvider(
            server: server,
            binding: WorkOSVaultOwnerBinding(
                tenant: "org_01KP6XMWC2WGC2960Y63FGP7BM",
                subject: "user_01KP6XRGC9ZF41ZZF5CXWVCPCC"
            )
        )
        try await userA.provider.set(longId, value: "a-refresh-token")
        try await userA.provider.set(siblingId, value: "a-access-token")
        try await userB.provider.set(longId, value: "b-refresh-token")
        #expect(try await userA.provider.value(forItem: longId) == "a-refresh-token")
        #expect(try await userA.provider.value(forItem: siblingId) == "a-access-token")
        #expect(try await userB.provider.value(forItem: longId) == "b-refresh-token")
        // A second write lands on the same capped name (update, not duplicate).
        try await userA.provider.set(longId, value: "a-refresh-token-2")
        #expect(try await userA.provider.value(forItem: longId) == "a-refresh-token-2")
        #expect(await server.objectCount() == 3)
    }
}

@Suite("WorkOSVault retries and errors", .serialized)
struct WorkOSVaultRetryTests {
    @Test func contentionFallsBackToBlindWrite() async throws {
        let server = FakeVaultServer()
        await server.setUpdatesAlwaysConflict()
        let harness = try await makeWorkOSProvider(server: server, jitterUnit: 0)
        // First write creates (reads miss, so no update contention).
        try await harness.provider.set("k", value: "v1")
        // Reads hit now; every versioned update 409s, including the
        // blind write's... no — the blind write is un-versioned, but
        // this fake conflicts ALL updates, so the write fails after
        // 5 versioned attempts plus the blind attempt.
        await #expect(throws: SecretsError.providerDown("workos-vault:server")) {
            try await harness.provider.set("k", value: "v2")
        }
        let updates = await server.requests.filter { $0.httpMethod == "PUT" }
        // 5 versioned + 1 blind.
        #expect(updates.count == 6)
        // 4 conflict backoffs (attempts 1-4), jitter 0.
        #expect(harness.sleeps.delays == [0.025, 0.05, 0.1, 0.2])
    }

    @Test func blindWriteSucceedsAfterRaces() async throws {
        let server = FakeVaultServer()
        // Conflict the first 5 versioned updates, then let the blind
        // write through: script counts PUTs with a version_check.
        let counter = Mutex(0)
        await server.setScript { request in
            guard request.httpMethod == "PUT" else { return nil }
            let body = request.httpBody ?? Data()
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            if json?["version_check"] != nil {
                counter.withLock { $0 += 1 }
                return (409, errorJSON("race lost"))
            }
            return nil
        }
        let harness = try await makeWorkOSProvider(server: server, jitterUnit: 1)
        try await harness.provider.set("k", value: "v1")
        try await harness.provider.set("k", value: "v2")
        #expect(try await harness.provider.value(forItem: "k") == "v2")
        #expect(counter.withLock { $0 } == 5)
        // Attempt ceilings at jitter 1: 50/100/200/400 ms.
        #expect(harness.sleeps.delays == [0.05, 0.1, 0.2, 0.4])
    }

    @Test func blindWriteTakesCreateWhenMissing() async throws {
        let server = FakeVaultServer()
        // Every versioned update 409s; after 5 the object vanishes,
        // so the blind re-read misses and the blind path creates.
        await server.setUpdatesAlwaysConflict()
        await server.setVanishAfterVersionedPuts(5)
        let harness = try await makeWorkOSProvider(server: server)
        try await harness.provider.set("k", value: "v1")
        try await harness.provider.set("k", value: "v2")
        #expect(try await harness.provider.value(forItem: "k") == "v2")
        // One create per write, 5 versioned updates, no blind update.
        #expect(await server.requests.filter { $0.httpMethod == "POST" }.count == 2)
        #expect(await server.requests.filter { $0.httpMethod == "PUT" }.count == 5)
    }

    @Test func update400IsContention() async throws {
        let server = FakeVaultServer()
        await server.setUpdatesAlwaysStale400()
        let harness = try await makeWorkOSProvider(server: server)
        try await harness.provider.set("k", value: "v1")
        // Stale-version 400s are contention: 5 versioned attempts,
        // then the blind write — which also 400s here, surfacing as
        // a server failure.
        await #expect(throws: SecretsError.providerDown("workos-vault:server")) {
            try await harness.provider.set("k", value: "v2")
        }
        let updates = await server.requests.filter { $0.httpMethod == "PUT" }
        #expect(updates.count == 6)
    }

    @Test func update400Recovers() async throws {
        let server = FakeVaultServer()
        let seen = Mutex(0)
        await server.setScript { request in
            guard request.httpMethod == "PUT" else { return nil }
            let count = seen.withLock { $0 += 1; return $0 }
            if count == 1 {
                return (400, errorJSON("Version is several generations behind"))
            }
            return nil
        }
        let harness = try await makeWorkOSProvider(server: server)
        try await harness.provider.set("k", value: "v1")
        try await harness.provider.set("k", value: "v2")
        #expect(try await harness.provider.value(forItem: "k") == "v2")
        #expect(harness.sleeps.delays.count == 1)
    }

    @Test func create409BecomesUpdate() async throws {
        let server = FakeVaultServer()
        // First create 409s (peer won), then default behavior: the
        // retry re-reads (misses — the 409 was synthetic) and
        // creates for real.
        let seen = Mutex(0)
        await server.setScript { request in
            guard request.httpMethod == "POST" else { return nil }
            let count = seen.withLock { $0 += 1; return $0 }
            if count == 1 {
                return (409, errorJSON("Object exists"))
            }
            return nil
        }
        let harness = try await makeWorkOSProvider(server: server)
        try await harness.provider.set("k", value: "v1")
        #expect(try await harness.provider.value(forItem: "k") == "v1")
        #expect(harness.sleeps.delays.count == 1)
        #expect(await server.objectCount() == 1)
    }

    @Test func kekRetryThenSucceeds() async throws {
        let server = FakeVaultServer()
        await server.setKEK(reads: 0, writes: 3)
        let harness = try await makeWorkOSProvider(server: server)
        try await harness.provider.set("k", value: "v")
        #expect(try await harness.provider.value(forItem: "k") == "v")
        // Three KEK failures, three fixed 1s backoffs.
        #expect(harness.sleeps.delays == [1, 1, 1])
    }

    @Test func kekExhaustsTwentyAttempts() async throws {
        let server = FakeVaultServer()
        await server.setKEK(reads: 0, writes: 10_000)
        let harness = try await makeWorkOSProvider(server: server)
        await #expect(throws: SecretsError.providerDown("workos-vault:kekNotReady")) {
            try await harness.provider.set("k", value: "v")
        }
        // 20 whole attempts, 19 KEK backoffs, no metadata written.
        #expect(harness.sleeps.delays == Array(repeating: 1.0, count: 19))
        #expect(await server.requests.count == 40)
        #expect(try await harness.provider.has("k") == false)
    }

    @Test func kekOnReadRetries() async throws {
        let server = FakeVaultServer()
        await server.setKEK(reads: 2, writes: 0)
        let harness = try await makeWorkOSProvider(server: server)
        try await harness.provider.set("k", value: "v")
        #expect(try await harness.provider.value(forItem: "k") == "v")
        #expect(harness.sleeps.delays == [1, 1])
    }

    @Test func kek400OnReadFallsThroughToCreate() async throws {
        // Executor quirk parity: a 400 on read masks to missing
        // WITHOUT consulting the KEK kind, so the write proceeds to
        // create with no retry at all.
        let server = FakeVaultServer()
        await server.setScript { request in
            guard request.httpMethod == "GET" else { return nil }
            return (400, errorJSON("prefix \(WorkOSVaultClientError.kekNotReadySuffix)"))
        }
        let harness = try await makeWorkOSProvider(server: server)
        try await harness.provider.set("k", value: "v")
        #expect(try await harness.provider.value(forItem: "k") == nil)
        let posts = await server.requests.filter { $0.httpMethod == "POST" }
        #expect(posts.count == 1)
        #expect(harness.sleeps.delays == [])
    }

    @Test func kekDoesNotConsumeContentionAttempt() async throws {
        let server = FakeVaultServer()
        await server.setKEK(reads: 0, writes: 1)
        // One write attempt allowed: a KEK failure must not trip the
        // blind path — the retry still takes the versioned path.
        let policy = WorkOSVaultRetryPolicy(maxWriteAttempts: 1)
        let harness = try await makeWorkOSProvider(server: server, retryPolicy: policy)
        try await harness.provider.set("k", value: "v")
        #expect(try await harness.provider.value(forItem: "k") == "v")
        #expect(harness.sleeps.delays == [1])
        #expect(await server.requests.filter { $0.httpMethod == "POST" }.count == 2)
    }

    @Test func readPathKEKSurfacesWithoutRetry() async throws {
        let server = FakeVaultServer()
        let harness = try await makeWorkOSProvider(server: server)
        try await harness.provider.set("k", value: "v")
        await server.setKEK(reads: 10, writes: 0)
        await #expect(throws: SecretsError.providerDown("workos-vault:kekNotReady")) {
            try await harness.provider.value(forItem: "k")
        }
        #expect(harness.sleeps.delays == [])
    }

    @Test func customKEKCapHonored() async throws {
        let server = FakeVaultServer()
        await server.setKEK(reads: 0, writes: 10_000)
        let policy = WorkOSVaultRetryPolicy(maxKEKAttempts: 3)
        let harness = try await makeWorkOSProvider(server: server, retryPolicy: policy)
        await #expect(throws: SecretsError.providerDown("workos-vault:kekNotReady")) {
            try await harness.provider.set("k", value: "v")
        }
        #expect(harness.sleeps.delays == [1, 1])
    }

    @Test func sleeperFailureAbortsAsRetry() async throws {
        let server = FakeVaultServer()
        await server.setConflictOnce()
        struct NapDefect: Error {}
        let client = try makeWorkOSClient(server: server)
        let store = try WorkOSVaultMetadataStore(path: ":memory:")
        let provider = try WorkOSVaultSecretsProvider(
            client: client, store: store,
            binding: WorkOSVaultOwnerBinding(tenant: "t"),
            jitter: { 0 },
            sleeper: { _ in throw NapDefect() }
        )
        try await provider.set("conflict", value: "v1")
        await #expect(throws: SecretsError.providerDown("workos-vault:retry")) {
            try await provider.set("conflict", value: "v2")
        }
    }

    @Test func sleeperCancellationPropagates() async throws {
        let server = FakeVaultServer()
        await server.setConflictOnce()
        let client = try makeWorkOSClient(server: server)
        let store = try WorkOSVaultMetadataStore(path: ":memory:")
        let provider = try WorkOSVaultSecretsProvider(
            client: client, store: store,
            binding: WorkOSVaultOwnerBinding(tenant: "t"),
            jitter: { 0 },
            sleeper: { _ in throw CancellationError() }
        )
        try await provider.set("conflict", value: "v1")
        await #expect(throws: CancellationError.self) {
            try await provider.set("conflict", value: "v2")
        }
    }
}

@Suite("WorkOSVault error mapping", .serialized)
struct WorkOSVaultErrorMappingTests {
    @Test func clientErrorMappingMatrix() {
        let map = WorkOSVaultSecretsProvider.mapClientError
        let make = { (kind: WorkOSVaultClientError.Kind) in
            WorkOSVaultClientError(operation: "read_object_by_name", kind: kind, retryKind: nil)
        }
        #expect(map(make(.httpStatus(401))) == .providerDown("workos-vault:forbidden"))
        #expect(map(make(.httpStatus(403))) == .providerDown("workos-vault:forbidden"))
        #expect(map(make(.httpStatus(429))) == .providerDown("workos-vault:rateLimited"))
        #expect(map(make(.httpStatus(404))) == .providerDown("workos-vault:server"))
        #expect(map(make(.httpStatus(409))) == .providerDown("workos-vault:server"))
        #expect(map(make(.httpStatus(500))) == .providerDown("workos-vault:server"))
        #expect(map(make(.timeout)) == .timeout("workos-vault"))
        #expect(map(make(.tls)) == .providerDown("workos-vault:tls"))
        #expect(map(make(.unreachable)) == .providerDown("workos-vault:unreachable"))
        #expect(map(make(.oversized)) == .oversized("workos-vault"))
        #expect(map(make(.decode)) == .providerDown("workos-vault:decode"))
        // The KEK kind wins over every status.
        #expect(
            map(WorkOSVaultClientError(
                operation: "create_object", kind: .httpStatus(500), retryKind: .kekNotReady
            )) == .providerDown("workos-vault:kekNotReady")
        )
    }

    @Test func readErrorMappingIntegration() async throws {
        let vectors: [(Int, SecretsError)] = [
            (401, .providerDown("workos-vault:forbidden")),
            (403, .providerDown("workos-vault:forbidden")),
            (429, .providerDown("workos-vault:rateLimited")),
            (500, .providerDown("workos-vault:server")),
            (503, .providerDown("workos-vault:server")),
        ]
        for (status, expected) in vectors {
            let server = FakeVaultServer()
            let harness = try await makeWorkOSProvider(server: server)
            try await harness.provider.set("k", value: "v")
            await server.setScript { _ in (status, errorJSON("canary-status-\(status)")) }
            await #expect(throws: expected) {
                try await harness.provider.value(forItem: "k")
            }
        }
    }

    @Test func transportErrorMappingIntegration() async throws {
        let vectors: [(Error, SecretsError)] = [
            (URLError(.timedOut), .timeout("workos-vault")),
            (URLError(.serverCertificateUntrusted), .providerDown("workos-vault:tls")),
            (URLError(.cannotConnectToHost), .providerDown("workos-vault:unreachable")),
        ]
        for (failure, expected) in vectors {
            let transport: WorkOSVaultTransport = { _ in throw failure }
            let client = try WorkOSVaultHTTPClient(
                endpoint: URL(string: "https://api.workos.com")!, apiKey: "k",
                timeoutSeconds: 10, transport: transport
            )
            let store = try WorkOSVaultMetadataStore(path: ":memory:")
            try await store.upsert(
                WorkOSVaultMetadataRow(
                    id: "k", name: "k", purpose: nil,
                    createdAt: Date(timeIntervalSince1970: 1)
                ),
                tenant: "t", owner: .org, subject: nil
            )
            let provider = try WorkOSVaultSecretsProvider(
                client: client, store: store,
                binding: WorkOSVaultOwnerBinding(tenant: "t"),
                jitter: { 0 }, sleeper: { _ in }
            )
            await #expect(throws: expected) {
                try await provider.value(forItem: "k")
            }
        }
    }

    @Test func errorOpacitySweep() async throws {
        // Planted canaries must never appear in mapped errors.
        let canaryID = "canary-id-hunter2"
        let canaryValue = "canary-value-s3cr3t"
        let canaryTenant = "canary-tenant-xyz"
        let server = FakeVaultServer()
        let harness = try await makeWorkOSProvider(
            server: server,
            binding: WorkOSVaultOwnerBinding(tenant: canaryTenant, subject: "canary-subject")
        )
        try await harness.provider.set(canaryID, value: canaryValue)
        await server.setScript { _ in
            (500, errorJSON("leak \(canaryID) \(canaryValue) \(canaryTenant)"))
        }
        var descriptions: [String] = []
        do {
            _ = try await harness.provider.value(forItem: canaryID)
        } catch {
            descriptions.append(String(describing: error))
        }
        do {
            try await harness.provider.set(canaryID, value: "x")
        } catch {
            descriptions.append(String(describing: error))
        }
        do {
            try await harness.provider.delete(canaryID)
        } catch {
            descriptions.append(String(describing: error))
        }
        #expect(descriptions.count == 3)
        for description in descriptions {
            #expect(description.contains(canaryID) == false)
            #expect(description.contains(canaryValue) == false)
            #expect(description.contains(canaryTenant) == false)
            #expect(description.contains("canary-subject") == false)
            #expect(description.contains("leak") == false)
        }
        // Client errors are structurally opaque: no text field exists.
        let clientError = WorkOSVaultClientError(
            operation: "read_object_by_name", kind: .httpStatus(500), retryKind: nil
        )
        #expect(String(describing: clientError).contains(canaryID) == false)
    }

    @Test func apiKeyNeverSurfacesInErrors() async throws {
        // Even a hostile server that reflects the Authorization
        // header into its error bodies cannot smuggle the key into
        // mapped errors: bodies are detection-only, never retained.
        let key = "sk-canary-hunter2-key"
        let server = FakeVaultServer()
        await server.setScript { request in
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? "<absent>"
            return (500, errorJSON("reflected \(auth)"))
        }
        let client = try makeWorkOSClient(server: server, apiKey: key)
        let store = try WorkOSVaultMetadataStore(path: ":memory:")
        try await store.upsert(
            WorkOSVaultMetadataRow(
                id: "k", name: "k", purpose: nil,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            tenant: "t", owner: .org, subject: nil
        )
        let provider = try WorkOSVaultSecretsProvider(
            client: client, store: store,
            binding: WorkOSVaultOwnerBinding(tenant: "t"),
            jitter: { 0 }, sleeper: { _ in }
        )
        var descriptions: [String] = []
        do {
            _ = try await provider.value(forItem: "k")
        } catch {
            descriptions.append(String(describing: error))
        }
        do {
            try await provider.set("k", value: "x")
        } catch {
            descriptions.append(String(describing: error))
        }
        do {
            try await provider.delete("k")
        } catch {
            descriptions.append(String(describing: error))
        }
        #expect(descriptions.count == 3)
        // The requests really carried the key, so the echo is real.
        let sent = await server.requests.compactMap {
            $0.value(forHTTPHeaderField: "Authorization")
        }
        #expect(sent.isEmpty == false)
        #expect(sent.allSatisfy { $0 == "Bearer \(key)" })
        for description in descriptions {
            #expect(description.contains(key) == false)
            #expect(description.contains("reflected") == false)
            #expect(description.contains("Bearer") == false)
        }
    }

    @Test func storeFailuresMapToStoreLabel() async throws {
        let server = FakeVaultServer()
        let client = try makeWorkOSClient(server: server)
        for failure: Error in [WorkOSVaultStoreError.storeFailure, FakeStoreDefect()] {
            let provider = try WorkOSVaultSecretsProvider(
                client: client, store: ThrowingMetadataStore(error: failure),
                binding: WorkOSVaultOwnerBinding(tenant: "t"),
                jitter: { 0 }, sleeper: { _ in }
            )
            await #expect(throws: SecretsError.providerDown("workos-vault:store")) {
                try await provider.value(forItem: "k")
            }
            await #expect(throws: SecretsError.providerDown("workos-vault:store")) {
                try await provider.has("k")
            }
            await #expect(throws: SecretsError.providerDown("workos-vault:store")) {
                try await provider.list()
            }
            await #expect(throws: SecretsError.providerDown("workos-vault:store")) {
                try await provider.set("k", value: "v")
            }
            await #expect(throws: SecretsError.providerDown("workos-vault:store")) {
                try await provider.delete("k")
            }
        }
    }

    @Test func storeCancellationPropagates() async throws {
        let server = FakeVaultServer()
        let client = try makeWorkOSClient(server: server)
        let provider = try WorkOSVaultSecretsProvider(
            client: client, store: ThrowingMetadataStore(error: CancellationError()),
            binding: WorkOSVaultOwnerBinding(tenant: "t"),
            jitter: { 0 }, sleeper: { _ in }
        )
        await #expect(throws: CancellationError.self) {
            try await provider.value(forItem: "k")
        }
        await #expect(throws: CancellationError.self) {
            try await provider.list()
        }
    }

    @Test func deleteRemoveFailureMapsToStoreLabel() async throws {
        let server = FakeVaultServer()
        let client = try makeWorkOSClient(server: server)
        let provider = try WorkOSVaultSecretsProvider(
            client: client, store: RemoveFailingMetadataStore(),
            binding: WorkOSVaultOwnerBinding(tenant: "t"),
            jitter: { 0 }, sleeper: { _ in }
        )
        await #expect(throws: SecretsError.providerDown("workos-vault:store")) {
            try await provider.delete("k")
        }
    }

    @Test func nonContentionWriteFailuresSurfaceWithoutRetry() async throws {
        let server = FakeVaultServer()
        let harness = try await makeWorkOSProvider(server: server)
        try await harness.provider.set("k", value: "v1")
        // A non-contention update failure (500) maps and throws with
        // no retry and no backoff.
        await server.setScript { request in
            guard request.httpMethod == "PUT" else { return nil }
            return (500, errorJSON("boom"))
        }
        await #expect(throws: SecretsError.providerDown("workos-vault:server")) {
            try await harness.provider.set("k", value: "v2")
        }
        #expect(harness.sleeps.delays == [])
        #expect(await server.requests.filter { $0.httpMethod == "PUT" }.count == 1)
        // Same for a non-409 create failure: reads miss, creates 500.
        await server.setScript { request in
            if request.httpMethod == "GET" {
                return (404, errorJSON("Object gone"))
            }
            if request.httpMethod == "POST" {
                return (500, errorJSON("boom"))
            }
            return nil
        }
        await #expect(throws: SecretsError.providerDown("workos-vault:server")) {
            try await harness.provider.set("fresh", value: "v")
        }
        #expect(harness.sleeps.delays == [])
    }

    @Test func setStoreFailureOrphansVaultValue() async throws {
        // Vault write lands, metadata upsert fails: the value is
        // orphaned (executor parity — later reads see no metadata).
        let server = FakeVaultServer()
        let client = try makeWorkOSClient(server: server)
        let failer = FailAfterReadsMetadataStore()
        let provider = try WorkOSVaultSecretsProvider(
            client: client, store: failer,
            binding: WorkOSVaultOwnerBinding(tenant: "t"),
            jitter: { 0 }, sleeper: { _ in }
        )
        await #expect(throws: SecretsError.providerDown("workos-vault:store")) {
            try await provider.set("k", value: "v")
        }
        #expect(await server.objectCount() == 1)
    }
}

/// Metadata double whose rows exist but whose removal fails.
private actor RemoveFailingMetadataStore: WorkOSVaultMetadata {
    func get(id: String, tenant: String, subject: String?) async throws -> WorkOSVaultMetadataRow? {
        WorkOSVaultMetadataRow(
            id: id, name: id, purpose: nil,
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }

    func upsert(
        _ row: WorkOSVaultMetadataRow, tenant: String, owner: WorkOSVaultOwner, subject: String?
    ) async throws {}

    func remove(
        id: String, tenant: String, subject: String?
    ) async throws -> Bool {
        throw WorkOSVaultStoreError.storeFailure
    }

    func list(tenant: String, subject: String?) async throws -> [WorkOSVaultMetadataRow] {
        []
    }
}

/// Metadata double whose reads miss and whose writes fail.
private actor FailAfterReadsMetadataStore: WorkOSVaultMetadata {
    func get(id: String, tenant: String, subject: String?) async throws -> WorkOSVaultMetadataRow? {
        nil
    }

    func upsert(
        _ row: WorkOSVaultMetadataRow, tenant: String, owner: WorkOSVaultOwner, subject: String?
    ) async throws {
        throw WorkOSVaultStoreError.storeFailure
    }

    func remove(
        id: String, tenant: String, subject: String?
    ) async throws -> Bool {
        throw WorkOSVaultStoreError.storeFailure
    }

    func list(tenant: String, subject: String?) async throws -> [WorkOSVaultMetadataRow] {
        []
    }
}

@Suite("WorkOSVault resolve and health", .serialized)
struct WorkOSVaultResolveTests {
    @Test func automationDeniesUserScopedIds() async throws {
        // Automation (subject-less) binding: user-partition ids fail
        // closed on every mutating and read path, and the denied `set`
        // leaves neither a Vault object nor a metadata row behind.
        let harness = try await makeWorkOSProvider()
        let id = "connection:user:notion:personal:token"
        await #expect(throws: SecretsError.denied("workos-vault")) {
            try await harness.provider.set(id, value: "orphan")
        }
        await #expect(throws: SecretsError.denied("workos-vault")) {
            _ = try await harness.provider.value(forItem: id)
        }
        await #expect(throws: SecretsError.denied("workos-vault")) {
            _ = try await harness.provider.has(id)
        }
        await #expect(throws: SecretsError.denied("workos-vault")) {
            try await harness.provider.delete(id)
        }
        #expect(await harness.server.objectCount() == 0)
        #expect(try await harness.provider.list().isEmpty)
    }

    @Test func automationStillServesOrgAndLegacyIds() async throws {
        let harness = try await makeWorkOSProvider()
        try await harness.provider.set("connection:org:exa:main:token", value: "o")
        try await harness.provider.set("legacy-id", value: "l")
        #expect(
            try await harness.provider.value(forItem: "connection:org:exa:main:token") == "o"
        )
        #expect(try await harness.provider.value(forItem: "legacy-id") == "l")
    }

    @Test func emptySubjectRejectedAtInit() async throws {
        let server = FakeVaultServer()
        let client = try makeWorkOSClient(server: server)
        let store = try WorkOSVaultMetadataStore(path: ":memory:")
        #expect(throws: WorkOSVaultConfigurationError.emptySubject) {
            _ = try WorkOSVaultSecretsProvider(
                client: client, store: store,
                binding: WorkOSVaultOwnerBinding(tenant: "t", subject: "")
            )
        }
    }

    @Test func resolveRejectsForeignProvider() async throws {
        let harness = try await makeWorkOSProvider()
        let ref = try SecretRef(provider: "env", item: "whatever")
        await #expect(throws: SecretsError.invalidRef("workos-vault")) {
            try await harness.provider.resolve(ref)
        }
    }

    // The tests below construct `SecretRef(provider: "workos-vault")`,
    // admitted by `SecretRef.allowedProviders`.

    @Test func resolveRoundTrip() async throws {
        let harness = try await makeWorkOSProvider()
        try await harness.provider.set("github-token", value: "ghp_secret")
        let ref = try SecretRef(provider: "workos-vault", item: "github-token")
        #expect(try await harness.provider.resolve(ref) == .text("ghp_secret"))
    }

    @Test func resolveMissingIsNotFound() async throws {
        let harness = try await makeWorkOSProvider()
        let ref = try SecretRef(provider: "workos-vault", item: "absent")
        await #expect(throws: SecretsError.notFound("workos-vault")) {
            try await harness.provider.resolve(ref)
        }
    }

    @Test func resolveFieldIsNotFound() async throws {
        let harness = try await makeWorkOSProvider()
        try await harness.provider.set("k", value: "v")
        let ref = try SecretRef(provider: "workos-vault", item: "k", field: "field")
        await #expect(throws: SecretsError.notFound("workos-vault")) {
            try await harness.provider.resolve(ref)
        }
    }

    @Test func healthMatrix() async throws {
        let healthy = try await makeWorkOSProvider()
        #expect(await healthy.provider.health() == ProviderHealth(ok: true))
        // Every failure reports unhealthy, never throws.
        for status in [400, 401, 403, 404, 429, 500] {
            let server = FakeVaultServer()
            await server.setScript { request in
                guard request.url?.path == "/vault/v1/kv" else { return nil }
                return (status, errorJSON("boom"))
            }
            let harness = try await makeWorkOSProvider(server: server)
            #expect(await harness.provider.health() == ProviderHealth(ok: false))
        }
        let transport: WorkOSVaultTransport = { _ in throw URLError(.cannotConnectToHost) }
        let client = try WorkOSVaultHTTPClient(
            endpoint: URL(string: "https://api.workos.com")!, apiKey: "k",
            timeoutSeconds: 10, transport: transport
        )
        let unreachable = try WorkOSVaultSecretsProvider(
            client: client, store: ThrowingMetadataStore(error: FakeStoreDefect()),
            binding: WorkOSVaultOwnerBinding(tenant: "t"),
            jitter: { 0 }, sleeper: { _ in }
        )
        #expect(await unreachable.health() == ProviderHealth(ok: false))
        let cancelling: WorkOSVaultTransport = { _ in throw CancellationError() }
        let cancelClient = try WorkOSVaultHTTPClient(
            endpoint: URL(string: "https://api.workos.com")!, apiKey: "k",
            timeoutSeconds: 10, transport: cancelling
        )
        let cancelled = try WorkOSVaultSecretsProvider(
            client: cancelClient, store: ThrowingMetadataStore(error: FakeStoreDefect()),
            binding: WorkOSVaultOwnerBinding(tenant: "t"),
            jitter: { 0 }, sleeper: { _ in }
        )
        #expect(await cancelled.health() == ProviderHealth(ok: false))
    }

    @Test func healthSendsLimitOne() async throws {
        let harness = try await makeWorkOSProvider()
        _ = await harness.provider.health()
        let requests = await harness.server.requests
        #expect(requests.count == 1)
        #expect(requests.first?.url?.absoluteString.contains("limit=1") == true)
    }
}

@Suite("WorkOSVault edges and stress", .serialized)
struct WorkOSVaultEdgeTests {
    @Test func setPreservesMetadata() async throws {
        let clock = WorkOSClockBox(Date(timeIntervalSince1970: 1_000))
        let harness = try await makeWorkOSProvider(clock: clock)
        try await harness.provider.set("k", value: "v1")
        try await harness.store.upsert(
            WorkOSVaultMetadataRow(
                id: "k", name: "custom-name", purpose: "custom-purpose",
                createdAt: Date(timeIntervalSince1970: 500)
            ),
            tenant: "tenant-a", owner: .org, subject: nil
        )
        clock.advance(by: 10_000)
        try await harness.provider.set("k", value: "v2")
        let row = try #require(
            try await harness.store.get(id: "k", tenant: "tenant-a", subject: nil)
        )
        #expect(row.name == "custom-name")
        #expect(row.purpose == "custom-purpose")
        #expect(row.createdAt == Date(timeIntervalSince1970: 500))
    }

    @Test func setDefaultsMetadataFromClock() async throws {
        let clock = WorkOSClockBox(Date(timeIntervalSince1970: 1_700_000_000))
        let harness = try await makeWorkOSProvider(clock: clock)
        try await harness.provider.set("k", value: "v")
        let row = try #require(
            try await harness.store.get(id: "k", tenant: "tenant-a", subject: nil)
        )
        #expect(row.name == "k")
        #expect(row.purpose == nil)
        #expect(row.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func metadataGatesReads() async throws {
        // A vault object with no metadata row is invisible.
        let server = FakeVaultServer()
        let client = try makeWorkOSClient(server: server)
        _ = try await client.createObject(name: "executor/secrets/orphan", value: "v", context: [:])
        let harness = try await makeWorkOSProvider(server: server)
        #expect(try await harness.provider.value(forItem: "orphan") == nil)
    }

    @Test func emptyAndMissingValuesReadMissing() async throws {
        let server = FakeVaultServer()
        await server.setScript { request in
            guard request.httpMethod == "GET" else { return nil }
            let path = request.url?.path ?? ""
            if path.contains("empty") {
                return (200, Data(
                    "{\"id\":\"secret_1\",\"metadata\":{\"version_id\":\"v1\"},\"value\":\"\"}".utf8
                ))
            }
            return (200, Data("{\"id\":\"secret_1\",\"metadata\":{\"version_id\":\"v1\"}}".utf8))
        }
        let harness = try await makeWorkOSProvider(server: server)
        try await harness.store.upsert(
            WorkOSVaultMetadataRow(
                id: "empty", name: "empty", purpose: nil,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            tenant: "tenant-a", owner: .org, subject: nil
        )
        try await harness.store.upsert(
            WorkOSVaultMetadataRow(
                id: "noval", name: "noval", purpose: nil,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            tenant: "tenant-a", owner: .org, subject: nil
        )
        #expect(try await harness.provider.value(forItem: "empty") == nil)
        #expect(try await harness.provider.value(forItem: "noval") == nil)
    }

    @Test func deleteSkipsNetworkWhenNoMetadata() async throws {
        let harness = try await makeWorkOSProvider()
        try await harness.provider.delete("absent")
        #expect(await harness.server.requests.count == 0)
    }

    @Test func deleteMissingVaultObjectStillClears() async throws {
        let harness = try await makeWorkOSProvider()
        try await harness.provider.set("k", value: "v")
        // Vault object vanishes out of band; delete still clears metadata.
        let server = harness.server
        await server.setScript { request in
            guard request.httpMethod == "GET" else { return nil }
            return (404, errorJSON("Object gone"))
        }
        try await harness.provider.delete("k")
        #expect(try await harness.provider.has("k") == false)
        #expect(try await harness.provider.list() == [])
    }

    @Test func deleteRaced404ThrowsAndKeepsMetadata() async throws {
        let harness = try await makeWorkOSProvider()
        try await harness.provider.set("k", value: "v")
        let server = harness.server
        await server.setScript { request in
            guard request.httpMethod == "DELETE" else { return nil }
            return (404, errorJSON("Object gone"))
        }
        // Executor parity: the raced delete fails, metadata stays.
        await #expect(throws: SecretsError.providerDown("workos-vault:server")) {
            try await harness.provider.delete("k")
        }
        #expect(try await harness.provider.has("k"))
    }

    @Test func deleteUsesObjectId() async throws {
        let harness = try await makeWorkOSProvider()
        try await harness.provider.set("connection:org:acme:main:token", value: "v")
        try await harness.provider.delete("connection:org:acme:main:token")
        let deletes = await harness.server.requests.filter { $0.httpMethod == "DELETE" }
        #expect(deletes.count == 1)
        #expect(try #require(deletes.first?.url?.path) == "/vault/v1/kv/secret_1")
    }

    @Test func crossContextDeleteLeavesNoGhostRow() async throws {
        // Automation files a legacy id (org partition); a bound
        // subject deletes it through the shared store. Both the
        // vault object and the org metadata row go: no ghost row
        // keeps `has` true or the id listed afterwards.
        let server = FakeVaultServer()
        let store = try WorkOSVaultMetadataStore(path: ":memory:")
        let automation = try await makeWorkOSProvider(
            server: server,
            binding: WorkOSVaultOwnerBinding(tenant: "tenant-a"),
            store: store
        )
        let member = try await makeWorkOSProvider(
            server: server,
            binding: WorkOSVaultOwnerBinding(tenant: "tenant-a", subject: "subject-a"),
            store: store
        )
        try await automation.provider.set("legacy-token", value: "v")
        #expect(try await member.provider.value(forItem: "legacy-token") == "v")
        try await member.provider.delete("legacy-token")
        #expect(try await automation.provider.has("legacy-token") == false)
        #expect(try await member.provider.has("legacy-token") == false)
        #expect(try await automation.provider.value(forItem: "legacy-token") == nil)
        #expect(try await automation.provider.list() == [])
        #expect(try await member.provider.list() == [])
        #expect(await server.objectCount() == 0)
    }

    @Test func nulByteIdsRoundTripThroughProvider() async throws {
        // NUL bytes survive the metadata store and the vault-name
        // encoding: neighboring ids stay distinct end to end.
        let harness = try await makeWorkOSProvider()
        try await harness.provider.set("a\0b", value: "v-nul")
        try await harness.provider.set("a", value: "v-plain")
        #expect(try await harness.provider.value(forItem: "a\0b") == "v-nul")
        #expect(try await harness.provider.value(forItem: "a") == "v-plain")
        #expect(try await harness.provider.list().count == 2)
    }

    @Test func keyContextSentOnCreate() async throws {
        let server = FakeVaultServer()
        let store = try WorkOSVaultMetadataStore(path: ":memory:")
        let user = try await makeWorkOSProvider(
            server: server,
            binding: WorkOSVaultOwnerBinding(tenant: "tenant-a", subject: "subject-a"),
            store: store
        )
        try await user.provider.set("connection:org:i:n:v", value: "a")
        try await user.provider.set("connection:user:i:n:v", value: "b")
        try await user.provider.set("legacy", value: "c")
        let posts = await server.requests.filter { $0.httpMethod == "POST" }
        #expect(posts.count == 3)
        let contexts = try posts.map { request -> [String: String] in
            let body = try #require(request.httpBody)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            return try #require(json["key_context"] as? [String: String])
        }
        #expect(contexts[0] == ["app": "executor", "organization_id": "tenant-a"])
        #expect(contexts[1] == [
            "app": "executor", "organization_id": "tenant-a", "user_id": "subject-a",
        ])
        #expect(contexts[2] == ["app": "executor"])
    }

    @Test func updateUsesReadVersionNotUpdateEcho() async throws {
        // The version_check for write N+1 comes from the read before
        // it, never from an earlier update's echo.
        let server = FakeVaultServer()
        let harness = try await makeWorkOSProvider(server: server)
        try await harness.provider.set("k", value: "v1")
        try await harness.provider.set("k", value: "v2")
        try await harness.provider.set("k", value: "v3")
        let puts = await server.requests.filter { $0.httpMethod == "PUT" }
        #expect(puts.count == 2)
        let checks = try puts.map { request -> String in
            let body = try #require(request.httpBody)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            return try #require(json["version_check"] as? String)
        }
        #expect(checks == ["v1", "v2"])
    }

    @Test func largeAndUnicodeValues() async throws {
        let harness = try await makeWorkOSProvider()
        let large = String(repeating: "x🎉", count: 64 * 1024)
        try await harness.provider.set("big", value: large)
        #expect(try await harness.provider.value(forItem: "big") == large)
        let quotes = "say \"hi\" \\ bye \n deed\u{0}null?"
        try await harness.provider.set("q", value: quotes)
        #expect(try await harness.provider.value(forItem: "q") == quotes)
    }

    @Test func hostileIdsRoundTrip() async throws {
        let harness = try await makeWorkOSProvider()
        let ids = ["a/b?c=d&e#f", "x y", "\"quoted\"", "日本語", "a:b:c", "%25", ".", ".."]
        for id in ids {
            try await harness.provider.set(id, value: "v-\(id)")
        }
        for id in ids {
            #expect(try await harness.provider.value(forItem: id) == "v-\(id)")
        }
        #expect(try await harness.provider.list().count == ids.count)
        // No raw slash or space reached Vault object names.
        let posts = await harness.server.requests.filter { $0.httpMethod == "POST" }
        for post in posts {
            let body = try #require(post.httpBody)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            let name = try #require(json["name"] as? String)
            let tail = try #require(name.split(separator: "/").last.map(String.init))
            #expect(tail.contains(" ") == false)
        }
    }

    @Test func manySecretsStress() async throws {
        let harness = try await makeWorkOSProvider()
        for index in 0..<100 {
            try await harness.provider.set("stress-\(index)", value: "v\(index)")
        }
        #expect(try await harness.provider.list().count == 100)
        for index in [0, 49, 99] {
            #expect(
                try await harness.provider.value(forItem: "stress-\(index)") == "v\(index)"
            )
        }
    }

    @Test func concurrentSetsSameId() async throws {
        let harness = try await makeWorkOSProvider()
        let completed = try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<10 {
                group.addTask {
                    try await harness.provider.set("raced", value: "v\(index)")
                }
            }
            var count = 0
            for try await _ in group {
                count += 1
            }
            return count
        }
        // Every write retried through the races and succeeded; one value won.
        #expect(completed == 10)
        let value = try await harness.provider.value(forItem: "raced")
        #expect(value?.hasPrefix("v") == true)
        #expect(try await harness.provider.list().count == 1)
    }

    @Test func transportCancellationPropagatesFromProvider() async throws {
        let transport: WorkOSVaultTransport = { _ in throw CancellationError() }
        let client = try WorkOSVaultHTTPClient(
            endpoint: URL(string: "https://api.workos.com")!, apiKey: "k",
            timeoutSeconds: 10, transport: transport
        )
        let store = try WorkOSVaultMetadataStore(path: ":memory:")
        try await store.upsert(
            WorkOSVaultMetadataRow(
                id: "k", name: "k", purpose: nil,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            tenant: "t", owner: .org, subject: nil
        )
        let provider = try WorkOSVaultSecretsProvider(
            client: client, store: store,
            binding: WorkOSVaultOwnerBinding(tenant: "t"),
            jitter: { 0 }, sleeper: { _ in }
        )
        await #expect(throws: CancellationError.self) {
            try await provider.value(forItem: "k")
        }
        await #expect(throws: CancellationError.self) {
            try await provider.set("k", value: "v")
        }
        await #expect(throws: CancellationError.self) {
            try await provider.delete("k")
        }
    }
}

private func writeWorkOSFile(at directory: URL, name: String, json: String, mode: Int = 0o600) throws {
    let url = directory.appendingPathComponent(name)
    try json.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

@Suite("WorkOSVault operator config", .serialized)
struct WorkOSVaultOperatorConfigTests {
    @Test func apiKeyDecode() {
        #expect(
            WorkOSVaultAPIKeyStore.decode(Data("{\"version\":1,\"api_key\":\"sk-x\"}".utf8))
                == .success("sk-x")
        )
        #expect(
            WorkOSVaultAPIKeyStore.decode(Data("{\"version\":1,\"api_key\":\"  sk-x\\n\"}".utf8))
                == .success("sk-x")
        )
        #expect(
            WorkOSVaultAPIKeyStore.decode(Data(repeating: 0x61, count: 5_000))
                == .failure(.oversized)
        )
        for doc in [
            "{not json",
            "{\"version\":1}",
            "{\"api_key\":\"sk-x\"}",
            "{\"version\":1,\"api_key\":\"\"}",
            "{\"version\":1,\"api_key\":\"   \"}",
            "{\"version\":1,\"api_key\":\"sk-x\",\"smuggled\":1}",
            "{\"version\":1,\"api_key\":42}",
            "{\"version\":\"1\",\"api_key\":\"sk-x\"}",
            "{\"version\":1,\"api_key\":\"\(String(repeating: "k", count: 3_000))\"}",
        ] {
            #expect(
                WorkOSVaultAPIKeyStore.decode(Data(doc.utf8)) == .failure(.invalidDocument),
                "rejects \(doc.prefix(40))"
            )
        }
        #expect(
            WorkOSVaultAPIKeyStore.decode(Data("{\"version\":2,\"api_key\":\"sk-x\"}".utf8))
                == .failure(.unsupportedVersion)
        )
    }

    @Test func apiKeyLoad() throws {
        let dir = try makeTempWorkOSDir(prefix: "rv-workos-apikey")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(WorkOSVaultAPIKeyStore.load(from: dir) == .failure(.unreadable))
        try writeWorkOSFile(
            at: dir, name: WorkOSVaultAPIKeyStore.fileName,
            json: "{\"version\":1,\"api_key\":\"sk-round\"}"
        )
        #expect(WorkOSVaultAPIKeyStore.load(from: dir) == .success("sk-round"))
        // Unsafe file mode.
        try writeWorkOSFile(
            at: dir, name: WorkOSVaultAPIKeyStore.fileName,
            json: "{\"version\":1,\"api_key\":\"sk-round\"}", mode: 0o640
        )
        #expect(WorkOSVaultAPIKeyStore.load(from: dir) == .failure(.unsafeLocation))
        // Unsafe directory mode.
        try writeWorkOSFile(
            at: dir, name: WorkOSVaultAPIKeyStore.fileName,
            json: "{\"version\":1,\"api_key\":\"sk-round\"}"
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: dir.path)
        #expect(WorkOSVaultAPIKeyStore.load(from: dir) == .failure(.unsafeLocation))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        // Oversized file.
        try writeWorkOSFile(
            at: dir, name: WorkOSVaultAPIKeyStore.fileName,
            json: String(repeating: "x", count: 5_000)
        )
        #expect(WorkOSVaultAPIKeyStore.load(from: dir) == .failure(.oversized))
        // Symlink denied (inaccessible reads as unreadable).
        try FileManager.default.removeItem(
            at: dir.appendingPathComponent(WorkOSVaultAPIKeyStore.fileName)
        )
        let target = dir.appendingPathComponent("real.json")
        try "{\"version\":1,\"api_key\":\"sk-x\"}".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent(WorkOSVaultAPIKeyStore.fileName),
            withDestinationURL: target
        )
        #expect(WorkOSVaultAPIKeyStore.load(from: dir) == .failure(.unreadable))
    }

    @Test func endpointDecode() {
        // Minimal doc: only tenant required, everything else defaults.
        let minimal = WorkOSVaultEndpointStore.decode(Data("{\"version\":1,\"tenant\":\"t\"}".utf8))
        switch minimal {
        case .success(let config):
            #expect(config.endpoint.absoluteString == "https://api.workos.com")
            #expect(config.timeoutSeconds == 10)
            #expect(config.objectPrefix == "executor")
            #expect(config.tenant == "t")
            #expect(config.subject == nil)
        case .failure:
            Issue.record("minimal doc must decode")
        }
        let full = WorkOSVaultEndpointStore.decode(Data(
            """
            {"version":1,"endpoint":"http://127.0.0.1:5392","timeoutSeconds":5,\
            "objectPrefix":"rv","tenant":"tenant-a","subject":"subject-a"}
            """.utf8
        ))
        switch full {
        case .success(let config):
            #expect(config.endpoint.absoluteString == "http://127.0.0.1:5392")
            #expect(config.timeoutSeconds == 5)
            #expect(config.objectPrefix == "rv")
            #expect(config.tenant == "tenant-a")
            #expect(config.subject == "subject-a")
        case .failure:
            Issue.record("full doc must decode")
        }
        for doc in [
            "{not json",
            "{\"version\":2,\"tenant\":\"t\"}",
            "{\"version\":1}",
            "{\"version\":1,\"tenant\":\"\"}",
            "{\"version\":1,\"tenant\":\"t\",\"endpoint\":\"https://api.workos.com/x\"}",
            "{\"version\":1,\"tenant\":\"t\",\"endpoint\":\"http://api.workos.com\"}",
            "{\"version\":1,\"tenant\":\"t\",\"endpoint\":\"http://exa mple.com\"}",
            "{\"version\":1,\"tenant\":\"t\",\"timeoutSeconds\":0}",
            "{\"version\":1,\"tenant\":\"t\",\"objectPrefix\":\"a/b\"}",
            "{\"version\":1,\"tenant\":\"t\",\"smuggled\":1}",
            "{\"tenant\":\"t\"}",
        ] {
            #expect(
                WorkOSVaultEndpointStore.decode(Data(doc.utf8))
                    == .failure(.configInvalid),
                "rejects \(doc.prefix(48))"
            )
        }
        #expect(
            WorkOSVaultEndpointStore.decode(Data(repeating: 0x61, count: 5_000))
                == .failure(.configInvalid)
        )
    }

    @Test func endpointLoad() throws {
        let dir = try makeTempWorkOSDir(prefix: "rv-workos-endpoint")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Absent config loads as nil: the provider is opt-in.
        switch WorkOSVaultEndpointStore.load(from: dir) {
        case .success(nil):
            break
        default:
            Issue.record("absent config must load nil")
        }
        try writeWorkOSFile(
            at: dir, name: WorkOSVaultEndpointStore.fileName,
            json: "{\"version\":1,\"tenant\":\"tenant-a\"}"
        )
        switch WorkOSVaultEndpointStore.load(from: dir) {
        case .success(let config?):
            #expect(config.tenant == "tenant-a")
        default:
            Issue.record("present config must load")
        }
        try writeWorkOSFile(
            at: dir, name: WorkOSVaultEndpointStore.fileName, json: "{corrupt"
        )
        #expect(
            WorkOSVaultEndpointStore.load(from: dir) == .failure(.configInvalid)
        )
        // Unsafe location fails closed, never as absent.
        try writeWorkOSFile(
            at: dir, name: WorkOSVaultEndpointStore.fileName,
            json: "{\"version\":1,\"tenant\":\"tenant-a\"}"
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: dir.path)
        #expect(
            WorkOSVaultEndpointStore.load(from: dir) == .failure(.configInvalid)
        )
    }
}

private func createJSON(id: String, version: Int) -> Data {
    Data("{\"id\":\"\(id)\",\"metadata\":{\"version_id\":\"v\(version)\"}}".utf8)
}

private func errorJSON(_ message: String) -> Data {
    let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
    return Data("{\"message\":\"\(escaped)\"}".utf8)
}
