import Foundation
import RVDomain
import RVFileStore
import Synchronization
import Testing
@testable import RVIsolation

// MARK: - Helpers

private struct StubForeignError: Error {}

private struct StubScript: Sendable {
    var healthOK = true
    var healthDelay: Duration = .zero
    var resolveDelay: Duration = .zero
    var resolveError: SecretsError?
    var foreignError = false
    var values: [SecretRef: SecretValue] = [:]
    var defaultValue: SecretValue? = .text("stub-default-value")
    var healthCalls = 0
    var resolveCalls: [SecretRef] = []
}

private final class StubState: Sendable {
    let mutex = Mutex(StubScript())
}

private struct StubProvider: SecretsProvider, Sendable {
    var id: String
    var state: StubState

    init(_ id: String, configure: (inout StubScript) -> Void = { _ in }) {
        self.id = id
        let state = StubState()
        state.mutex.withLock { configure(&$0) }
        self.state = state
    }

    func health() async -> ProviderHealth {
        let delay = state.mutex.withLock { script -> Duration in
            script.healthCalls += 1
            return script.healthDelay
        }
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        return state.mutex.withLock { ProviderHealth(ok: $0.healthOK) }
    }

    func resolve(_ ref: SecretRef) async throws -> SecretValue {
        let script = state.mutex.withLock { script -> StubScript in
            script.resolveCalls.append(ref)
            return script
        }
        if script.resolveDelay > .zero {
            // Plain try: cancellation surfaces as CancellationError so the
            // broker's rethrow (not provider-down mapping) is exercised.
            try await Task.sleep(for: script.resolveDelay)
        }
        if script.foreignError {
            throw StubForeignError()
        }
        if let error = script.resolveError {
            throw error
        }
        if let value = script.values[ref] {
            return value
        }
        if let fallback = script.defaultValue {
            return fallback
        }
        throw SecretsError.notFound(id)
    }

    var healthCalls: Int {
        state.mutex.withLock { $0.healthCalls }
    }

    var resolveCalls: [SecretRef] {
        state.mutex.withLock { $0.resolveCalls }
    }
}

private final class AuditCapture: Sendable {
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

private func makeInstance() -> AgentInstance {
    AgentInstance(
        id: AgentInstanceID(),
        owner: OwnerPrincipal(uid: 501),
        definitionID: AgentDefinitionID(rawValue: "test-agent"),
        definitionRevision: AgentDefinitionRevision(digestHex: String(repeating: "a", count: 64)),
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

private func makeContext(validity: AgentInstanceValidity = .active) -> AuthenticatedAgentContext {
    AuthenticatedAgentContext(instance: makeInstance(), validity: validity)
}

private func makeRef(
    _ provider: String,
    _ item: String,
    _ field: String? = nil
) throws -> SecretRef {
    try SecretRef(provider: provider, item: item, field: field)
}

private func makeTempDir(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
}

private func writeSecretsFile(at directory: URL, json: String, mode: Int = 0o600) throws {
    let url = directory.appendingPathComponent(FileSecretsProvider.fileName)
    try json.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

private func readAuditEvents(at directory: URL) throws -> [SecretsAuditRecord] {
    let url = directory.appendingPathComponent(SecretsAuditPaths.fileName)
    let text = try String(contentsOf: url, encoding: .utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try text.split(separator: "\n").map { line in
        try decoder.decode(SecretsAuditRecord.self, from: Data(line.utf8))
    }
}

private func readAuditText(at directory: URL) throws -> String {
    try String(
        contentsOf: directory.appendingPathComponent(SecretsAuditPaths.fileName),
        encoding: .utf8
    )
}

private func posixPermissions(of url: URL) throws -> Int {
    let raw = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    return try #require(raw) & 0o777
}

/// Deterministic mid-flight gate: the stub waits here until the test opens
/// it. Late opens still release a waiter that has not arrived yet, so no
/// interleaving can hang the test.
private final class ResolveGate: Sendable {
    private let mutex = Mutex(State())

    private struct State: Sendable {
        var entered = false
        var opened = false
        var continuation: CheckedContinuation<Void, Never>?
    }

    func waitForEntry() async {
        for _ in 0..<10_000 {
            if mutex.withLock({ $0.entered }) {
                return
            }
            await Task.yield()
        }
    }

    func wait() async {
        let alreadyOpen = mutex.withLock { state -> Bool in
            state.entered = true
            return state.opened
        }
        if alreadyOpen {
            return
        }
        await withCheckedContinuation { continuation in
            let lateOpen = mutex.withLock { state -> Bool in
                if state.opened {
                    return true
                }
                state.continuation = continuation
                return false
            }
            if lateOpen {
                continuation.resume()
            }
        }
    }

    func open() {
        let pending = mutex.withLock { state -> CheckedContinuation<Void, Never>? in
            state.opened = true
            let pending = state.continuation
            state.continuation = nil
            return pending
        }
        pending?.resume()
    }
}

private struct GatedProvider: SecretsProvider, Sendable {
    var id: String
    var gate: ResolveGate
    var value: SecretValue

    func health() async -> ProviderHealth {
        ProviderHealth(ok: true)
    }

    func resolve(_ ref: SecretRef) async throws -> SecretValue {
        await gate.wait()
        return value
    }
}

/// Faulty/hostile provider: throws CancellationError with no cancellation.
private struct CancellingProvider: SecretsProvider, Sendable {
    var id: String

    func health() async -> ProviderHealth {
        ProviderHealth(ok: true)
    }

    func resolve(_ ref: SecretRef) async throws -> SecretValue {
        throw CancellationError()
    }
}

/// Health that swallows cancellation and succeeds only when the gate opens.
/// The gate wait never throws, so a cancelled call still yields a worker
/// success against the broker's multi-second sleeper: deterministic win.
private struct GatedHealthProvider: SecretsProvider, Sendable {
    var id: String
    var gate: ResolveGate
    var value: SecretValue

    func health() async -> ProviderHealth {
        await gate.wait()
        return ProviderHealth(ok: true)
    }

    func resolve(_ ref: SecretRef) async throws -> SecretValue {
        value
    }
}

private struct BrokerRegistryHarness {
    let root: URL
    let registry: AgentInstanceRegistry
    let instance: AgentInstance
    let session: RuntimeSession

    init() throws {
        root = try makeTempDir(prefix: "rv-secret-broker-registry")
        registry = AgentInstanceRegistry(
            journal: .file(root.appendingPathComponent("instances.jsonl"))
        )
        let workspace = WorkspaceSessionID()
        let runtime = RuntimeSessionID()
        instance = AgentInstance(
            id: AgentInstanceID(),
            owner: OwnerPrincipal(uid: 501),
            definitionID: AgentDefinitionID(rawValue: "test-agent"),
            definitionRevision: AgentDefinitionRevision(
                digestHex: String(repeating: "a", count: 64)
            ),
            workspaceSessionID: workspace,
            runtimeSessionID: runtime,
            executableEvidence: .none,
            assurance: .launchObserved,
            groupLeader: RuntimeChildIdentity(pid: 100),
            workloadProcess: nil,
            parent: nil,
            effectiveAuthority: AgentAuthority(scopes: []),
            delegableAuthority: AgentAuthority(scopes: []),
            mintedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        session = RuntimeSession(
            id: runtime,
            workspaceSessionID: workspace,
            host: .opencode,
            workspace: try #require(WorkingDirectory(validating: root.path)),
            backend: .seatbelt,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            child: nil
        )
        #expect(registry.announce(instance))
        let established = try #require(
            EstablishedRuntimeSession(session: session, instance: instance, establishedAt: Date())
        )
        #expect(registry.activate(established)?.validity == .active)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func makeBroker(
    providers: [any SecretsProvider],
    capture: AuditCapture,
    timeoutSeconds: Double = 5,
    liveness: SecretBrokerLiveness = .usableOnly
) -> SecretBroker {
    SecretBroker(
        providers: providers,
        audit: capture.sink,
        liveness: liveness,
        timeoutSeconds: timeoutSeconds
    )
}

/// Liveness that passes the entry check and fails the commit check: the
/// first `isLive` call (entry) returns true, every later call is stale.
private func staleAtCommitLiveness() -> SecretBrokerLiveness {
    final class Calls: Sendable {
        let mutex = Mutex(0)
    }
    let calls = Calls()
    return SecretBrokerLiveness(
        snapshot: { _ in 7 },
        isLive: { _, _ in
            calls.mutex.withLock { count in
                count += 1
                return count == 1
            }
        }
    )
}

// MARK: - File provider

@Suite("FileSecretsProvider")
struct FileSecretsProviderTests {
    @Test func resolvesWholeItemText() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSecretsFile(
            at: dir,
            json: #"{"version":1,"items":{"github/token":{"text":"ghp-secret-value"}}}"#
        )
        let provider = FileSecretsProvider(configDirectory: dir)
        let value = try await provider.resolve(makeRef("file", "github/token"))
        #expect(value == .text("ghp-secret-value"))
        #expect(await provider.health() == ProviderHealth(ok: true))
    }

    @Test func resolvesFieldSubvalue() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSecretsFile(
            at: dir,
            json: #"{"version":1,"items":{"deploy":{"fields":{"private":"key-material"}}}}"#
        )
        let provider = FileSecretsProvider(configDirectory: dir)
        let value = try await provider.resolve(makeRef("file", "deploy", "private"))
        #expect(value == .text("key-material"))
    }

    @Test func missingItemIsNotFound() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSecretsFile(
            at: dir,
            json: #"{"version":1,"items":{"present":{"text":"value"}}}"#
        )
        let provider = FileSecretsProvider(configDirectory: dir)
        await #expect(throws: SecretsError.notFound("file")) {
            try await provider.resolve(makeRef("file", "absent"))
        }
        #expect(await provider.health() == ProviderHealth(ok: true))
    }

    @Test func missingFieldIsNotFound() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSecretsFile(
            at: dir,
            json: #"{"version":1,"items":{"deploy":{"fields":{"public":"x"}}}}"#
        )
        let provider = FileSecretsProvider(configDirectory: dir)
        await #expect(throws: SecretsError.notFound("file")) {
            try await provider.resolve(makeRef("file", "deploy", "private"))
        }
    }

    @Test func fieldAgainstTextOnlyItemIsNotFound() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSecretsFile(
            at: dir,
            json: #"{"version":1,"items":{"token":{"text":"value"}}}"#
        )
        let provider = FileSecretsProvider(configDirectory: dir)
        await #expect(throws: SecretsError.notFound("file")) {
            try await provider.resolve(makeRef("file", "token", "field"))
        }
    }

    @Test func wholeAgainstFieldsOnlyItemIsNotFound() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSecretsFile(
            at: dir,
            json: #"{"version":1,"items":{"deploy":{"fields":{"private":"x"}}}}"#
        )
        let provider = FileSecretsProvider(configDirectory: dir)
        await #expect(throws: SecretsError.notFound("file")) {
            try await provider.resolve(makeRef("file", "deploy"))
        }
    }

    @Test func missingFileIsEmptyStore() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = FileSecretsProvider(configDirectory: dir)
        await #expect(throws: SecretsError.notFound("file")) {
            try await provider.resolve(makeRef("file", "anything"))
        }
        #expect(await provider.health() == ProviderHealth(ok: true))
    }

    @Test func missingDirectoryIsEmptyStore() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-broker-file-missing-\(UUID().uuidString)")
        let provider = FileSecretsProvider(configDirectory: dir)
        await #expect(throws: SecretsError.notFound("file")) {
            try await provider.resolve(makeRef("file", "anything"))
        }
        #expect(await provider.health() == ProviderHealth(ok: true))
    }

    @Test func fileAsDirectoryIsProviderDown() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-broker-file-fileasdir-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = FileSecretsProvider(configDirectory: file)
        await #expect(throws: SecretsError.providerDown("file")) {
            try await provider.resolve(makeRef("file", "anything"))
        }
        #expect(await provider.health() == ProviderHealth(ok: false))
    }

    @Test func invalidJSONIsProviderDown() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSecretsFile(at: dir, json: "{not json")
        let provider = FileSecretsProvider(configDirectory: dir)
        await #expect(throws: SecretsError.providerDown("file")) {
            try await provider.resolve(makeRef("file", "anything"))
        }
        #expect(await provider.health() == ProviderHealth(ok: false))
    }

    @Test func unsupportedVersionIsProviderDown() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSecretsFile(at: dir, json: #"{"version":2,"items":{}}"#)
        let provider = FileSecretsProvider(configDirectory: dir)
        await #expect(throws: SecretsError.providerDown("file")) {
            try await provider.resolve(makeRef("file", "anything"))
        }
        #expect(await provider.health() == ProviderHealth(ok: false))
    }

    @Test func oversizedFileIsProviderDown() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSecretsFile(at: dir, json: String(repeating: "x", count: 70_000))
        let provider = FileSecretsProvider(configDirectory: dir)
        await #expect(throws: SecretsError.providerDown("file")) {
            try await provider.resolve(makeRef("file", "anything"))
        }
        #expect(await provider.health() == ProviderHealth(ok: false))
    }

    @Test func groupReadableFileIsProviderDown() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSecretsFile(
            at: dir,
            json: #"{"version":1,"items":{"a":{"text":"b"}}}"#,
            mode: 0o640
        )
        let provider = FileSecretsProvider(configDirectory: dir)
        await #expect(throws: SecretsError.providerDown("file")) {
            try await provider.resolve(makeRef("file", "a"))
        }
        #expect(await provider.health() == ProviderHealth(ok: false))
    }

    @Test func unknownTopLevelKeyIsProviderDown() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        // A value smuggled under an unrecognized key fails closed.
        try writeSecretsFile(
            at: dir,
            json: #"{"version":1,"items":{},"smuggled":"hunter2"}"#
        )
        let provider = FileSecretsProvider(configDirectory: dir)
        await #expect(throws: SecretsError.providerDown("file")) {
            try await provider.resolve(makeRef("file", "anything"))
        }
    }

    @Test func worldWritableDirectoryIsProviderDown() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSecretsFile(
            at: dir,
            json: #"{"version":1,"items":{"a":{"text":"b"}}}"#
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777], ofItemAtPath: dir.path
        )
        let provider = FileSecretsProvider(configDirectory: dir)
        await #expect(throws: SecretsError.providerDown("file")) {
            try await provider.resolve(makeRef("file", "a"))
        }
    }

    @Test func emptyTextIsExplicitEmptySecret() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSecretsFile(
            at: dir,
            json: #"{"version":1,"items":{"empty":{"text":""}}}"#
        )
        let provider = FileSecretsProvider(configDirectory: dir)
        let value = try await provider.resolve(makeRef("file", "empty"))
        #expect(value == .text(""))
    }

    @Test func recordWithNeitherTextNorFieldsIsProviderDown() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSecretsFile(
            at: dir,
            json: #"{"version":1,"items":{"hollow":{}}}"#
        )
        let provider = FileSecretsProvider(configDirectory: dir)
        await #expect(throws: SecretsError.providerDown("file")) {
            try await provider.resolve(makeRef("file", "hollow"))
        }
    }

    @Test func controlByteFieldNameIsProviderDown() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSecretsFile(
            at: dir,
            json: "{\"version\":1,\"items\":{\"deploy\":{\"fields\":{\"bad\\nfield\":\"x\"}}}}"
        )
        let provider = FileSecretsProvider(configDirectory: dir)
        await #expect(throws: SecretsError.providerDown("file")) {
            try await provider.resolve(makeRef("file", "deploy"))
        }
    }

    @Test func tooManyItemsIsProviderDown() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        let items = (0...FileSecretsProvider.maximumItems).map {
            #""item-\#($0)":{"text":"v"}"#
        }.joined(separator: ",")
        try writeSecretsFile(at: dir, json: #"{"version":1,"items":{\#(items)}}"#)
        let provider = FileSecretsProvider(configDirectory: dir)
        await #expect(throws: SecretsError.providerDown("file")) {
            try await provider.resolve(makeRef("file", "item-0"))
        }
    }

    @Test func symlinkedValuesFileIsProviderDown() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-filelink")
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("real.json")
        try #"{"version":1,"items":{"a":{"text":"b"}}}"#.write(
            to: target, atomically: true, encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent(FileSecretsProvider.fileName),
            withDestinationURL: target
        )
        let provider = FileSecretsProvider(configDirectory: dir)
        await #expect(throws: SecretsError.providerDown("file")) {
            try await provider.resolve(makeRef("file", "a"))
        }
        #expect(await provider.health() == ProviderHealth(ok: false))
    }

    @Test func unknownRecordKeyIsProviderDown() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Record-level smuggling fails closed like the top-level case.
        try writeSecretsFile(
            at: dir,
            json: #"{"version":1,"items":{"deploy":{"text":"v","smuggled":"hunter2"}}}"#
        )
        let provider = FileSecretsProvider(configDirectory: dir)
        await #expect(throws: SecretsError.providerDown("file")) {
            try await provider.resolve(makeRef("file", "deploy"))
        }
        #expect(await provider.health() == ProviderHealth(ok: false))
    }

    @Test func newlineItemNameIsProviderDown() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSecretsFile(
            at: dir,
            json: "{\"version\":1,\"items\":{\"bad\\nname\":{\"text\":\"v\"}}}"
        )
        let provider = FileSecretsProvider(configDirectory: dir)
        await #expect(throws: SecretsError.providerDown("file")) {
            try await provider.resolve(makeRef("file", "anything"))
        }
    }

    @Test func overlongItemNameIsProviderDown() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = String(repeating: "n", count: 257)
        try writeSecretsFile(
            at: dir,
            json: #"{"version":1,"items":{"\#(name)":{"text":"v"}}}"#
        )
        let provider = FileSecretsProvider(configDirectory: dir)
        await #expect(throws: SecretsError.providerDown("file")) {
            try await provider.resolve(makeRef("file", "anything"))
        }
    }

    @Test func unreadableValuesFileIsProviderDown() async throws {
        // Owner-unreadable denies only for non-root owners; root reads anything.
        guard NSUserName() != "root" else { return }
        let dir = try makeTempDir(prefix: "rv-broker-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSecretsFile(
            at: dir,
            json: #"{"version":1,"items":{"a":{"text":"b"}}}"#,
            mode: 0o000
        )
        let provider = FileSecretsProvider(configDirectory: dir)
        await #expect(throws: SecretsError.providerDown("file")) {
            try await provider.resolve(makeRef("file", "a"))
        }
        #expect(await provider.health() == ProviderHealth(ok: false))
    }
}

// MARK: - Keychain provider

@Suite("KeychainSecretsProvider")
struct KeychainSecretsProviderTests {
    #if os(macOS)
    @Test func resolvesThroughReader() async throws {
        final class Calls: Sendable {
            let mutex = Mutex<[(String, String)]>([])
        }
        let calls = Calls()
        let provider = KeychainSecretsProvider(read: { service, account in
            calls.mutex.withLock { $0.append((service, account)) }
            return Data("kc-secret".utf8)
        })
        let value = try await provider.resolve(makeRef("keychain", "api"))
        #expect(value == .text("kc-secret"))
        let seen = calls.mutex.withLock { $0 }
        #expect(seen.count == 1)
        #expect(seen.first?.0 == "api")
        #expect(seen.first?.1 == KeychainSecretsProvider.defaultAccount)
        #expect(await provider.health() == ProviderHealth(ok: true))
    }

    @Test func fieldSelectsAccount() async throws {
        final class Calls: Sendable {
            let mutex = Mutex<[(String, String)]>([])
        }
        let calls = Calls()
        let provider = KeychainSecretsProvider(read: { service, account in
            calls.mutex.withLock { $0.append((service, account)) }
            return Data("kc-secret".utf8)
        })
        let value = try await provider.resolve(makeRef("keychain", "api", "build"))
        #expect(value == .text("kc-secret"))
        let seen = calls.mutex.withLock { $0 }
        #expect(seen.first?.0 == "api")
        #expect(seen.first?.1 == "build")
    }

    @Test func nilDataIsNotFound() async throws {
        let provider = KeychainSecretsProvider(read: { _, _ in nil })
        await #expect(throws: SecretsError.notFound("keychain")) {
            try await provider.resolve(makeRef("keychain", "api"))
        }
    }

    @Test func nonUTF8DataIsNotFound() async throws {
        let provider = KeychainSecretsProvider(read: { _, _ in Data([0xFF, 0xFE, 0x00]) })
        await #expect(throws: SecretsError.notFound("keychain")) {
            try await provider.resolve(makeRef("keychain", "api"))
        }
    }

    @Test func deniedReaderFailsClosed() async throws {
        let provider = KeychainSecretsProvider.denied
        await #expect(throws: SecretsError.notFound("keychain")) {
            try await provider.resolve(makeRef("keychain", "api"))
        }
        await #expect(throws: SecretsError.notFound("keychain")) {
            try await provider.resolve(makeRef("keychain", "api", "build"))
        }
    }

    @Test func currentPlatformIsLiveOnMacOS() {
        #expect(KeychainSecretsProvider.currentPlatform() != nil)
    }
    #else
    // Documented platform skip (CON-003): Linux has no keychain. The
    // factory returns nil fail-closed, and a directly constructed
    // instance reports down with unhealthy status. This test pins the
    // gate; the macOS resolve tests above do not run here by design.
    @Test func linuxHasNoKeychain() async throws {
        #expect(KeychainSecretsProvider.currentPlatform() == nil)
        let provider = KeychainSecretsProvider(read: { _, _ in Data("x".utf8) })
        #expect(await provider.health() == ProviderHealth(ok: false))
        await #expect(throws: SecretsError.providerDown("keychain")) {
            try await provider.resolve(makeRef("keychain", "api"))
        }
    }
    #endif
}

// MARK: - Broker

@Suite("SecretBroker")
struct SecretBrokerTests {
    @Test func emptyBatchReturnsEmpty() async throws {
        let capture = AuditCapture()
        let broker = makeBroker(providers: [], capture: capture)
        let values = try await broker.resolve([], ctx: makeContext())
        #expect(values.isEmpty)
        #expect(capture.events.isEmpty)
    }

    @Test func emptyBatchStillGatesPrincipal() async throws {
        let stub = StubProvider("env")
        let capture = AuditCapture()
        let broker = makeBroker(providers: [stub], capture: capture)
        await #expect(throws: SecretsError.identityRequired) {
            try await broker.resolve([], ctx: makeContext(validity: .revoking))
        }
        #expect(stub.healthCalls == 0)
        #expect(stub.resolveCalls.isEmpty)
    }

    @Test(
        "principal gate rejects every invalid state",
        arguments: [AgentInstanceValidity.inactive, .revoking, .unknown]
    )
    func principalGateRejectsInvalidStates(validity: AgentInstanceValidity) async throws {
        let stub = StubProvider("env")
        let capture = AuditCapture()
        let broker = makeBroker(providers: [stub], capture: capture)
        let refs = try [makeRef("env", "a"), makeRef("env", "b")]
        await #expect(throws: SecretsError.identityRequired) {
            try await broker.resolve(refs, ctx: makeContext(validity: validity))
        }
        #expect(stub.healthCalls == 0)
        #expect(stub.resolveCalls.isEmpty)
        let events = capture.events
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.decision == .denied })
        #expect(events.allSatisfy { $0.cause?.redacted == "identityRequired" })
    }

    @Test func unknownProviderIsAtomic() async throws {
        let stub = StubProvider("env")
        let capture = AuditCapture()
        let broker = makeBroker(providers: [stub], capture: capture)
        let refs = try [makeRef("env", "a"), makeRef("vault-http", "b")]
        await #expect(throws: SecretsError.providerDown("vault-http")) {
            try await broker.resolve(refs, ctx: makeContext())
        }
        // Registration precheck runs before any provider is touched.
        #expect(stub.healthCalls == 0)
        #expect(stub.resolveCalls.isEmpty)
        let events = capture.events
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.cause?.redacted == "providerDown:vault-http" })
    }

    @Test func unhealthyProviderDeniesWithoutResolving() async throws {
        let healthy = StubProvider("env")
        let sick = StubProvider("exec") { $0.healthOK = false }
        let capture = AuditCapture()
        let broker = makeBroker(providers: [healthy, sick], capture: capture)
        let refs = try [makeRef("env", "a"), makeRef("exec", "b")]
        await #expect(throws: SecretsError.providerDown("exec")) {
            try await broker.resolve(refs, ctx: makeContext())
        }
        #expect(healthy.healthCalls == 1)
        #expect(sick.healthCalls == 1)
        #expect(healthy.resolveCalls.isEmpty)
        #expect(sick.resolveCalls.isEmpty)
    }

    @Test func healthTimeout() async throws {
        let stub = StubProvider("env") { $0.healthDelay = .seconds(5) }
        let capture = AuditCapture()
        let broker = makeBroker(providers: [stub], capture: capture, timeoutSeconds: 0.05)
        await #expect(throws: SecretsError.timeout("env")) {
            try await broker.resolve([makeRef("env", "a")], ctx: makeContext())
        }
        #expect(stub.resolveCalls.isEmpty)
        #expect(capture.events.first?.cause?.redacted == "timeout:env")
    }

    @Test func resolveTimeout() async throws {
        let stub = StubProvider("env") { $0.resolveDelay = .seconds(5) }
        let capture = AuditCapture()
        let broker = makeBroker(providers: [stub], capture: capture, timeoutSeconds: 0.05)
        await #expect(throws: SecretsError.timeout("env")) {
            try await broker.resolve([makeRef("env", "a")], ctx: makeContext())
        }
        #expect(capture.events.first?.cause?.redacted == "timeout:env")
    }

    @Test func atomicBatchDiscardsPartialValues() async throws {
        let good = try makeRef("env", "good")
        let stub = StubProvider("env") {
            $0.values = [good: .text("good-value")]
            $0.defaultValue = nil
        }
        let capture = AuditCapture()
        let broker = makeBroker(providers: [stub], capture: capture)
        let refs = [good, try makeRef("env", "missing")]
        await #expect(throws: SecretsError.notFound("env")) {
            try await broker.resolve(refs, ctx: makeContext())
        }
        let events = capture.events
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.decision == .denied })
    }

    @Test func foreignErrorsMapToProviderDown() async throws {
        let stub = StubProvider("env") { $0.foreignError = true }
        let capture = AuditCapture()
        let broker = makeBroker(providers: [stub], capture: capture)
        await #expect(throws: SecretsError.providerDown("env")) {
            try await broker.resolve([makeRef("env", "a")], ctx: makeContext())
        }
        #expect(capture.events.first?.cause?.redacted == "providerDown:env")
    }

    @Test func leaseExpiredPassesThrough() async throws {
        let stub = StubProvider("env") { $0.resolveError = .leaseExpired("env") }
        let capture = AuditCapture()
        let broker = makeBroker(providers: [stub], capture: capture)
        await #expect(throws: SecretsError.leaseExpired("env")) {
            try await broker.resolve([makeRef("env", "a")], ctx: makeContext())
        }
        #expect(capture.events.first?.cause?.redacted == "leaseExpired:env")
    }

    @Test func staleContextAtCommitDiscardsValues() async throws {
        let stub = StubProvider("env")
        let capture = AuditCapture()
        let broker = makeBroker(
            providers: [stub], capture: capture, liveness: staleAtCommitLiveness()
        )
        await #expect(throws: SecretsError.identityRequired) {
            try await broker.resolve([makeRef("env", "a")], ctx: makeContext())
        }
        // The provider was touched, but the stale commit returned nothing.
        #expect(stub.resolveCalls.count == 1)
        let events = capture.events
        #expect(events.count == 1)
        #expect(events.first?.decision == .denied)
        #expect(events.first?.cause?.redacted == "identityRequired")
    }

    @Test func nonpositiveTimeoutDeniesImmediately() async throws {
        let stub = StubProvider("env")
        let capture = AuditCapture()
        let broker = makeBroker(providers: [stub], capture: capture, timeoutSeconds: 0)
        await #expect(throws: SecretsError.timeout("env")) {
            try await broker.resolve([makeRef("env", "a")], ctx: makeContext())
        }
        #expect(stub.healthCalls == 0)
        #expect(stub.resolveCalls.isEmpty)
    }

    @Test func slowProviderTimeoutIsAtomic() async throws {
        let fast = StubProvider("env")
        let slow = StubProvider("exec") { $0.resolveDelay = .seconds(5) }
        let capture = AuditCapture()
        let broker = makeBroker(providers: [fast, slow], capture: capture, timeoutSeconds: 0.05)
        let refs = try [makeRef("env", "a"), makeRef("exec", "b")]
        await #expect(throws: SecretsError.timeout("exec")) {
            try await broker.resolve(refs, ctx: makeContext())
        }
        #expect(capture.events.count == 2)
        #expect(capture.events.allSatisfy { $0.cause?.redacted == "timeout:exec" })
    }

    @Test func duplicateRefsResolveOnce() async throws {
        let stub = StubProvider("env")
        let capture = AuditCapture()
        let broker = makeBroker(providers: [stub], capture: capture)
        let ref = try makeRef("env", "a")
        let values = try await broker.resolve([ref, ref], ctx: makeContext())
        #expect(values.count == 1)
        #expect(values[ref] == .text("stub-default-value"))
        #expect(stub.resolveCalls == [ref])
        #expect(capture.events.count == 1)
    }

    @Test func multiProviderBatch() async throws {
        let env = StubProvider("env")
        let exec = StubProvider("exec")
        let capture = AuditCapture()
        let broker = makeBroker(providers: [env, exec], capture: capture)
        let envRef = try makeRef("env", "a")
        let execRef = try makeRef("exec", "b", "field")
        let values = try await broker.resolve([envRef, execRef], ctx: makeContext())
        #expect(values.count == 2)
        #expect(values[envRef] == .text("stub-default-value"))
        #expect(values[execRef] == .text("stub-default-value"))
        #expect(capture.events.allSatisfy { $0.decision == .resolved })
    }

    @Test func providerIDsAreSorted() async {
        let capture = AuditCapture()
        let broker = makeBroker(
            providers: [StubProvider("exec"), StubProvider("env")], capture: capture
        )
        #expect(await broker.providerIDs == ["env", "exec"])
    }

    @Test func laterRegistrationWins() async throws {
        let first = StubProvider("env") { $0.defaultValue = .text("first") }
        let second = StubProvider("env") { $0.defaultValue = .text("second") }
        let capture = AuditCapture()
        let broker = makeBroker(providers: [first, second], capture: capture)
        let values = try await broker.resolve([makeRef("env", "a")], ctx: makeContext())
        #expect(values.values.first == .text("second"))
        #expect(first.resolveCalls.isEmpty)
        #expect(second.resolveCalls.count == 1)
    }

    @Test func registryLivenessAdmitsLiveContext() async throws {
        let harness = try BrokerRegistryHarness()
        defer { harness.cleanup() }
        let stub = StubProvider("env")
        let capture = AuditCapture()
        let broker = makeBroker(
            providers: [stub],
            capture: capture,
            liveness: SecretBrokerLiveness.registry(harness.registry)
        )
        let ctx = try #require(harness.registry.context(for: harness.instance.id))
        let ref = try makeRef("env", "a")
        let values = try await broker.resolve([ref], ctx: ctx)
        #expect(values[ref] == .text("stub-default-value"))
        #expect(capture.events.first?.decision == .resolved)
    }

    @Test func registryRevocationBeforeEntryDeniesWithoutTouching() async throws {
        let harness = try BrokerRegistryHarness()
        defer { harness.cleanup() }
        #expect(
            harness.registry.revoke(harness.instance.id, reason: .explicitRevoke) { true } == .revoked
        )
        let stub = StubProvider("env")
        let capture = AuditCapture()
        let broker = makeBroker(
            providers: [stub],
            capture: capture,
            liveness: SecretBrokerLiveness.registry(harness.registry)
        )
        // Stale snapshot: still claims active, but the registry is dead.
        let stale = AuthenticatedAgentContext(instance: harness.instance, validity: .active)
        await #expect(throws: SecretsError.identityRequired) {
            try await broker.resolve([makeRef("env", "a")], ctx: stale)
        }
        #expect(stub.healthCalls == 0)
        #expect(stub.resolveCalls.isEmpty)
    }

    @Test func registryRevocationMidFlightDenies() async throws {
        let harness = try BrokerRegistryHarness()
        defer { harness.cleanup() }
        let gate = ResolveGate()
        let gated = GatedProvider(id: "env", gate: gate, value: .text("late-value"))
        let capture = AuditCapture()
        let broker = makeBroker(
            providers: [gated],
            capture: capture,
            liveness: SecretBrokerLiveness.registry(harness.registry)
        )
        let ctx = try #require(harness.registry.context(for: harness.instance.id))
        let ref = try makeRef("env", "a")
        let task = Task { try await broker.resolve([ref], ctx: ctx) }
        await gate.waitForEntry()
        #expect(
            harness.registry.revoke(harness.instance.id, reason: .explicitRevoke) { true } == .revoked
        )
        gate.open()
        await #expect(throws: SecretsError.identityRequired) {
            try await task.value
        }
        let events = capture.events
        #expect(events.count == 1)
        #expect(events.first?.cause?.redacted == "identityRequired")
    }

    @Test func successAuditRows() async throws {
        let stub = StubProvider("env")
        let capture = AuditCapture()
        let fixed = Date(timeIntervalSince1970: 1_800_000_000)
        let broker = SecretBroker(
            providers: [stub, StubProvider("exec")],
            audit: capture.sink,
            liveness: .usableOnly,
            timeoutSeconds: 5,
            now: { fixed }
        )
        let ctx = makeContext()
        let envRef = try makeRef("env", "a")
        let execRef = try makeRef("exec", "b", "field")
        _ = try await broker.resolve([envRef, execRef], ctx: ctx)
        let events = capture.events
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.decision == .resolved })
        #expect(events.allSatisfy { $0.cause == nil })
        #expect(events.allSatisfy { $0.kind == .secretResolve })
        #expect(events.allSatisfy { $0.timestamp == fixed })
        let executions = Set(events.map(\.executionID))
        #expect(executions.count == 1)
        let correlations = Set(events.map(\.correlationID))
        #expect(correlations.count == 1)
        #expect(events.allSatisfy { $0.principal.instanceID == ctx.instance.id })
        #expect(events.allSatisfy { $0.principal.definitionID == "test-agent" })
        #expect(events.allSatisfy { $0.principal.ownerUID == 501 })
        let targets = events.map(\.addressOrRef)
        #expect(targets.contains(SecretsAuditAddressOrRef(envRef)))
        #expect(targets.contains(SecretsAuditAddressOrRef(execRef)))
    }

    @Test func failureAuditRowsCarryProviderCause() async throws {
        let stub = StubProvider("env") { $0.defaultValue = nil }
        let capture = AuditCapture()
        let broker = makeBroker(providers: [stub], capture: capture)
        let refs = try [makeRef("env", "a"), makeRef("env", "b")]
        await #expect(throws: SecretsError.notFound("env")) {
            try await broker.resolve(refs, ctx: makeContext())
        }
        let events = capture.events
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.decision == .denied })
        #expect(events.allSatisfy { $0.cause?.redacted == "notFound:env" })
    }

    @Test func auditFailureOnCommitDenies() async throws {
        struct AuditBoom: Error {}
        let stub = StubProvider("env")
        let broker = SecretBroker(
            providers: [stub],
            audit: SecretBrokerAuditSink(append: { _ in throw AuditBoom() }),
            liveness: .usableOnly
        )
        await #expect(throws: SecretsError.denied("audit")) {
            try await broker.resolve([makeRef("env", "a")], ctx: makeContext())
        }
    }

    @Test func auditFailureKeepsOriginalError() async throws {
        struct AuditBoom: Error {}
        let stub = StubProvider("env")
        let broker = SecretBroker(
            providers: [stub],
            audit: SecretBrokerAuditSink(append: { _ in throw AuditBoom() }),
            liveness: .usableOnly
        )
        await #expect(throws: SecretsError.providerDown("vault-http")) {
            try await broker.resolve([makeRef("vault-http", "a")], ctx: makeContext())
        }
    }

    @Test func parallelResolves() async throws {
        let stub = StubProvider("env")
        let capture = AuditCapture()
        let broker = makeBroker(providers: [stub], capture: capture)
        let ctx = makeContext()
        let ref = try makeRef("env", "item")
        try await withThrowingTaskGroup(of: [SecretRef: SecretValue].self) { group in
            for _ in 0..<10 {
                group.addTask { try await broker.resolve([ref], ctx: ctx) }
            }
            var count = 0
            for try await values in group {
                #expect(values[ref] == .text("stub-default-value"))
                count += 1
            }
            #expect(count == 10)
        }
        let executions = Set(capture.events.map(\.executionID))
        #expect(executions.count == 10)
    }

    @Test func stressFiftyRefBatch() async throws {
        var values: [SecretRef: SecretValue] = [:]
        var refs: [SecretRef] = []
        for index in 0..<50 {
            let ref = try makeRef("env", "item-\(index)")
            refs.append(ref)
            values[ref] = .text("value-\(index)")
        }
        let stub = StubProvider("env") {
            $0.values = values
            $0.defaultValue = nil
        }
        let capture = AuditCapture()
        let broker = makeBroker(providers: [stub], capture: capture)
        let resolved = try await broker.resolve(refs, ctx: makeContext())
        #expect(resolved.count == 50)
        #expect(resolved[refs[7]] == .text("value-7"))
        #expect(capture.events.count == 50)
    }

    @Test func noEchoAcrossErrorsAndAudit() async throws {
        let marker = "B7R0K3R-S3CR3T-M4RK3R"
        let dir = try makeTempDir(prefix: "rv-broker-noecho")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSecretsFile(
            at: dir,
            json: #"{"version":1,"items":{"normal-item":{"text":"\#(marker)"}}}"#
        )
        let file = FileSecretsProvider(configDirectory: dir)
        let broker = SecretBroker(providers: [file], auditDirectory: dir, liveness: .usableOnly)
        let ctx = makeContext()
        let ref = try makeRef("file", "normal-item")
        let values = try await broker.resolve([ref], ctx: ctx)
        #expect(values[ref] == .text(marker))
        var errorStrings: [String] = []
        do {
            // Plain missing label: the marker lives only in the stored value,
            // never in a label, so any marker echo is a real leak.
            _ = try await broker.resolve([makeRef("file", "missing-item")], ctx: ctx)
        } catch {
            errorStrings.append(String(describing: error))
        }
        do {
            _ = try await broker.resolve([makeRef("vault-http", "x")], ctx: ctx)
        } catch {
            errorStrings.append(String(describing: error))
        }
        do {
            _ = try await broker.resolve([ref], ctx: makeContext(validity: .unknown))
        } catch {
            errorStrings.append(String(describing: error))
        }
        let auditText = try readAuditText(at: dir)
        #expect(errorStrings.joined().contains(marker) == false)
        #expect(errorStrings.joined().contains("normal-item") == false)
        #expect(auditText.contains(marker) == false)
        // Labels stay by design: the ledger records what was touched.
        #expect(auditText.contains("normal-item"))
        #expect(errorStrings.joined().contains("file"))
    }

    @Test func fileAuditKeysMatchLedgerTaxonomy() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-auditkeys")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubProvider("env")
        let broker = SecretBroker(providers: [stub], auditDirectory: dir, liveness: .usableOnly)
        let whole = try makeRef("env", "a")
        let fielded = try makeRef("env", "b", "field")
        _ = try await broker.resolve([whole, fielded], ctx: makeContext())
        let text = try readAuditText(at: dir)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        for line in lines {
            let row = try #require(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            )
            #expect(row["executionId"] is String)
            #expect(row["timestamp"] is String)
            #expect(row["kind"] as? String == "secret.resolve")
            #expect(row["decision"] as? String == "resolved")
            #expect(row["correlationId"] is String)
            #expect(row["cause"] == nil)
            let principal = try #require(row["principal"] as? [String: Any])
            #expect(principal["instanceID"] is String)
            #expect(principal["definitionID"] as? String == "test-agent")
            #expect(principal["ownerUID"] as? Int == 501)
            let target = try #require(row["addressOrRef"] as? [String: Any])
            #expect(target["kind"] as? String == "secret")
            #expect(target["provider"] as? String == "env")
        }
        let first = try #require(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        )
        let firstTarget = try #require(first["addressOrRef"] as? [String: Any])
        #expect(firstTarget["item"] as? String == "a")
        #expect(firstTarget["field"] == nil)
        let second = try #require(
            JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any]
        )
        let secondTarget = try #require(second["addressOrRef"] as? [String: Any])
        #expect(secondTarget["item"] as? String == "b")
        #expect(secondTarget["field"] as? String == "field")
    }

    @Test func fileAuditPermissionsAreOwnerOnly() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-auditperms")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubProvider("env")
        let broker = SecretBroker(providers: [stub], auditDirectory: dir, liveness: .usableOnly)
        _ = try await broker.resolve([makeRef("env", "a")], ctx: makeContext())
        #expect(
            try posixPermissions(of: dir.appendingPathComponent(SecretsAuditPaths.fileName))
                == 0o600
        )
        #expect(try posixPermissions(of: dir) == 0o700)
    }

    @Test func emptyBatchSkipsFileAudit() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-emptyaudit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let broker = SecretBroker(
            providers: [StubProvider("env")], auditDirectory: dir, liveness: .usableOnly
        )
        let values = try await broker.resolve([], ctx: makeContext())
        #expect(values.isEmpty)
        #expect(
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(SecretsAuditPaths.fileName).path
            ) == false
        )
    }

    @Test func auditDirectoryIsFileDenies() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-auditfile")
        defer { try? FileManager.default.removeItem(at: dir) }
        let blocker = dir.appendingPathComponent("blocker")
        try "not a directory".write(to: blocker, atomically: true, encoding: .utf8)
        let broker = SecretBroker(
            providers: [StubProvider("env")], auditDirectory: blocker, liveness: .usableOnly
        )
        await #expect(throws: SecretsError.denied("audit")) {
            try await broker.resolve([makeRef("env", "a")], ctx: makeContext())
        }
    }

    @Test func symlinkedAuditDirectoryDenies() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-auditlink")
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let broker = SecretBroker(
            providers: [StubProvider("env")], auditDirectory: link, liveness: .usableOnly
        )
        await #expect(throws: SecretsError.denied("audit")) {
            try await broker.resolve([makeRef("env", "a")], ctx: makeContext())
        }
    }

    @Test func cancellationDuringResolvePropagates() async throws {
        let stub = StubProvider("env") { $0.resolveDelay = .seconds(5) }
        let capture = AuditCapture()
        let broker = makeBroker(providers: [stub], capture: capture)
        let ref = try makeRef("env", "a")
        let task = Task { try await broker.resolve([ref], ctx: makeContext()) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected CancellationError")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(capture.events.isEmpty)
    }

    @Test func causeSpellingMirrorsLedger() {
        // Post-collapse the broker emits SecretsAuditCause directly: the
        // ledger spelling below is the single source pinned per case.
        let cases: [(SecretsError, String)] = [
            (.invalidRef("env"), "invalidRef:env"),
            (.notFound("env"), "notFound:env"),
            (.denied("audit"), "denied:audit"),
            (.identityRequired, "identityRequired"),
            (.leaseExpired("env"), "leaseExpired:env"),
            (.providerDown("env"), "providerDown:env"),
            (.oversized("env"), "oversized:env"),
            (.policyDenied, "policyDenied"),
            (.timeout("env"), "timeout:env"),
        ]
        for (error, literal) in cases {
            #expect(SecretsAuditCause(error).redacted == literal)
        }
    }

    @Test func fileAuditLinesDecodeAsCanonicalRecords() async throws {
        // Cross-compat proof: broker file rows decode as the shared
        // ledger record with identical labels and causes.
        let dir = try makeTempDir(prefix: "rv-broker-canonical")
        defer { try? FileManager.default.removeItem(at: dir) }
        let broker = SecretBroker(
            providers: [StubProvider("env")], auditDirectory: dir, liveness: .usableOnly
        )
        _ = try await broker.resolve([makeRef("env", "a")], ctx: makeContext())
        let failing = SecretBroker(
            providers: [StubProvider("env") { $0.resolveError = .notFound("env") }],
            auditDirectory: dir,
            liveness: .usableOnly
        )
        await #expect(throws: SecretsError.notFound("env")) {
            try await failing.resolve([makeRef("env", "b", "field")], ctx: makeContext())
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lines = try readAuditText(at: dir).split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        let resolved = try decoder.decode(SecretsAuditRecord.self, from: Data(lines[0].utf8))
        #expect(resolved.kind == .secretResolve)
        #expect(resolved.decision == .resolved)
        #expect(resolved.addressOrRef == .secret(provider: "env", item: "a", field: nil))
        #expect(resolved.cause == nil)
        let denied = try decoder.decode(SecretsAuditRecord.self, from: Data(lines[1].utf8))
        #expect(denied.kind == .secretResolve)
        #expect(denied.decision == .denied)
        #expect(denied.addressOrRef == .secret(provider: "env", item: "b", field: "field"))
        #expect(denied.cause?.redacted == "notFound:env")
    }

    @Test func multiProviderResolveFailureIsAtomic() async throws {
        let env = StubProvider("env")
        let exec = StubProvider("exec") { $0.resolveError = .notFound("exec") }
        let capture = AuditCapture()
        let broker = makeBroker(providers: [env, exec], capture: capture)
        let refs = try [makeRef("env", "a"), makeRef("exec", "b")]
        await #expect(throws: SecretsError.notFound("exec")) {
            try await broker.resolve(refs, ctx: makeContext())
        }
        // env resolved into the scratch map, then exec failed: nothing commits.
        #expect(env.resolveCalls.count == 1)
        #expect(exec.resolveCalls.count == 1)
        let events = capture.events
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.decision == .denied })
        #expect(events.allSatisfy { $0.cause?.redacted == "notFound:exec" })
    }

    @Test func bothUnhealthyNamesFirstSortedProvider() async throws {
        let env = StubProvider("env") { $0.healthOK = false }
        let exec = StubProvider("exec") { $0.healthOK = false }
        let capture = AuditCapture()
        let broker = makeBroker(providers: [exec, env], capture: capture)
        await #expect(throws: SecretsError.providerDown("env")) {
            try await broker.resolve(
                [makeRef("exec", "b"), makeRef("env", "a")], ctx: makeContext()
            )
        }
        // Sorted health order short-circuits on env; exec is never gated.
        #expect(env.healthCalls == 1)
        #expect(exec.healthCalls == 0)
        #expect(capture.events.first?.cause?.redacted == "providerDown:env")
    }

    @Test func filePathValuePassesThroughWithLabelOnlyAudit() async throws {
        let ref = try makeRef("env", "key")
        let staged = SecretValue.filePath("/tmp/staged/key-1")
        let stub = StubProvider("env") {
            $0.values = [ref: staged]
            $0.defaultValue = nil
        }
        let capture = AuditCapture()
        let broker = makeBroker(providers: [stub], capture: capture)
        let values = try await broker.resolve([ref], ctx: makeContext())
        #expect(values[ref] == staged)
        let events = capture.events
        #expect(events.count == 1)
        #expect(events.first?.decision == .resolved)
        #expect(events.first?.addressOrRef == .secret(provider: "env", item: "key", field: nil))
    }

    @Test func providerThrownErrorsAreRetaggedToThrowingProvider() async throws {
        let cases: [(thrown: SecretsError, expected: SecretsError)] = [
            (.oversized("vault-http"), .oversized("env")),
            (.denied("audit"), .denied("env")),
            (.invalidRef("exec"), .invalidRef("env")),
            (.notFound("keychain"), .notFound("env")),
            (.providerDown("file"), .providerDown("env")),
            (.leaseExpired("exec"), .leaseExpired("env")),
            (.timeout("vault-http"), .timeout("env")),
        ]
        for (thrown, expected) in cases {
            let stub = StubProvider("env") { $0.resolveError = thrown }
            let capture = AuditCapture()
            let broker = makeBroker(providers: [stub], capture: capture)
            do {
                _ = try await broker.resolve([makeRef("env", "a")], ctx: makeContext())
                Issue.record("expected \(expected) for \(thrown)")
            } catch let error as SecretsError {
                #expect(error == expected)
            }
            #expect(capture.events.first?.cause?.redacted == SecretsAuditCause(expected).redacted)
        }
    }

    @Test func providerErrorsWithoutProviderPassThrough() async throws {
        for thrown: SecretsError in [.policyDenied, .identityRequired] {
            let stub = StubProvider("env") { $0.resolveError = thrown }
            let capture = AuditCapture()
            let broker = makeBroker(providers: [stub], capture: capture)
            do {
                _ = try await broker.resolve([makeRef("env", "a")], ctx: makeContext())
                Issue.record("expected \(thrown)")
            } catch let error as SecretsError {
                #expect(error == thrown)
            }
        }
    }

    @Test func generationMismatchDeniesWhileActive() async throws {
        // Isolates the TOCTOU generation predicate: validity stays active,
        // only the token is stale.
        let harness = try BrokerRegistryHarness()
        defer { harness.cleanup() }
        let liveness = SecretBrokerLiveness.registry(harness.registry)
        let ctx = try #require(harness.registry.context(for: harness.instance.id))
        let token = liveness.snapshot(ctx)
        #expect(token != nil)
        #expect(liveness.isLive(ctx, token))
        #expect(harness.registry.validity(of: harness.instance.id) == .active)
        #expect(liveness.isLive(ctx, 999) == false)
        #expect(liveness.isLive(ctx, nil) == false)
    }

    @Test func usableOnlyIgnoresRegistryRevocation() async throws {
        // Documents the usableOnly trap: cached validity is trusted without
        // consulting the registry, so production wiring must pass
        // SecretBrokerLiveness.registry explicitly.
        let harness = try BrokerRegistryHarness()
        defer { harness.cleanup() }
        #expect(
            harness.registry.revoke(harness.instance.id, reason: .explicitRevoke) { true } == .revoked
        )
        let stub = StubProvider("env")
        let capture = AuditCapture()
        let broker = makeBroker(providers: [stub], capture: capture, liveness: .usableOnly)
        let stale = AuthenticatedAgentContext(instance: harness.instance, validity: .active)
        let ref = try makeRef("env", "a")
        let values = try await broker.resolve([ref], ctx: stale)
        #expect(values[ref] == .text("stub-default-value"))
        #expect(capture.events.first?.decision == .resolved)
    }

    @Test func cancellationDuringHealthPropagates() async throws {
        // The stub swallows cancellation in health (try?); the broker's own
        // check still converts the raced outcome to CancellationError.
        let stub = StubProvider("env") { $0.healthDelay = .seconds(5) }
        let capture = AuditCapture()
        let broker = makeBroker(providers: [stub], capture: capture)
        let ref = try makeRef("env", "a")
        let task = Task { try await broker.resolve([ref], ctx: makeContext()) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected CancellationError")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(capture.events.isEmpty)
        #expect(stub.resolveCalls.isEmpty)
    }

    @Test func cancellationDuringHealthWinsOverRacedSuccess() async throws {
        // Deterministic control for the broker's cancellation-wins check:
        // health swallows cancellation and succeeds only after the gate
        // opens, so the worker deterministically beats the 5s sleeper. With
        // the check removed the cancelled call would commit resolved rows.
        let gate = ResolveGate()
        let stub = GatedHealthProvider(id: "env", gate: gate, value: .text("v"))
        let capture = AuditCapture()
        let broker = makeBroker(providers: [stub], capture: capture)
        let ref = try makeRef("env", "a")
        let task = Task { try await broker.resolve([ref], ctx: makeContext()) }
        await gate.waitForEntry()
        task.cancel()
        gate.open()
        do {
            _ = try await task.value
            Issue.record("expected CancellationError")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(capture.events.isEmpty)
    }

    @Test func spoofedCancellationErrorDeniesAsProviderDown() async throws {
        // A provider that throws CancellationError without cancellation is
        // faulty or hostile: the batch must deny (and audit), not escape
        // the ledger with zero rows.
        #expect(Task.isCancelled == false)
        let stub = CancellingProvider(id: "env")
        let capture = AuditCapture()
        let broker = makeBroker(providers: [stub], capture: capture)
        await #expect(throws: SecretsError.providerDown("env")) {
            try await broker.resolve([makeRef("env", "a")], ctx: makeContext())
        }
        let events = capture.events
        #expect(events.count == 1)
        #expect(events.allSatisfy { $0.decision == .denied })
        #expect(events.first?.cause?.redacted == "providerDown:env")
    }

    @Test func cancellationDuringAuditAppendPropagates() async throws {
        let stub = StubProvider("env")
        let broker = SecretBroker(
            providers: [stub],
            audit: SecretBrokerAuditSink(append: { _ in throw CancellationError() }),
            liveness: .usableOnly
        )
        do {
            _ = try await broker.resolve([makeRef("env", "a")], ctx: makeContext())
            Issue.record("expected CancellationError")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func symlinkedLedgerFileDenies() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-ledgerlink")
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("real-ledger.jsonl")
        try "".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent(SecretsAuditPaths.fileName),
            withDestinationURL: target
        )
        let broker = SecretBroker(
            providers: [StubProvider("env")], auditDirectory: dir, liveness: .usableOnly
        )
        await #expect(throws: SecretsError.denied("audit")) {
            try await broker.resolve([makeRef("env", "a")], ctx: makeContext())
        }
        // The link target is never written through.
        #expect(try String(contentsOf: target, encoding: .utf8) == "")
    }

    @Test func laxAuditDirectoryIsTightened() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-audittighten")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: dir.path
        )
        let broker = SecretBroker(
            providers: [StubProvider("env")], auditDirectory: dir, liveness: .usableOnly
        )
        _ = try await broker.resolve([makeRef("env", "a")], ctx: makeContext())
        #expect(try posixPermissions(of: dir) == 0o700)
    }

    @Test func symlinkedAuditDirectoryLeavesTargetUntouched() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-auditlinkmode")
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: target.path
        )
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let broker = SecretBroker(
            providers: [StubProvider("env")], auditDirectory: link, liveness: .usableOnly
        )
        await #expect(throws: SecretsError.denied("audit")) {
            try await broker.resolve([makeRef("env", "a")], ctx: makeContext())
        }
        // Path-based tightening would have re-owned the target to 0700.
        #expect(try posixPermissions(of: target) == 0o755)
    }

    @Test func ledgerLockFileIsOwnerOnly() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-auditlock")
        defer { try? FileManager.default.removeItem(at: dir) }
        let broker = SecretBroker(
            providers: [StubProvider("env")], auditDirectory: dir, liveness: .usableOnly
        )
        _ = try await broker.resolve([makeRef("env", "a")], ctx: makeContext())
        let lock = dir.appendingPathComponent(SecretsAuditPaths.lockFileName)
        #expect(FileManager.default.fileExists(atPath: lock.path))
        #expect(try posixPermissions(of: lock) == 0o600)
    }

    @Test func usableOnlySnapshotPinsNilArm() {
        #expect(SecretBrokerLiveness.usableOnly.snapshot(makeContext(validity: .inactive)) == nil)
        #expect(SecretBrokerLiveness.usableOnly.snapshot(makeContext()) == 0)
    }

    @Test func fileAuditAppendEmptyIsNoop() throws {
        let dir = try makeTempDir(prefix: "rv-broker-audit-empty")
        defer { try? FileManager.default.removeItem(at: dir) }
        try SecretsLedger.append([], directory: dir, retention: .default)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("secrets-audit.jsonl").path) == false)
    }

    @Test func symlinkedConfigDirectoryIsUnsafe() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-dirlink")
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.deletingLastPathComponent().appendingPathComponent("rv-broker-dirlink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        defer { try? FileManager.default.removeItem(at: link) }
        let provider = FileSecretsProvider(configDirectory: link)
        await #expect(provider.health().ok == false)
    }

    @Test func symlinkedLockFileDeniesAppend() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-locklink")
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("real.lock")
        try Data("x".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent(SecretsAuditPaths.lockFileName),
            withDestinationURL: target
        )
        let capture = AuditCapture()
        let broker = makeBroker(providers: [StubProvider("env")], capture: capture)
        _ = try await broker.resolve([makeRef("env", "a")], ctx: makeContext())
        #expect(throws: SecretsLedgerError.lockFailed) {
            try SecretsLedger.append(capture.events, directory: dir, retention: .default)
        }
    }

    @Test func fifoLockFileTripsTypeGuard() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-lockfifo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = dir.appendingPathComponent(SecretsAuditPaths.lockFileName)
        #expect(Darwin.mkfifo(lock.path, 0o600) == 0)
        let capture = AuditCapture()
        let broker = makeBroker(providers: [StubProvider("env")], capture: capture)
        _ = try await broker.resolve([makeRef("env", "a")], ctx: makeContext())
        #expect(throws: SecretsLedgerError.lockFailed) {
            try SecretsLedger.append(capture.events, directory: dir, retention: .default)
        }
    }

    @Test func fifoLedgerFileTripsTypeGuard() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-ledgerfifo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = dir.appendingPathComponent("secrets-audit.jsonl")
        #expect(Darwin.mkfifo(ledger.path, 0o600) == 0)
        // Held reader so the O_WRONLY open succeeds instead of blocking;
        // the fstat type guard below it is what must deny.
        let reader = Darwin.open(ledger.path, O_RDONLY | O_NONBLOCK)
        try #require(reader >= 0)
        defer { Darwin.close(reader) }
        let capture = AuditCapture()
        let broker = makeBroker(providers: [StubProvider("env")], capture: capture)
        _ = try await broker.resolve([makeRef("env", "a")], ctx: makeContext())
        #expect(throws: SecretsLedgerError.ioFailed) {
            try SecretsLedger.append(capture.events, directory: dir, retention: .default)
        }
    }

    @Test func ledgerFullDeniesDirectly() async throws {
        let dir = try makeTempDir(prefix: "rv-broker-ledgerfull")
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = AuditCapture()
        let broker = makeBroker(providers: [StubProvider("env")], capture: capture)
        _ = try await broker.resolve([makeRef("env", "a")], ctx: makeContext())
        let tiny = SecretsAuditRetention(maxRows: 100, maxAge: 1_000_000, maxBytes: 64, maxGenerations: 0)
        let sink = SecretBrokerAuditSink.file(directory: dir, retention: tiny)
        await #expect(throws: SecretsLedgerError.ledgerFull) {
            try await sink.append(capture.events)
        }
    }

    @Test func strictKeysRejectIntegerCodingKeys() {
        #expect(FileSecretsStrictKey(intValue: 5) == nil)
    }
}
