#if os(macOS)
import Foundation
import RVDomain
import RVFileStore
import Synchronization
import Testing
@testable import RVIsolation

// MARK: - Helpers

/// Scripted provider: records every call so tests prove what supervisor
/// preparation did and did not touch.
private struct E1CStubScript: Sendable {
    var healthOK = true
    var resolveError: SecretsError?
    var values: [SecretRef: SecretValue] = [:]
    var healthCalls = 0
    var resolveCalls: [SecretRef] = []
}

private final class E1CStubState: Sendable {
    let mutex = Mutex(E1CStubScript())
}

private struct E1CStubProvider: SecretsProvider, Sendable {
    var id: String
    var state: E1CStubState

    init(_ id: String, configure: (inout E1CStubScript) -> Void = { _ in }) {
        self.id = id
        let state = E1CStubState()
        state.mutex.withLock { configure(&$0) }
        self.state = state
    }

    func health() async -> ProviderHealth {
        state.mutex.withLock {
            $0.healthCalls += 1
            return ProviderHealth(ok: $0.healthOK)
        }
    }

    func resolve(_ ref: SecretRef) async throws -> SecretValue {
        let script = state.mutex.withLock { script -> E1CStubScript in
            script.resolveCalls.append(ref)
            return script
        }
        if let error = script.resolveError {
            throw error
        }
        if let value = script.values[ref] {
            return value
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

private struct E1COpened {
    var supervisor: WorkspaceSessionSupervisor
    var runtimeLog: URL
}

private func e1cOpenWorkspace(_ tree: ContainmentTree) throws -> E1COpened {
    let runtimeLog = tree.rootURL.appendingPathComponent("runtime-\(UUID().uuidString).jsonl")
    let lifeLog = tree.rootURL.appendingPathComponent("workspace-\(UUID().uuidString).jsonl")
    let journal = tree.rootURL.appendingPathComponent("instances-\(UUID().uuidString).jsonl")
    let directory = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
    let supervisor = try WorkspaceSessionSupervisor.open(
        directory,
        lifecycleLog: .file(lifeLog),
        instanceJournal: .file(journal)
    ).get()
    return E1COpened(supervisor: supervisor, runtimeLog: runtimeLog)
}

private func e1cLaunch(
    _ supervisor: WorkspaceSessionSupervisor,
    log: URL,
    script: String,
    profile: RuntimeResourceProfile? = nil,
    stagingAgent: DefinitionStagingTag? = nil,
    context: AuthenticatedAgentContext? = nil,
    providers: [any SecretsProvider]? = nil,
    configDirectory: URL? = nil
) throws -> Result<RunningRuntime, WorkspaceSessionError> {
    try supervisor.launch(
        host: .opencode,
        stagingAgent: stagingAgent,
        command: #require(IsolatedCommand(executable: "/bin/sh", arguments: ["-c", script])),
        plan: compileContainedPlan(workspace: supervisor.snapshot.policyWorkspace),
        io: .discard,
        resourceProfile: profile,
        admission: .failClosed,
        sessionStore: .file(log),
        brokerCallerContext: context,
        brokerProviders: providers,
        secretsConfigDirectory: configDirectory
    )
}

private func e1cDefinition(tag: String = "e1c-agent") -> AgentDefinition {
    AgentDefinition(
        id: AgentDefinitionID(rawValue: "e1c-agent"),
        displayName: "E1-C",
        blurb: "",
        executableRequirement: ExecutableRequirement(allowsUnsigned: true),
        hookHost: .opencode,
        agentTag: tag,
        resourceProfile: RuntimeResourceProfile(id: "e1c", projects: []),
        credentialBindings: [],
        requiredAssurance: .launchObserved,
        authorityCeiling: AgentAuthority(scopes: ["shell"])
    )
}

private func e1cAnnounce(
    _ supervisor: WorkspaceSessionSupervisor,
    definition: AgentDefinition? = nil
) throws -> AgentInstance {
    let definition = definition ?? e1cDefinition()
    let granted = definition.authorityCeiling
    let instance = AgentInstance(
        id: AgentInstanceID(),
        owner: OwnerPrincipal(uid: 501),
        definitionID: definition.id,
        definitionRevision: AgentDefinitionRevision.resolve(definition),
        workspaceSessionID: supervisor.id,
        runtimeSessionID: RuntimeSessionID(),
        executableEvidence: .none,
        assurance: .launchObserved,
        groupLeader: RuntimeChildIdentity(pid: 100),
        workloadProcess: nil,
        parent: nil,
        effectiveAuthority: granted,
        delegableAuthority: granted,
        mintedAt: Date()
    )
    guard supervisor.agentInstances.announce(instance) else {
        throw E1CFixtureError.announceFailed
    }
    return instance
}

/// Fresh usable caller context: announced plus activated, then resolved
/// fresh from the registry (never the activate return cached).
private func e1cActiveContext(
    _ supervisor: WorkspaceSessionSupervisor
) throws -> AuthenticatedAgentContext {
    let instance = try e1cAnnounce(supervisor)
    try e1cActivate(supervisor, instance: instance)
    let context = try #require(supervisor.agentInstances.context(for: instance.id))
    try #require(context.isUsable)
    return context
}

private func e1cActivate(
    _ supervisor: WorkspaceSessionSupervisor, instance: AgentInstance
) throws {
    let directory = try #require(
        WorkingDirectory(validating: FileManager.default.temporaryDirectory.path)
    )
    let session = RuntimeSession(
        id: instance.runtimeSessionID,
        workspaceSessionID: supervisor.id,
        host: .opencode,
        workspace: directory,
        backend: .seatbelt,
        startedAt: Date(),
        child: nil
    )
    let established = try #require(
        EstablishedRuntimeSession(session: session, instance: instance, establishedAt: Date())
    )
    try #require(supervisor.agentInstances.activate(established) != nil)
}

/// Stale caller context: captured usable, then revoked. The snapshot
/// still claims usable; only the registry knows it is dead.
private func e1cStaleContext(
    _ supervisor: WorkspaceSessionSupervisor
) throws -> AuthenticatedAgentContext {
    let instance = try e1cAnnounce(supervisor)
    try e1cActivate(supervisor, instance: instance)
    let stale = try #require(supervisor.agentInstances.context(for: instance.id))
    try #require(stale.isUsable)
    let outcome = supervisor.agentInstances.revoke(
        instance.id, reason: .explicitRevoke, teardown: { true }
    )
    try #require(outcome == .revoked)
    try #require(stale.isUsable)
    return stale
}

/// Fresh unusable caller context: announced but never established, so
/// validity stays inactive.
private func e1cInactiveContext(
    _ supervisor: WorkspaceSessionSupervisor
) throws -> AuthenticatedAgentContext {
    let instance = try e1cAnnounce(supervisor)
    let context = try #require(supervisor.agentInstances.context(for: instance.id))
    try #require(context.isUsable == false)
    return context
}

private enum E1CFixtureError: Error {
    case announceFailed
    case waitTimedOut
}

private func e1cSecretsProfile(
    _ entries: [RuntimeResourceProfile.BrokerEntry]
) -> RuntimeResourceProfile {
    RuntimeResourceProfile(id: "e1c-secrets", projects: [], secrets: entries)
}

private func e1cWaitFor(_ url: URL) async -> Bool {
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return false
}

private func e1cSeen(
    _ tree: ContainmentTree,
    name: String = "seen.txt"
) async throws -> String {
    let url = tree.workspaceURL.appendingPathComponent(name)
    guard await e1cWaitFor(url) else {
        throw E1CFixtureError.waitTimedOut
    }
    return try String(contentsOf: url, encoding: .utf8)
}

private func e1cConfigDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-e1c-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
}

private func e1cWriteConfig(
    at directory: URL, name: String, json: String
) throws {
    let url = directory.appendingPathComponent(name)
    try json.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

// MARK: - Launch-level resolution

/// E1-C supervisor preparation: resolve-then-inject through the
/// launch path, fail-closed denials, and the legacy skip arms.
@Suite("Supervisor broker resolution", .serialized)
struct SupervisorBrokerResolutionTests {
    @Test func resolveInjectsValueIntoSpawnedEnvironment() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try e1cOpenWorkspace(tree)
        defer { _ = opened.supervisor.close() }
        let ref = try SecretRef(provider: "file", item: "github")
        let stub = E1CStubProvider("file") {
            $0.values = [ref: .text("synthetic-broker-value-e1c")]
        }
        let profile = e1cSecretsProfile([
            RuntimeResourceProfile.BrokerEntry(
                provider: "file", item: "github", env: "SYNTHETIC_BROKER_FIRST"
            )
        ])
        let running = try e1cLaunch(
            opened.supervisor,
            log: opened.runtimeLog,
            script: #"printf '%s' "$SYNTHETIC_BROKER_FIRST" > seen.txt; /bin/sleep 30"#,
            profile: profile,
            context: e1cActiveContext(opened.supervisor),
            providers: [stub]
        ).get()
        defer { _ = opened.supervisor.cancel(running.id) }
        #expect(try await e1cSeen(tree) == "synthetic-broker-value-e1c")
        #expect(stub.resolveCalls == [ref])
    }

    @Test func definitionTagAdmitsFilteredEntry() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try e1cOpenWorkspace(tree)
        defer { _ = opened.supervisor.close() }
        let ref = try SecretRef(provider: "file", item: "npm")
        let stub = E1CStubProvider("file") {
            $0.values = [ref: .text("synthetic-tagged-value-e1c")]
        }
        let profile = e1cSecretsProfile([
            RuntimeResourceProfile.BrokerEntry(
                provider: "file", item: "npm",
                env: "SYNTHETIC_BROKER_TAGGED", agents: ["e1c-agent"]
            )
        ])
        let tag = try #require(DefinitionStagingTag(e1cDefinition()))
        let running = try e1cLaunch(
            opened.supervisor,
            log: opened.runtimeLog,
            script: #"printf '%s' "$SYNTHETIC_BROKER_TAGGED" > seen.txt; /bin/sleep 30"#,
            profile: profile,
            stagingAgent: tag,
            context: e1cActiveContext(opened.supervisor),
            providers: [stub]
        ).get()
        defer { _ = opened.supervisor.cancel(running.id) }
        #expect(try await e1cSeen(tree) == "synthetic-tagged-value-e1c")
    }

    @Test func providerDownDeniesLaunch() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try e1cOpenWorkspace(tree)
        defer { _ = opened.supervisor.close() }
        let stub = E1CStubProvider("file") { $0.healthOK = false }
        let profile = e1cSecretsProfile([
            RuntimeResourceProfile.BrokerEntry(
                provider: "file", item: "github", env: "SYNTHETIC_BROKER_DOWN"
            )
        ])
        let result = try e1cLaunch(
            opened.supervisor,
            log: opened.runtimeLog,
            script: "/bin/sleep 30",
            profile: profile,
            context: e1cActiveContext(opened.supervisor),
            providers: [stub]
        )
        guard case .failure(.apply(.resourceStagingFailed(let detail))) = result else {
            Issue.record("down provider must deny the launch, got \(result)")
            return
        }
        #expect(detail == "broker provider 'file' unavailable")
        #expect(stub.resolveCalls.isEmpty)
    }

    @Test func timeoutDeniesLaunch() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try e1cOpenWorkspace(tree)
        defer { _ = opened.supervisor.close() }
        let stub = E1CStubProvider("file") {
            $0.resolveError = .timeout("file")
        }
        let profile = e1cSecretsProfile([
            RuntimeResourceProfile.BrokerEntry(
                provider: "file", item: "github", env: "SYNTHETIC_BROKER_TIMEOUT"
            )
        ])
        let result = try e1cLaunch(
            opened.supervisor,
            log: opened.runtimeLog,
            script: "/bin/sleep 30",
            profile: profile,
            context: e1cActiveContext(opened.supervisor),
            providers: [stub]
        )
        guard case .failure(.apply(.resourceStagingFailed(let detail))) = result else {
            Issue.record("timed-out provider must deny the launch, got \(result)")
            return
        }
        #expect(detail == "broker provider 'file' timed out")
        #expect(detail.contains("github") == false)
    }

    @Test func identityRequiredDeniesLaunch() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try e1cOpenWorkspace(tree)
        defer { _ = opened.supervisor.close() }
        let ref = try SecretRef(provider: "file", item: "github")
        let stub = E1CStubProvider("file") {
            $0.values = [ref: .text("synthetic-never-committed-e1c")]
        }
        let profile = e1cSecretsProfile([
            RuntimeResourceProfile.BrokerEntry(
                provider: "file", item: "github", env: "SYNTHETIC_BROKER_IDENTITY"
            )
        ])
        let result = try e1cLaunch(
            opened.supervisor,
            log: opened.runtimeLog,
            script: "/bin/sleep 30",
            profile: profile,
            context: e1cInactiveContext(opened.supervisor),
            providers: [stub]
        )
        guard case .failure(.apply(.resourceStagingFailed(let detail))) = result else {
            Issue.record("unusable context must deny the launch, got \(result)")
            return
        }
        #expect(detail == "broker identity required")
        #expect(stub.healthCalls == 0)
        #expect(stub.resolveCalls.isEmpty)
    }

    @Test func staleContextDeniesLaunch() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try e1cOpenWorkspace(tree)
        defer { _ = opened.supervisor.close() }
        let ref = try SecretRef(provider: "file", item: "github")
        let stub = E1CStubProvider("file") {
            $0.values = [ref: .text("synthetic-never-committed-e1c")]
        }
        let profile = e1cSecretsProfile([
            RuntimeResourceProfile.BrokerEntry(
                provider: "file", item: "github", env: "SYNTHETIC_BROKER_STALE"
            )
        ])
        let result = try e1cLaunch(
            opened.supervisor,
            log: opened.runtimeLog,
            script: "/bin/sleep 30",
            profile: profile,
            context: e1cStaleContext(opened.supervisor),
            providers: [stub]
        )
        guard case .failure(.apply(.resourceStagingFailed(let detail))) = result else {
            Issue.record("revoked context must deny the launch, got \(result)")
            return
        }
        #expect(detail == "broker identity required")
        #expect(stub.healthCalls == 0)
        #expect(stub.resolveCalls.isEmpty)
    }

    @Test func tagMismatchSkipsBroker() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try e1cOpenWorkspace(tree)
        defer { _ = opened.supervisor.close() }
        let ref = try SecretRef(provider: "file", item: "github")
        let stub = E1CStubProvider("file") {
            $0.values = [ref: .text("synthetic-skipped-e1c")]
        }
        let profile = e1cSecretsProfile([
            RuntimeResourceProfile.BrokerEntry(
                provider: "file", item: "github",
                env: "SYNTHETIC_BROKER_MISSING", agents: ["someone-else"]
            )
        ])
        let running = try e1cLaunch(
            opened.supervisor,
            log: opened.runtimeLog,
            script: #"printf '%s' "${SYNTHETIC_BROKER_MISSING:-absent}" > seen.txt; /bin/sleep 30"#,
            profile: profile,
            context: e1cActiveContext(opened.supervisor),
            providers: [stub]
        ).get()
        defer { _ = opened.supervisor.cancel(running.id) }
        #expect(try await e1cSeen(tree) == "absent")
        #expect(stub.healthCalls == 0)
        #expect(stub.resolveCalls.isEmpty)
    }

    @Test func noContextKeepsLegacyPath() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try e1cOpenWorkspace(tree)
        defer { _ = opened.supervisor.close() }
        let profile = e1cSecretsProfile([
            RuntimeResourceProfile.BrokerEntry(
                provider: "file", item: "github", env: "SYNTHETIC_BROKER_LEGACY"
            )
        ])
        let running = try e1cLaunch(
            opened.supervisor,
            log: opened.runtimeLog,
            script: #"printf '%s' "${SYNTHETIC_BROKER_LEGACY:-absent}" > seen.txt; /bin/sleep 30"#,
            profile: profile
        ).get()
        defer { _ = opened.supervisor.cancel(running.id) }
        #expect(try await e1cSeen(tree) == "absent")
    }

    @Test func factoryPathResolvesFileSecrets() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try e1cOpenWorkspace(tree)
        defer { _ = opened.supervisor.close() }
        let config = try e1cConfigDir()
        defer { try? FileManager.default.removeItem(at: config) }
        try e1cWriteConfig(
            at: config, name: "secrets-file.json",
            json: #"{"version":1,"items":{"github":{"text":"synthetic-file-value-e1c"}}}"#
        )
        let profile = e1cSecretsProfile([
            RuntimeResourceProfile.BrokerEntry(
                provider: "file", item: "github", env: "SYNTHETIC_BROKER_FILE"
            )
        ])
        let running = try e1cLaunch(
            opened.supervisor,
            log: opened.runtimeLog,
            script: #"printf '%s' "$SYNTHETIC_BROKER_FILE" > seen.txt; /bin/sleep 30"#,
            profile: profile,
            context: e1cActiveContext(opened.supervisor),
            configDirectory: config
        ).get()
        defer { _ = opened.supervisor.cancel(running.id) }
        #expect(try await e1cSeen(tree) == "synthetic-file-value-e1c")
        let ledger = config.appendingPathComponent("secrets-audit.jsonl")
        #expect(FileManager.default.fileExists(atPath: ledger.path))
        let rows = try String(contentsOf: ledger, encoding: .utf8)
        #expect(rows.contains("secret.resolve"))
        #expect(rows.contains("synthetic-file-value-e1c") == false)
    }

    @Test func missingProvidersFailsClosed() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try e1cOpenWorkspace(tree)
        defer { _ = opened.supervisor.close() }
        let profile = e1cSecretsProfile([
            RuntimeResourceProfile.BrokerEntry(
                provider: "file", item: "github", env: "SYNTHETIC_BROKER_UNAVAILABLE"
            )
        ])
        let result = try e1cLaunch(
            opened.supervisor,
            log: opened.runtimeLog,
            script: "/bin/sleep 30",
            profile: profile,
            context: e1cActiveContext(opened.supervisor)
        )
        guard case .failure(.apply(.resourceStagingFailed(let detail))) = result else {
            Issue.record("context without providers must fail closed, got \(result)")
            return
        }
        #expect(detail == "broker secrets unavailable")
    }

    @Test func corruptFactoryConfigFailsClosed() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try e1cOpenWorkspace(tree)
        defer { _ = opened.supervisor.close() }
        let config = try e1cConfigDir()
        defer { try? FileManager.default.removeItem(at: config) }
        try e1cWriteConfig(
            at: config, name: "secrets-providers.json", json: "{not-json"
        )
        let profile = e1cSecretsProfile([
            RuntimeResourceProfile.BrokerEntry(
                provider: "file", item: "github", env: "SYNTHETIC_BROKER_CORRUPT"
            )
        ])
        let result = try e1cLaunch(
            opened.supervisor,
            log: opened.runtimeLog,
            script: "/bin/sleep 30",
            profile: profile,
            context: e1cActiveContext(opened.supervisor),
            configDirectory: config
        )
        guard case .failure(.apply(.resourceStagingFailed(let detail))) = result else {
            Issue.record("corrupt factory config must fail closed, got \(result)")
            return
        }
        #expect(detail == "broker providers configuration invalid")
    }

    @Test func invalidRefAuditsDropWithoutBroker() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try e1cOpenWorkspace(tree)
        defer { _ = opened.supervisor.close() }
        let config = try e1cConfigDir()
        defer { try? FileManager.default.removeItem(at: config) }
        // Corrupt on purpose: nothing is admitted, so the factory must
        // never run — a launch with no resolvable refs must not depend
        // on provider config at all.
        try e1cWriteConfig(
            at: config, name: "secrets-providers.json", json: "{not-json"
        )
        let profile = e1cSecretsProfile([
            RuntimeResourceProfile.BrokerEntry(
                provider: "nope", item: "keepme", env: "SYNTHETIC_BADREF_E1C"
            )
        ])
        let running = try e1cLaunch(
            opened.supervisor,
            log: opened.runtimeLog,
            script: #"printf '%s' "${SYNTHETIC_BADREF_E1C:-absent}" > seen.txt; /bin/sleep 30"#,
            profile: profile,
            context: e1cActiveContext(opened.supervisor),
            configDirectory: config
        ).get()
        defer { _ = opened.supervisor.cancel(running.id) }
        #expect(try await e1cSeen(tree) == "absent")
        let ledger = config.appendingPathComponent("secrets-audit.jsonl")
        let rows = SecretsLedger.loadRecords(fileURL: ledger)
        let row = try #require(rows.count == 1 ? rows[0] : nil)
        #expect(row.decision == .denied)
        #expect(row.cause?.redacted == "stagingDrop:invalidRef:SYNTHETIC_BADREF_E1C")
    }
}

// MARK: - Preparation core

/// Fast unit pins for the preparation core: skip arms, mapping, and
/// the sync bridge. No supervisor, no spawn.
@Suite("Broker launch preparation")
struct BrokerLaunchPreparationTests {
    @Test func detailsAreProviderOnly() {
        let secrets: [(SecretsError, String)] = [
            (.invalidRef("file"), "broker ref rejected by provider 'file'"),
            (.notFound("env"), "broker secret missing from provider 'env'"),
            (.denied("vault-http"), "broker provider 'vault-http' denied access"),
            (.identityRequired, "broker identity required"),
            (.leaseExpired("vault-http"), "broker lease expired at provider 'vault-http'"),
            (.providerDown("file"), "broker provider 'file' unavailable"),
            (.oversized("file"), "broker value oversized from provider 'file'"),
            (.policyDenied, "broker policy denied"),
            (.timeout("vault-http"), "broker provider 'vault-http' timed out"),
        ]
        for (error, detail) in secrets {
            #expect(brokerSecretsDetail(error) == detail)
            #expect(BrokerLaunchFailure.secrets(error).detail == detail)
        }
        let factory: [(SecretsProviderFactoryError, String)] = [
            (.providersInvalid, "broker providers configuration invalid"),
            (.vaultConfigInvalid, "broker vault configuration invalid"),
            (.vaultCredentialsInvalid, "broker vault credentials invalid"),
            (.vaultMisconfigured, "broker vault misconfigured"),
        ]
        for (error, detail) in factory {
            #expect(brokerFactoryDetail(error) == detail)
            #expect(BrokerLaunchFailure.factory(error).detail == detail)
        }
        #expect(BrokerLaunchFailure.providersUnavailable.detail == "broker secrets unavailable")
        #expect(BrokerLaunchFailure.interrupted.detail == "broker resolution interrupted")
    }

    @Test func prepareSkipsWithoutSecretsOrContext() throws {
        let registry = try e1cStandaloneRegistry()
        let stub = E1CStubProvider("file")
        let active = try e1cStandaloneContext(registry: registry, usable: true)
        let empty = RuntimeResourceManifest(
            RuntimeResourceProfile(id: "e1c-empty", projects: [])
        )
        let untagged = RuntimeResourceManifest(e1cSecretsProfile([
            RuntimeResourceProfile.BrokerEntry(
                provider: "file", item: "github", env: "SYNTHETIC_BROKER_UNIT"
            )
        ]))
        let skipped: [Result<BrokerLaunchPreparation, BrokerLaunchFailure>] = [
            prepareBrokerLaunchValues(
                resources: nil, agent: nil, context: active,
                providers: [stub], configDirectory: nil,
                registry: registry, timeoutSeconds: 5
            ),
            prepareBrokerLaunchValues(
                resources: empty, agent: nil, context: active,
                providers: [stub], configDirectory: nil,
                registry: registry, timeoutSeconds: 5
            ),
            prepareBrokerLaunchValues(
                resources: untagged, agent: nil, context: nil,
                providers: [stub], configDirectory: nil,
                registry: registry, timeoutSeconds: 5
            ),
        ]
        for result in skipped {
            guard case .success(let preparation) = result else {
                Issue.record("skip arms must succeed skipped, got \(result)")
                continue
            }
            #expect(preparation == .skipped)
        }
        #expect(stub.healthCalls == 0)
        #expect(stub.resolveCalls.isEmpty)
    }

    @Test func prepareHandsEmptyMapWhenNothingAdmitted() throws {
        let registry = try e1cStandaloneRegistry()
        let stub = E1CStubProvider("file")
        let active = try e1cStandaloneContext(registry: registry, usable: true)
        let auditDir = try e1cConfigDir()
        defer { try? FileManager.default.removeItem(at: auditDir) }
        let tagged = RuntimeResourceManifest(e1cSecretsProfile([
            RuntimeResourceProfile.BrokerEntry(
                provider: "file", item: "github",
                env: "SYNTHETIC_BROKER_UNIT", agents: ["someone-else"]
            )
        ]))
        let invalid = RuntimeResourceManifest(e1cSecretsProfile([
            RuntimeResourceProfile.BrokerEntry(
                provider: "nope", item: "keepme",
                env: "SYNTHETIC_BROKER_UNIT"
            )
        ]))
        for resources in [tagged, invalid] {
            let result = prepareBrokerLaunchValues(
                resources: resources, agent: nil, context: active,
                providers: [stub], configDirectory: auditDir,
                registry: registry, timeoutSeconds: 5
            )
            guard case .success(let preparation) = result else {
                Issue.record("empty admission must hand an empty map, got \(result)")
                continue
            }
            #expect(preparation.values == [:])
            #expect(preparation.auditDirectory == auditDir)
        }
        #expect(stub.healthCalls == 0)
        #expect(stub.resolveCalls.isEmpty)
    }

    @Test func prepareResolvesWithInjectedProviders() throws {
        let registry = try e1cStandaloneRegistry()
        let ref = try SecretRef(provider: "file", item: "github")
        let stub = E1CStubProvider("file") {
            $0.values = [ref: .text("synthetic-unit-e1c")]
        }
        let resources = RuntimeResourceManifest(e1cSecretsProfile([
            RuntimeResourceProfile.BrokerEntry(
                provider: "file", item: "github", env: "SYNTHETIC_BROKER_UNIT"
            )
        ]))
        let active = try e1cStandaloneContext(registry: registry, usable: true)
        let auditDir = try e1cConfigDir()
        defer { try? FileManager.default.removeItem(at: auditDir) }
        let result = prepareBrokerLaunchValues(
            resources: resources, agent: nil, context: active,
            providers: [stub], configDirectory: auditDir,
            registry: registry, timeoutSeconds: 5
        )
        guard case .success(let preparation) = result else {
            Issue.record("injected providers must resolve, got \(result)")
            return
        }
        #expect(preparation.values == [ref: .text("synthetic-unit-e1c")])
        #expect(preparation.auditDirectory == auditDir)
    }

    @Test func prepareFailsWhenProviderDown() throws {
        let registry = try e1cStandaloneRegistry()
        let stub = E1CStubProvider("file") { $0.healthOK = false }
        let resources = RuntimeResourceManifest(e1cSecretsProfile([
            RuntimeResourceProfile.BrokerEntry(
                provider: "file", item: "github", env: "SYNTHETIC_BROKER_UNIT"
            )
        ]))
        let active = try e1cStandaloneContext(registry: registry, usable: true)
        let result = prepareBrokerLaunchValues(
            resources: resources, agent: nil, context: active,
            providers: [stub], configDirectory: nil,
            registry: registry, timeoutSeconds: 5
        )
        guard case .failure(let failure) = result else {
            Issue.record("down provider must fail preparation, got \(result)")
            return
        }
        #expect(failure == .secrets(.providerDown("file")))
        #expect(stub.resolveCalls.isEmpty)
    }

    @Test func bridgeResolvesAndDenies() throws {
        let ref = try SecretRef(provider: "file", item: "github")
        let stub = E1CStubProvider("file") {
            $0.values = [ref: .text("synthetic-bridge-e1c")]
        }
        let broker = SecretBroker(
            providers: [stub],
            audit: SecretBrokerAuditSink(append: { _ in }),
            liveness: .usableOnly
        )
        let instance = AgentInstance(
            id: AgentInstanceID(),
            owner: OwnerPrincipal(uid: 501),
            definitionID: AgentDefinitionID(rawValue: "e1c-bridge"),
            definitionRevision: AgentDefinitionRevision(
                digestHex: String(repeating: "c", count: 64)
            ),
            workspaceSessionID: WorkspaceSessionID(),
            runtimeSessionID: RuntimeSessionID(),
            executableEvidence: .none,
            assurance: .launchObserved,
            groupLeader: RuntimeChildIdentity(pid: 100),
            workloadProcess: nil,
            parent: nil,
            effectiveAuthority: AgentAuthority(scopes: ["shell"]),
            delegableAuthority: AgentAuthority(scopes: ["shell"]),
            mintedAt: Date()
        )
        let resolved = resolveBrokerValuesBlocking(
            broker, refs: [ref],
            context: AuthenticatedAgentContext(instance: instance, validity: .active)
        )
        guard case .success(let values) = resolved else {
            Issue.record("usable context must resolve, got \(resolved)")
            return
        }
        #expect(values == [ref: .text("synthetic-bridge-e1c")])
        let denied = resolveBrokerValuesBlocking(
            broker, refs: [ref],
            context: AuthenticatedAgentContext(instance: instance, validity: .inactive)
        )
        guard case .failure(let failure) = denied else {
            Issue.record("unusable context must deny, got \(denied)")
            return
        }
        #expect(failure == .secrets(.identityRequired))
    }

    @Test func bridgeMapsNonSecretsThrowToInterrupted() throws {
        // A hostile audit sink throws CancellationError spuriously (the
        // bridge task itself is never cancelled). The broker rethrows it
        // past the SecretsError arms, and the bridge maps it closed to
        // `.interrupted` instead of leaking the throw.
        let ref = try SecretRef(provider: "file", item: "github")
        let stub = E1CStubProvider("file") {
            $0.values = [ref: .text("synthetic-bridge-e1f")]
        }
        let broker = SecretBroker(
            providers: [stub],
            audit: SecretBrokerAuditSink(append: { _ in throw CancellationError() }),
            liveness: .usableOnly
        )
        let instance = AgentInstance(
            id: AgentInstanceID(),
            owner: OwnerPrincipal(uid: 501),
            definitionID: AgentDefinitionID(rawValue: "e1f-bridge"),
            definitionRevision: AgentDefinitionRevision(
                digestHex: String(repeating: "f", count: 64)
            ),
            workspaceSessionID: WorkspaceSessionID(),
            runtimeSessionID: RuntimeSessionID(),
            executableEvidence: .none,
            assurance: .launchObserved,
            groupLeader: RuntimeChildIdentity(pid: 100),
            workloadProcess: nil,
            parent: nil,
            effectiveAuthority: AgentAuthority(scopes: ["shell"]),
            delegableAuthority: AgentAuthority(scopes: ["shell"]),
            mintedAt: Date()
        )
        let result = resolveBrokerValuesBlocking(
            broker, refs: [ref],
            context: AuthenticatedAgentContext(instance: instance, validity: .active)
        )
        guard case .failure(let failure) = result else {
            Issue.record("audit throw must fail closed, got \(result)")
            return
        }
        #expect(failure == .interrupted)
    }
}

private func e1cStandaloneRegistry() throws -> AgentInstanceRegistry {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-e1c-instances-\(UUID().uuidString).jsonl")
    return AgentInstanceRegistry(journal: .file(url))
}

private func e1cStandaloneContext(
    registry: AgentInstanceRegistry, usable: Bool
) throws -> AuthenticatedAgentContext {
    let definition = e1cDefinition()
    let instance = AgentInstance(
        id: AgentInstanceID(),
        owner: OwnerPrincipal(uid: 501),
        definitionID: definition.id,
        definitionRevision: AgentDefinitionRevision.resolve(definition),
        workspaceSessionID: WorkspaceSessionID(),
        runtimeSessionID: RuntimeSessionID(),
        executableEvidence: .none,
        assurance: .launchObserved,
        groupLeader: RuntimeChildIdentity(pid: 100),
        workloadProcess: nil,
        parent: nil,
        effectiveAuthority: definition.authorityCeiling,
        delegableAuthority: definition.authorityCeiling,
        mintedAt: Date()
    )
    guard registry.announce(instance) else {
        throw E1CFixtureError.announceFailed
    }
    if usable {
        let directory = try #require(
            WorkingDirectory(validating: FileManager.default.temporaryDirectory.path)
        )
        let session = RuntimeSession(
            id: instance.runtimeSessionID,
            workspaceSessionID: instance.workspaceSessionID,
            host: .opencode,
            workspace: directory,
            backend: .seatbelt,
            startedAt: Date(),
            child: nil
        )
        let established = try #require(
            EstablishedRuntimeSession(
                session: session, instance: instance, establishedAt: Date()
            )
        )
        try #require(registry.activate(established) != nil)
    }
    let context = try #require(registry.context(for: instance.id))
    try #require(context.isUsable == usable)
    return context
}
#endif
