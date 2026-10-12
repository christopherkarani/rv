import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RVDomain
import RVFileStore
import Synchronization
import Testing
@testable import RVIsolation

// MARK: - Helpers

private struct FactoryStubHTTPError: Error {}

private func makeFactoryTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-factory-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
}

private func writeFactoryFile(
    at directory: URL, name: String, json: String, mode: Int = 0o600
) throws {
    let url = directory.appendingPathComponent(name)
    try json.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

/// Always-on provider ids on this platform: file plus env everywhere,
/// keychain only where the platform supports it (absent on Linux).
private func expectedAlwaysOnIDs() -> [String] {
    var ids = ["env", "file"]
    if KeychainSecretsProvider.currentPlatform() != nil {
        ids.append("keychain")
    }
    return ids.sorted()
}

private func approleJSON() -> String {
    #"{"version":1,"role_id":"factory-test-role","secret_id":"factory-test-secret"}"#
}

private func vaultClient(
    in providers: [any SecretsProvider]
) throws -> VaultHTTPClient {
    let vaults = providers.compactMap { $0 as? VaultHTTPClient }
    #expect(vaults.count == 1)
    return try #require(vaults.first)
}

/// Stub transport answering healthy `sys/health` for every request.
private func healthyFactoryStub() -> @Sendable (URLRequest) async throws -> (
    Data, HTTPURLResponse
) {
    { request in
        let url = request.url ?? URL(string: "https://vault.example.com")!
        guard let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: nil
        ) else {
            throw FactoryStubHTTPError()
        }
        let body = #"{"initialized":true,"sealed":false,"standby":false,"version":"1.15.0"}"#
        return (Data(body.utf8), response)
    }
}

private final class FactoryAuditCapture: Sendable {
    let mutex = Mutex<[SecretsAuditRecord]>([])

    var sink: SecretBrokerAuditSink {
        SecretBrokerAuditSink(append: { events in
            self.mutex.withLock { $0 += events }
        })
    }

    var events: [SecretsAuditRecord] {
        mutex.withLock { $0 }
    }
}

private func makeFactoryInstance() -> AgentInstance {
    AgentInstance(
        id: AgentInstanceID(),
        owner: OwnerPrincipal(uid: 501),
        definitionID: AgentDefinitionID(rawValue: "factory-test-agent"),
        definitionRevision: AgentDefinitionRevision(digestHex: String(repeating: "b", count: 64)),
        workspaceSessionID: WorkspaceSessionID(),
        runtimeSessionID: RuntimeSessionID(),
        executableEvidence: .none,
        assurance: .launchObserved,
        groupLeader: RuntimeChildIdentity(pid: 100),
        workloadProcess: nil,
        parent: nil,
        effectiveAuthority: AgentAuthority(scopes: []),
        delegableAuthority: AgentAuthority(scopes: []),
        mintedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func makeFactoryContext() -> AuthenticatedAgentContext {
    AuthenticatedAgentContext(instance: makeFactoryInstance(), validity: .active)
}

// MARK: - Suite

@Suite("SecretsProviderFactory")
struct SecretsProviderFactoryTests {
    // MARK: Matrix — no config

    @Test func missingDirectoryBuildsAlwaysOnProviders() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-factory-missing-\(UUID().uuidString)")
        let providers = try SecretsProviderFactory.makeProviders(configDirectory: missing)
        #expect(providers.map(\.id).sorted() == expectedAlwaysOnIDs())
    }

    @Test func emptyDirectoryBuildsAlwaysOnProviders() throws {
        let dir = try makeFactoryTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let providers = try SecretsProviderFactory.makeProviders(configDirectory: dir)
        #expect(providers.map(\.id).sorted() == expectedAlwaysOnIDs())
    }

    // MARK: Matrix — file only

    @Test func fileOnlyConfigOmitsVault() throws {
        let dir = try makeFactoryTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFactoryFile(
            at: dir, name: "secrets-providers.json",
            json: #"{"version":1,"bindings":[{"name":"token","provider":"file","item":"github/token"}]}"#
        )
        try writeFactoryFile(
            at: dir, name: "secrets-file.json",
            json: #"{"version":1,"items":{"github/token":{"text":"file-value-1"}}}"#
        )
        let providers = try SecretsProviderFactory.makeProviders(configDirectory: dir)
        #expect(providers.map(\.id).sorted() == expectedAlwaysOnIDs())
        #expect(providers.map(\.id).contains("vault-http") == false)
    }

    // MARK: Matrix — vault iff vault config

    @Test func bindingsNamingVaultWithoutEndpointOmitsVault() throws {
        let dir = try makeFactoryTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFactoryFile(
            at: dir, name: "secrets-providers.json",
            json: #"{"version":1,"bindings":[{"name":"db","provider":"vault-http","item":"db/creds"}]}"#
        )
        let providers = try SecretsProviderFactory.makeProviders(configDirectory: dir)
        #expect(providers.map(\.id).sorted() == expectedAlwaysOnIDs())
        #expect(providers.map(\.id).contains("vault-http") == false)
    }

    @Test func vaultPresentAddsVaultClient() throws {
        let dir = try makeFactoryTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFactoryFile(
            at: dir, name: "secrets-providers.json",
            json: #"{"version":1,"bindings":[{"name":"db","provider":"vault-http","item":"db/creds"}]}"#
        )
        try writeFactoryFile(
            at: dir, name: "vault.json",
            json: #"{"version":1,"endpoint":"https://vault.example.com:8200"}"#
        )
        try writeFactoryFile(at: dir, name: "vault-approle.json", json: approleJSON())
        let providers = try SecretsProviderFactory.makeProviders(
            configDirectory: dir, transport: healthyFactoryStub()
        )
        #expect(
            providers.map(\.id).sorted() == (expectedAlwaysOnIDs() + ["vault-http"]).sorted()
        )
    }

    @Test func providerIDsAreAllowlisted() throws {
        let dir = try makeFactoryTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFactoryFile(
            at: dir, name: "vault.json",
            json: #"{"version":1,"endpoint":"https://vault.example.com:8200"}"#
        )
        try writeFactoryFile(at: dir, name: "vault-approle.json", json: approleJSON())
        let providers = try SecretsProviderFactory.makeProviders(
            configDirectory: dir, transport: healthyFactoryStub()
        )
        for id in providers.map(\.id) {
            #expect(SecretRef.allowedProviders.contains(id))
        }
    }

    // MARK: Vault client shape

    @Test func vaultClientShapeUsesConfigAndDefaults() throws {
        let dir = try makeFactoryTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFactoryFile(
            at: dir, name: "vault.json",
            json: #"{"version":1,"endpoint":"https://vault.example.com:8200"}"#
        )
        try writeFactoryFile(at: dir, name: "vault-approle.json", json: approleJSON())
        let providers = try SecretsProviderFactory.makeProviders(
            configDirectory: dir, transport: healthyFactoryStub(), tracker: VaultLeaseTracker()
        )
        let client = try vaultClient(in: providers)
        #expect(client.id == "vault-http")
        #expect(client.endpoint.absoluteString == "https://vault.example.com:8200")
        #expect(client.mount == VaultHTTPClient.defaultMount)
        #expect(client.tls == .system)
        #expect(client.timeoutSeconds == VaultHTTPClient.defaultTimeoutSeconds)
        #expect(client.wrapTTL == nil)
        #expect(client.auth.label == "approle")
    }

    @Test func vaultClientShapeHonorsFullConfig() throws {
        let dir = try makeFactoryTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pin = Data(repeating: 0x30, count: 256).base64EncodedString()
        try writeFactoryFile(
            at: dir, name: "vault.json",
            json: """
                {"version":1,"endpoint":"https://vault.example.com","mount":"team/sub",\
                "tls":{"pinnedLeafDER":"\(pin)"},"timeoutSeconds":30,"wrapTTL":"5m"}
                """
        )
        try writeFactoryFile(at: dir, name: "vault-approle.json", json: approleJSON())
        let providers = try SecretsProviderFactory.makeProviders(
            configDirectory: dir, transport: healthyFactoryStub()
        )
        let client = try vaultClient(in: providers)
        #expect(client.mount == "team/sub")
        #expect(client.tls == .pinnedLeafDER(Data(repeating: 0x30, count: 256)))
        #expect(client.timeoutSeconds == 30)
        #expect(client.wrapTTL == "5m")
    }

    @Test func explicitSystemTLSFactoryShape() throws {
        let dir = try makeFactoryTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFactoryFile(
            at: dir, name: "vault.json",
            json: #"{"version":1,"endpoint":"https://vault.example.com:8200","tls":"system"}"#
        )
        try writeFactoryFile(at: dir, name: "vault-approle.json", json: approleJSON())
        let providers = try SecretsProviderFactory.makeProviders(
            configDirectory: dir, transport: healthyFactoryStub()
        )
        let client = try vaultClient(in: providers)
        #expect(client.tls == .system)
    }

    @Test func injectedTransportIsWired() async throws {
        let dir = try makeFactoryTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFactoryFile(
            at: dir, name: "vault.json",
            json: #"{"version":1,"endpoint":"https://vault.example.com:8200"}"#
        )
        try writeFactoryFile(at: dir, name: "vault-approle.json", json: approleJSON())
        let providers = try SecretsProviderFactory.makeProviders(
            configDirectory: dir, transport: healthyFactoryStub()
        )
        let client = try vaultClient(in: providers)
        let health = await client.health()
        #expect(health.ok == true)
        #expect(health.identity == nil)
    }

    @Test func liveTransportBuildsLiveClient() throws {
        let dir = try makeFactoryTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFactoryFile(
            at: dir, name: "vault.json",
            json: #"{"version":1,"endpoint":"https://vault.example.com:8200"}"#
        )
        try writeFactoryFile(at: dir, name: "vault-approle.json", json: approleJSON())
        let providers = try SecretsProviderFactory.makeProviders(configDirectory: dir)
        let client = try vaultClient(in: providers)
        #expect(client.endpoint.absoluteString == "https://vault.example.com:8200")
        #expect(client.auth.label == "approle")
    }

    #if os(Linux)
    @Test func pinnedLiveClientFailsMisconfiguredOnLinux() throws {
        let dir = try makeFactoryTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pin = Data(repeating: 0x30, count: 256).base64EncodedString()
        try writeFactoryFile(
            at: dir, name: "vault.json",
            json: """
                {"version":1,"endpoint":"https://vault.example.com",\
                "tls":{"pinnedLeafDER":"\(pin)"}}
                """
        )
        try writeFactoryFile(at: dir, name: "vault-approle.json", json: approleJSON())
        #expect(throws: SecretsProviderFactoryError.vaultMisconfigured) {
            try SecretsProviderFactory.makeProviders(configDirectory: dir)
        }
    }
    #endif

    // MARK: Matrix — workos-vault iff workos config (X1-G parent hookup)

    @Test func workosPresentAddsProvider() throws {
        let dir = try makeFactoryTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFactoryFile(
            at: dir, name: "workos-vault.json",
            json: #"{"version":1,"endpoint":"https://api.workos.test","tenant":"factory-tenant"}"#
        )
        try writeFactoryFile(
            at: dir, name: "workos-vault-apikey.json",
            json: #"{"version":1,"api_key":"factory-test-key"}"#
        )
        let providers = try SecretsProviderFactory.makeProviders(configDirectory: dir)
        #expect(
            providers.map(\.id).sorted() == (expectedAlwaysOnIDs() + ["workos-vault"]).sorted()
        )
        let workos = try #require(providers.compactMap { $0 as? WorkOSVaultSecretsProvider }.first)
        #expect(workos.id == "workos-vault")
    }

    @Test func corruptWorkosConfigFailsClosed() throws {
        let dir = try makeFactoryTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFactoryFile(at: dir, name: "workos-vault.json", json: "not-json{{{")
        try writeFactoryFile(
            at: dir, name: "workos-vault-apikey.json",
            json: #"{"version":1,"api_key":"factory-test-key"}"#
        )
        #expect(throws: SecretsProviderFactoryError.workosVaultConfigInvalid) {
            try SecretsProviderFactory.makeProviders(configDirectory: dir)
        }
    }

    @Test func workosWithoutKeyFailsCredentials() throws {
        let dir = try makeFactoryTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFactoryFile(
            at: dir, name: "workos-vault.json",
            json: #"{"version":1,"tenant":"factory-tenant"}"#
        )
        #expect(throws: SecretsProviderFactoryError.workosVaultCredentialsInvalid) {
            try SecretsProviderFactory.makeProviders(configDirectory: dir)
        }
    }

    #if canImport(SQLite3)
    @Test func workosBlockedDatabaseFailsMisconfigured() throws {
        let dir = try makeFactoryTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFactoryFile(
            at: dir, name: "workos-vault.json",
            json: #"{"version":1,"tenant":"factory-tenant"}"#
        )
        try writeFactoryFile(
            at: dir, name: "workos-vault-apikey.json",
            json: #"{"version":1,"api_key":"factory-test-key"}"#
        )
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(WorkOSVaultMetadataStore.fileName),
            withIntermediateDirectories: false
        )
        #expect(throws: SecretsProviderFactoryError.workosVaultMisconfigured) {
            try SecretsProviderFactory.makeProviders(configDirectory: dir)
        }
    }
    #endif

    // MARK: Matrix — corrupt config fails closed

    @Test func corruptBindingsFailsClosed() throws {
        let dir = try makeFactoryTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFactoryFile(at: dir, name: "secrets-providers.json", json: "not-json{{{")
        #expect(throws: SecretsProviderFactoryError.providersInvalid) {
            try SecretsProviderFactory.makeProviders(configDirectory: dir)
        }
    }

    @Test func unsafeBindingsFailsClosed() throws {
        let dir = try makeFactoryTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFactoryFile(
            at: dir, name: "secrets-providers.json",
            json: #"{"version":1,"bindings":[]}"#, mode: 0o644
        )
        #expect(throws: SecretsProviderFactoryError.providersInvalid) {
            try SecretsProviderFactory.makeProviders(configDirectory: dir)
        }
    }

    @Test func corruptVaultConfigFailsClosed() throws {
        let dir = try makeFactoryTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFactoryFile(at: dir, name: "vault.json", json: "not-json{{{")
        try writeFactoryFile(at: dir, name: "vault-approle.json", json: approleJSON())
        #expect(throws: SecretsProviderFactoryError.vaultConfigInvalid) {
            try SecretsProviderFactory.makeProviders(configDirectory: dir)
        }
    }

    @Test func unsafeVaultConfigFailsClosed() throws {
        let dir = try makeFactoryTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFactoryFile(
            at: dir, name: "vault.json",
            json: #"{"version":1,"endpoint":"https://vault.example.com:8200"}"#, mode: 0o644
        )
        try writeFactoryFile(at: dir, name: "vault-approle.json", json: approleJSON())
        #expect(throws: SecretsProviderFactoryError.vaultConfigInvalid) {
            try SecretsProviderFactory.makeProviders(configDirectory: dir)
        }
    }

    @Test func oversizedVaultConfigFailsClosed() throws {
        let dir = try makeFactoryTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let padding = String(repeating: "p", count: VaultEndpointStore.maximumBytes)
        try writeFactoryFile(
            at: dir, name: "vault.json",
            json: #"{"version":1,"endpoint":"https://vault.example.com","wrapTTL":"\#(padding)"}"#
        )
        #expect(throws: SecretsProviderFactoryError.vaultConfigInvalid) {
            try SecretsProviderFactory.makeProviders(configDirectory: dir)
        }
    }

    @Test func symlinkedVaultConfigFailsClosed() throws {
        let dir = try makeFactoryTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("vault-real.json")
        try #"{"version":1,"endpoint":"https://vault.example.com:8200"}"#.write(
            to: target, atomically: true, encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("vault.json"),
            withDestinationURL: target
        )
        try writeFactoryFile(at: dir, name: "vault-approle.json", json: approleJSON())
        #expect(throws: SecretsProviderFactoryError.vaultConfigInvalid) {
            try SecretsProviderFactory.makeProviders(configDirectory: dir)
        }
    }

    @Test func vaultConfigWithoutCredentialsFailsClosed() throws {
        let dir = try makeFactoryTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFactoryFile(
            at: dir, name: "vault.json",
            json: #"{"version":1,"endpoint":"https://vault.example.com:8200"}"#
        )
        #expect(throws: SecretsProviderFactoryError.vaultCredentialsInvalid) {
            try SecretsProviderFactory.makeProviders(
                configDirectory: dir, transport: healthyFactoryStub()
            )
        }
    }

    @Test func vaultConfigWithCorruptCredentialsFailsClosed() throws {
        let dir = try makeFactoryTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFactoryFile(
            at: dir, name: "vault.json",
            json: #"{"version":1,"endpoint":"https://vault.example.com:8200"}"#
        )
        try writeFactoryFile(at: dir, name: "vault-approle.json", json: "not-json{{{")
        #expect(throws: SecretsProviderFactoryError.vaultCredentialsInvalid) {
            try SecretsProviderFactory.makeProviders(
                configDirectory: dir, transport: healthyFactoryStub()
            )
        }
    }

    // MARK: Vault config decode

    @Test func minimalVaultConfigDecodesWithDefaults() throws {
        let config = try VaultEndpointStore.decode(
            Data(#"{"version":1,"endpoint":"https://vault.example.com:8200"}"#.utf8)
        ).get()
        #expect(config.endpoint.absoluteString == "https://vault.example.com:8200")
        #expect(config.mount == VaultHTTPClient.defaultMount)
        #expect(config.tls == .system)
        #expect(config.timeoutSeconds == VaultHTTPClient.defaultTimeoutSeconds)
        #expect(config.wrapTTL == nil)
    }

    @Test func fullVaultConfigDecodes() throws {
        let pin = Data(repeating: 0x30, count: 256).base64EncodedString()
        let config = try VaultEndpointStore.decode(
            Data(
                """
                {"version":1,"endpoint":"http://127.0.0.1:8200","mount":"team/sub",\
                "tls":{"pinnedLeafDER":"\(pin)"},"timeoutSeconds":30,"wrapTTL":"1h"}
                """.utf8
            )
        ).get()
        #expect(config.endpoint.absoluteString == "http://127.0.0.1:8200")
        #expect(config.mount == "team/sub")
        #expect(config.tls == .pinnedLeafDER(Data(repeating: 0x30, count: 256)))
        #expect(config.timeoutSeconds == 30)
        #expect(config.wrapTTL == "1h")
    }

    @Test func explicitSystemTLSStringDecodes() throws {
        let config = try VaultEndpointStore.decode(
            Data(
                #"{"version":1,"endpoint":"https://vault.example.com","tls":"system"}"#.utf8
            )
        ).get()
        #expect(config.tls == .system)
    }

    @Test func nullMembersDecodeAsAbsent() throws {
        let config = try VaultEndpointStore.decode(
            Data(
                """
                {"version":1,"endpoint":"https://vault.example.com",\
                "mount":null,"tls":null,"timeoutSeconds":null,"wrapTTL":null}
                """.utf8
            )
        ).get()
        #expect(config.mount == VaultHTTPClient.defaultMount)
        #expect(config.tls == .system)
        #expect(config.timeoutSeconds == VaultHTTPClient.defaultTimeoutSeconds)
        #expect(config.wrapTTL == nil)
    }

    @Test(
        "invalid vault documents fail decode",
        arguments: [
            "not-json{{{",
            #"{"version":2,"endpoint":"https://vault.example.com"}"#,
            #"{"version":"1","endpoint":"https://vault.example.com"}"#,
            #"{"version":1}"#,
            #"{"version":1,"endpoint":""}"#,
            #"{"version":1,"endpoint":"notaurl"}"#,
            #"{"version":1,"endpoint":"https://"}"#,
            #"{"version":1,"endpoint":"ftp://vault.example.com"}"#,
            #"{"version":1,"endpoint":"https://vault.example.com/path"}"#,
            #"{"version":1,"endpoint":"http://vault.example.com"}"#,
            #"{"version":1,"endpoint":"https://vault.example.com","mount":""}"#,
            #"{"version":1,"endpoint":"https://vault.example.com","mount":"/lead"}"#,
            #"{"version":1,"endpoint":"https://vault.example.com","mount":"trail/"}"#,
            #"{"version":1,"endpoint":"https://vault.example.com","tls":"bogus"}"#,
            #"{"version":1,"endpoint":"https://vault.example.com","tls":123}"#,
            #"{"version":1,"endpoint":"https://vault.example.com","tls":{}}"#,
            #"{"version":1,"endpoint":"https://vault.example.com","tls":{"pinnedLeafDER":"!!!"}}"#,
            #"{"version":1,"endpoint":"https://vault.example.com","tls":{"pinnedLeafDER":"QUJDREVGR0hJSg=="}}"#,
            #"{"version":1,"endpoint":"https://vault.example.com","tls":{"pinnedLeafDER":"aGk=","extra":1}}"#,
            #"{"version":1,"endpoint":"https://vault.example.com","timeoutSeconds":0}"#,
            #"{"version":1,"endpoint":"https://vault.example.com","timeoutSeconds":61}"#,
            #"{"version":1,"endpoint":"https://vault.example.com","timeoutSeconds":"10"}"#,
            #"{"version":1,"endpoint":"https://vault.example.com","wrapTTL":"30x"}"#,
            #"{"version":1,"endpoint":"https://vault.example.com","wrapTTL":"30"}"#,
            #"{"version":1,"endpoint":"https://vault.example.com","wrapTTL":"0s"}"#,
            #"{"version":1,"endpoint":"https://vault.example.com","bogus":true}"#,
        ]
    )
    func invalidVaultDocumentsFailDecode(json: String) {
        #expect(
            VaultEndpointStore.decode(Data(json.utf8))
                == .failure(.vaultConfigInvalid)
        )
    }

    @Test func oversizedVaultDocumentFailsDecode() {
        let padding = String(repeating: "p", count: VaultEndpointStore.maximumBytes)
        #expect(
            VaultEndpointStore.decode(
                Data(
                    #"{"version":1,"endpoint":"https://vault.example.com","wrapTTL":"\#(padding)"}"#.utf8
                )
            ) == .failure(.vaultConfigInvalid)
        )
    }

    // MARK: Env provider

    @Test func envProviderResolvesInjectedMap() async throws {
        let provider = EnvSecretsProvider(environment: {
            ["PRESENT": "env-value-1", "EMPTY": ""]
        })
        #expect(provider.id == "env")
        let hit = try await provider.resolve(try SecretRef(provider: "env", item: "PRESENT"))
        #expect(hit == .text("env-value-1"))
        let empty = try await provider.resolve(try SecretRef(provider: "env", item: "EMPTY"))
        #expect(empty == .text(""))
        await #expect(throws: SecretsError.notFound("env")) {
            try await provider.resolve(try SecretRef(provider: "env", item: "MISSING"))
        }
        #expect(await provider.health() == ProviderHealth(ok: true))
    }

    @Test func envProviderRejectsFieldRefs() async throws {
        let provider = EnvSecretsProvider(environment: { ["PRESENT": "env-value-1"] })
        await #expect(throws: SecretsError.notFound("env")) {
            try await provider.resolve(
                try SecretRef(provider: "env", item: "PRESENT", field: "sub")
            )
        }
    }

    @Test func envProviderDefaultReadsLiveEnvironment() async throws {
        // The default closure reads the live process environment: whatever
        // is present resolves, and a surely-absent name fails closed.
        let provider = EnvSecretsProvider()
        #expect(provider.id == "env")
        if let live = ProcessInfo.processInfo.environment.first(where: { $0.key.isEmpty == false }) {
            let hit = try await provider.resolve(try SecretRef(provider: "env", item: live.key))
            #expect(hit == .text(live.value))
        }
        await #expect(throws: SecretsError.notFound("env")) {
            try await provider.resolve(
                try SecretRef(provider: "env", item: "RV_E1F_DEFINITELY_ABSENT_VAR")
            )
        }
    }

    // MARK: Broker wiring

    @Test func makeBrokerResolvesThroughFactoryProviders() async throws {
        let dir = try makeFactoryTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFactoryFile(
            at: dir, name: "secrets-file.json",
            json: #"{"version":1,"items":{"deploy/token":{"text":"factory-e2e-value"}}}"#
        )
        let capture = FactoryAuditCapture()
        let broker = try SecretsProviderFactory.makeBroker(
            configDirectory: dir, audit: capture.sink, liveness: .usableOnly
        )
        #expect(await broker.providerIDs.sorted() == expectedAlwaysOnIDs())
        let ref = try SecretRef(provider: "file", item: "deploy/token")
        let values = try await broker.resolve([ref], ctx: makeFactoryContext())
        #expect(values[ref] == .text("factory-e2e-value"))
        #expect(capture.events.isEmpty == false)
    }

    @Test func makeBrokerFailsClosedOnCorruptConfig() throws {
        let dir = try makeFactoryTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFactoryFile(at: dir, name: "secrets-providers.json", json: "not-json{{{")
        let capture = FactoryAuditCapture()
        #expect(throws: SecretsProviderFactoryError.providersInvalid) {
            try SecretsProviderFactory.makeBroker(
                configDirectory: dir, audit: capture.sink, liveness: .usableOnly
            )
        }
    }
}
