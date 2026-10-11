#if os(macOS)
import Darwin
import Foundation
import RVDomain
import RVFileStore
import Synchronization
import Testing
@testable import RVIsolation
@testable import RVPolicy

// MARK: - Helpers

/// Scripted provider: records every call so tests prove what the
/// prepare-time freeze did and did not touch.
private struct E1DStubScript: Sendable {
    var healthOK = true
    var resolveError: SecretsError?
    var values: [SecretRef: SecretValue] = [:]
    var healthCalls = 0
    var resolveCalls: [SecretRef] = []
}

private final class E1DStubState: Sendable {
    let mutex = Mutex(E1DStubScript())
}

private struct E1DStubProvider: SecretsProvider, Sendable {
    var id: String
    var state: E1DStubState

    init(_ id: String, configure: (inout E1DStubScript) -> Void = { _ in }) {
        self.id = id
        let state = E1DStubState()
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
        let script = state.mutex.withLock { script -> E1DStubScript in
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

    func setValues(_ values: [SecretRef: SecretValue]) {
        state.mutex.withLock { $0.values = values }
    }
}

private func e1dDefinition(
    id: String = "e1d-agent",
    target: String = "/bin/sleep",
    projects: [String],
    agentTag: String? = "e1d-agent",
    secrets: [RuntimeResourceProfile.BrokerEntry] = [],
    credentialBindings: [String] = [],
    credentials: [RuntimeResourceProfile.Credential] = [],
    keychain: [RuntimeResourceProfile.KeychainEntry] = []
) -> AgentDefinition {
    AgentDefinition(
        id: AgentDefinitionID(rawValue: id),
        displayName: "E1-D agent",
        blurb: "",
        executableRequirement: ExecutableRequirement(allowsUnsigned: true),
        hookHost: .opencode,
        agentTag: agentTag,
        resourceProfile: RuntimeResourceProfile(
            id: "e1d",
            projects: projects,
            executableLinks: [.init(name: id, target: target)],
            credentials: credentials,
            keychain: keychain,
            secrets: secrets
        ),
        credentialBindings: credentialBindings,
        requiredAssurance: .launchObserved,
        authorityCeiling: AgentAuthority(scopes: ["shell"])
    )
}

private func e1dSelection(_ definition: AgentDefinition) -> ResolvedAgentLaunch {
    ResolvedAgentLaunch(
        resolved: ResolvedAgentDefinition(
            definition: definition,
            revision: AgentDefinitionRevision.resolve(definition)
        ),
        executable: definition.resourceProfile.executableLinks.first(where: {
            $0.name == definition.id.rawValue
        })?.target ?? "/bin/sleep",
        resourceProfile: definition.resourceProfile
    )
}

private func e1dEntry(
    provider: String = "file",
    item: String = "github",
    field: String? = nil,
    env: String,
    agents: [String]? = nil
) -> RuntimeResourceProfile.BrokerEntry {
    RuntimeResourceProfile.BrokerEntry(
        provider: provider, item: item, field: field, env: env, agents: agents
    )
}

private func e1dSupervisor(_ tree: ContainmentTree) throws -> WorkspaceSessionSupervisor {
    try WorkspaceSessionSupervisor.open(
        try #require(WorkingDirectory(validating: tree.workspaceURL.path)),
        lifecycleLog: .file(tree.rootURL.appendingPathComponent("workspace-e1d.jsonl")),
        runtimeLog: tree.rootURL.appendingPathComponent("runtimes-e1d.jsonl"),
        instanceJournal: .file(tree.rootURL.appendingPathComponent("instances-e1d.jsonl"))
    ).get()
}

private func e1dHost() -> (WorkspaceHostID, WorkspaceHostGeneration) {
    (WorkspaceHostID(), WorkspaceHostGeneration())
}

private func e1dAnnounce(
    _ supervisor: WorkspaceSessionSupervisor,
    definition: AgentDefinition
) throws -> AgentInstance {
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
        throw E1DFixtureError.announceFailed
    }
    return instance
}

private func e1dActivate(
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

/// Fresh usable caller context: announced plus activated, then resolved
/// fresh from the registry (never the activate return cached).
private func e1dActiveContext(
    _ supervisor: WorkspaceSessionSupervisor,
    definition: AgentDefinition
) throws -> AuthenticatedAgentContext {
    let instance = try e1dAnnounce(supervisor, definition: definition)
    try e1dActivate(supervisor, instance: instance)
    let context = try #require(supervisor.agentInstances.context(for: instance.id))
    try #require(context.isUsable)
    return context
}

/// Stale caller context: captured usable, then revoked. The snapshot
/// still claims usable; only the registry knows it is dead.
private func e1dStaleContext(
    _ supervisor: WorkspaceSessionSupervisor,
    definition: AgentDefinition
) throws -> AuthenticatedAgentContext {
    let instance = try e1dAnnounce(supervisor, definition: definition)
    try e1dActivate(supervisor, instance: instance)
    let stale = try #require(supervisor.agentInstances.context(for: instance.id))
    try #require(stale.isUsable)
    let outcome = supervisor.agentInstances.revoke(
        instance.id, reason: .explicitRevoke, teardown: { true }
    )
    try #require(outcome == .revoked)
    try #require(stale.isUsable)
    return stale
}

private enum E1DFixtureError: Error {
    case announceFailed
}

private func e1dScratch(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func e1dCommit(
    authorizationID: UUID = UUID(),
    prepared: PreparedWorkspaceLaunch
) -> HostRedemptionCommit {
    let kind: HostRedemptionKind
    let definitionID: AgentDefinitionID?
    let revision: AgentDefinitionRevision?
    switch prepared.intent.target {
    case .named:
        kind = .launchAgent
        definitionID = prepared.selection.resolved.definition.id
        revision = prepared.selection.resolved.revision
    case .custom:
        kind = .launchCustom
        definitionID = nil
        revision = nil
    }
    return HostRedemptionCommit(
        authorizationID: authorizationID,
        workspace: prepared.binding.workspace,
        host: prepared.binding.host,
        generation: prepared.binding.generation,
        preparedID: prepared.binding.preparedLaunchID,
        intentDigest: prepared.intentDigest,
        kind: kind,
        definitionID: definitionID,
        definitionRevision: revision
    )
}

// MARK: - Pure freeze map

/// `frozenPreparedBrokerPairs`: text-backed pairs freeze, file-backed
/// and unknown pairs refuse with provider-only causes.
@Suite("Prepared broker freeze map")
struct PreparedBrokerFreezeMapTests {
    private func freezeProfile(
        _ entries: [RuntimeResourceProfile.BrokerEntry]
    ) -> RuntimeResourceProfile {
        RuntimeResourceProfile(id: "e1d-freeze", projects: [], secrets: entries)
    }

    @Test func textBackedPairsFreeze() throws {
        let entry = e1dEntry(env: "E1D_FIRST")
        let ref = try #require(entry.ref)
        let profile = freezeProfile([entry])
        let values: [SecretRef: SecretValue] = [ref: .text("synthetic-v1")]
        let result = frozenPreparedBrokerPairs(
            [(name: "E1D_FIRST", value: "synthetic-v1")],
            profile: profile, values: values
        )
        guard case .success(let frozen) = result else {
            Issue.record("text pairs must freeze, got \(result)")
            return
        }
        #expect(frozen.map(\.name) == ["E1D_FIRST"])
        #expect(frozen.map(\.value) == ["synthetic-v1"])
    }

    @Test func emptyPayloadFreezesEmpty() {
        let profile = freezeProfile([e1dEntry(env: "E1D_FIRST")])
        let result = frozenPreparedBrokerPairs([], profile: profile, values: [:])
        guard case .success(let frozen) = result else {
            Issue.record("empty payload must freeze, got \(result)")
            return
        }
        #expect(frozen.isEmpty)
    }

    @Test func fileBackedPairRefusesWithProviderOnlyCause() throws {
        let entry = e1dEntry(env: "E1D_FILE")
        let ref = try #require(entry.ref)
        let profile = freezeProfile([entry])
        let stagedPath = "/tmp/e1d-throwaway/secrets/E1D_FILE"
        let values: [SecretRef: SecretValue] = [ref: .filePath("/tmp/e1d-source")]
        let result = frozenPreparedBrokerPairs(
            [(name: "E1D_FILE", value: stagedPath)],
            profile: profile, values: values
        )
        guard case .failure(let error) = result else {
            Issue.record("file-backed pair must refuse, got \(result)")
            return
        }
        #expect(
            error
                == .brokerSecretsUnavailable(
                    "broker file values from provider 'file' cannot freeze"
                )
        )
        // Provider-only: neither the staged path nor the source path
        // may appear in the refusal.
        #expect("\(error)".contains("e1d-throwaway") == false)
        #expect("\(error)".contains("e1d-source") == false)
    }

    @Test func pairWithoutProfileEntryRefuses() {
        let profile = freezeProfile([e1dEntry(env: "E1D_FIRST")])
        let result = frozenPreparedBrokerPairs(
            [(name: "E1D_PHANTOM", value: "x")],
            profile: profile, values: [:]
        )
        guard case .failure(let error) = result else {
            Issue.record("unknown pair must refuse, got \(result)")
            return
        }
        #expect(error == .brokerSecretsUnavailable("broker staged values cannot freeze"))
    }

    @Test func pairWithoutResolvedValueRefuses() throws {
        let entry = e1dEntry(env: "E1D_FIRST")
        _ = try #require(entry.ref)
        let profile = freezeProfile([entry])
        // No value for the entry's ref: an integrity anomaly, refused.
        let result = frozenPreparedBrokerPairs(
            [(name: "E1D_FIRST", value: "x")],
            profile: profile, values: [:]
        )
        guard case .failure(let error) = result else {
            Issue.record("unvalued pair must refuse, got \(result)")
            return
        }
        #expect(error == .brokerSecretsUnavailable("broker staged values cannot freeze"))
    }

    @Test func duplicateEnvNamesFollowFirstSpelling() throws {
        let first = e1dEntry(item: "alpha", env: "E1D_DUP")
        let second = e1dEntry(item: "beta", env: "E1D_DUP")
        let firstRef = try #require(first.ref)
        let secondRef = try #require(second.ref)
        // Text first spelling freezes; the shadowed file sibling drops
        // downstream exactly like the spawn path's first-spelling-wins.
        let textFirst = freezeProfile([first, second])
        let frozenResult = frozenPreparedBrokerPairs(
            [(name: "E1D_DUP", value: "t"), (name: "E1D_DUP", value: "/p")],
            profile: textFirst,
            values: [firstRef: .text("t"), secondRef: .filePath("/src")]
        )
        guard case .success(let frozen) = frozenResult else {
            Issue.record("text first spelling must freeze, got \(frozenResult)")
            return
        }
        #expect(frozen.map(\.value) == ["t", "/p"])
        // File-backed first spelling refuses: it is the pair that would
        // inject, and its staged path cannot survive the freeze.
        let fileFirst = freezeProfile([second, first])
        let refusedResult = frozenPreparedBrokerPairs(
            [(name: "E1D_DUP", value: "/p"), (name: "E1D_DUP", value: "t")],
            profile: fileFirst,
            values: [firstRef: .text("t"), secondRef: .filePath("/src")]
        )
        guard case .failure(let error) = refusedResult else {
            Issue.record("file first spelling must refuse, got \(refusedResult)")
            return
        }
        #expect(
            error
                == .brokerSecretsUnavailable(
                    "broker file values from provider 'file' cannot freeze"
                )
        )
    }
}

// MARK: - Prepare-time freeze

/// E1-D freeze-at-prepare: a prepared launch with `secrets` entries
/// resolves through the broker at prepare time and freezes the pairs
/// into `prepared.environment.entries`; redemption injects them without
/// re-resolving (it threads no caller context, so the broker seam
/// below proves the no-resolution call shape), and prepare-time broker
/// failure fails prepare closed with a provider-only cause.
@Suite(.serialized)
struct PreparedBrokerFreezeTests {
    @Test func freezePinsResolvedBrokerValues() throws {
        let tree = try ContainmentTree()
        let supervisor = try e1dSupervisor(tree)
        defer { _ = supervisor.close() }
        let entry = e1dEntry(env: "E1D_FIRST")
        let ref = try #require(entry.ref)
        let definition = e1dDefinition(
            projects: [tree.workspaceURL.path], secrets: [entry]
        )
        let context = try e1dActiveContext(supervisor, definition: definition)
        let provider = E1DStubProvider("file") {
            $0.values = [ref: .text("synthetic-v1")]
        }
        let (host, generation) = e1dHost()
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: e1dSelection(definition),
            arguments: [], io: .discard,
            host: host, generation: generation,
            brokerCallerContext: context,
            brokerProviders: [provider]
        ).get()
        #expect(prepared.environment.entries.contains("E1D_FIRST=synthetic-v1"))
        #expect(prepared.stagingAgent?.rawValue == "e1d-agent")
        // The digest covers the frozen pairs: rebuilding reproduces it.
        #expect(
            WorkspaceLaunchEnvironmentSnapshot(entries: prepared.environment.entries).digestHex
                == prepared.environment.digestHex
        )
        #expect(provider.resolveCalls == [ref])
    }

    @Test func frozenValuesSurviveProviderChange() throws {
        let tree = try ContainmentTree()
        let supervisor = try e1dSupervisor(tree)
        defer { _ = supervisor.close() }
        let entry = e1dEntry(env: "E1D_FIRST")
        let ref = try #require(entry.ref)
        let definition = e1dDefinition(
            projects: [tree.workspaceURL.path], secrets: [entry]
        )
        let context = try e1dActiveContext(supervisor, definition: definition)
        let provider = E1DStubProvider("file") {
            $0.values = [ref: .text("synthetic-v1")]
        }
        let (host, generation) = e1dHost()
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: e1dSelection(definition),
            arguments: [], io: .discard,
            host: host, generation: generation,
            brokerCallerContext: context,
            brokerProviders: [provider]
        ).get()
        let digestBefore = prepared.environment.digestHex
        // Mutate the provider between prepare and redeem: the frozen
        // snapshot must not move.
        provider.setValues([ref: .text("synthetic-v2")])
        #expect(prepared.environment.entries.contains("E1D_FIRST=synthetic-v1"))
        #expect(prepared.environment.entries.contains("E1D_FIRST=synthetic-v2") == false)
        #expect(prepared.environment.digestHex == digestBefore)
        // Anti-vacuity control: the mutation took effect — a fresh
        // prepare observes v2 while the frozen one still carries v1.
        let fresh = try supervisor.prepareIdentityLaunch(
            selection: e1dSelection(definition),
            arguments: [], io: .discard,
            host: host, generation: generation,
            brokerCallerContext: context,
            brokerProviders: [provider]
        ).get()
        #expect(fresh.environment.entries.contains("E1D_FIRST=synthetic-v2"))
        #expect(fresh.environment.digestHex != digestBefore)
    }

    @Test func redemptionCallShapeResolvesNothing() throws {
        // Redemption threads no caller context, no providers, and no
        // config directory into resolution — this is exactly that call
        // shape, and it must skip without touching any provider.
        let entry = e1dEntry(env: "E1D_FIRST")
        let ref = try #require(entry.ref)
        let resources = RuntimeResourceManifest(
            RuntimeResourceProfile(id: "e1d", projects: [], secrets: [entry])
        )
        defer { resources.remove() }
        let scratch = try e1dScratch(prefix: "rv-e1d-noresolve")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let registry = AgentInstanceRegistry(
            journal: .file(scratch.appendingPathComponent("instances.jsonl"))
        )
        let provider = E1DStubProvider("file") {
            $0.values = [ref: .text("synthetic-v1")]
        }
        let result = prepareBrokerLaunchValues(
            resources: resources,
            agent: "e1d-agent",
            context: nil,
            providers: [provider],
            configDirectory: nil,
            registry: registry,
            timeoutSeconds: 5
        )
        #expect(result == .success(.skipped))
        #expect(provider.healthCalls == 0)
        #expect(provider.resolveCalls.isEmpty)
    }

    @Test func prepareFailsClosedWhenProviderDown() throws {
        let tree = try ContainmentTree()
        let supervisor = try e1dSupervisor(tree)
        defer { _ = supervisor.close() }
        let entry = e1dEntry(env: "E1D_FIRST")
        let definition = e1dDefinition(
            projects: [tree.workspaceURL.path], secrets: [entry]
        )
        let context = try e1dActiveContext(supervisor, definition: definition)
        let provider = E1DStubProvider("file") {
            $0.resolveError = .providerDown("file")
        }
        let (host, generation) = e1dHost()
        #expect(
            supervisor.prepareIdentityLaunch(
                selection: e1dSelection(definition),
                arguments: [], io: .discard,
                host: host, generation: generation,
                brokerCallerContext: context,
                brokerProviders: [provider]
            ) == .failure(
                .brokerSecretsUnavailable("broker provider 'file' unavailable")
            )
        )
    }

    @Test func prepareFailsClosedWithoutCallerContext() throws {
        let tree = try ContainmentTree()
        let supervisor = try e1dSupervisor(tree)
        defer { _ = supervisor.close() }
        let entry = e1dEntry(env: "E1D_FIRST")
        let definition = e1dDefinition(
            projects: [tree.workspaceURL.path], secrets: [entry]
        )
        let (host, generation) = e1dHost()
        // Default broker params: no caller context. Unlike the spawn
        // path's legacy nil path (which ignores `secrets`), the freeze
        // refuses rather than silently omitting admitted secrets.
        #expect(
            supervisor.prepareIdentityLaunch(
                selection: e1dSelection(definition),
                arguments: [], io: .discard,
                host: host, generation: generation
            ) == .failure(.brokerSecretsUnavailable("broker identity required"))
        )
    }

    @Test func nilContextWithFullyFilteredSecretsFreezesEmpty() throws {
        let tree = try ContainmentTree()
        let supervisor = try e1dSupervisor(tree)
        defer { _ = supervisor.close() }
        let entry = e1dEntry(env: "E1D_FIRST", agents: ["other-agent"])
        let definition = e1dDefinition(
            projects: [tree.workspaceURL.path], secrets: [entry]
        )
        let (host, generation) = e1dHost()
        // Nothing admittable for this tag: nothing secret is at stake,
        // so the freeze proceeds empty like the spawn nil contract.
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: e1dSelection(definition),
            arguments: [], io: .discard,
            host: host, generation: generation
        ).get()
        #expect(prepared.environment.entries.contains(where: { $0.hasPrefix("E1D_FIRST=") }) == false)
    }

    @Test func prepareFailsClosedOnRevokedContext() throws {
        let tree = try ContainmentTree()
        let supervisor = try e1dSupervisor(tree)
        defer { _ = supervisor.close() }
        let entry = e1dEntry(env: "E1D_FIRST")
        let ref = try #require(entry.ref)
        let definition = e1dDefinition(
            projects: [tree.workspaceURL.path], secrets: [entry]
        )
        let stale = try e1dStaleContext(supervisor, definition: definition)
        let provider = E1DStubProvider("file") {
            $0.values = [ref: .text("synthetic-v1")]
        }
        let (host, generation) = e1dHost()
        #expect(
            supervisor.prepareIdentityLaunch(
                selection: e1dSelection(definition),
                arguments: [], io: .discard,
                host: host, generation: generation,
                brokerCallerContext: stale,
                brokerProviders: [provider]
            ) == .failure(.brokerSecretsUnavailable("broker identity required"))
        )
    }

    @Test func prepareRefusesFileValuedBrokerSecrets() throws {
        let tree = try ContainmentTree()
        let supervisor = try e1dSupervisor(tree)
        defer { _ = supervisor.close() }
        let entry = e1dEntry(env: "E1D_FILE")
        let ref = try #require(entry.ref)
        let definition = e1dDefinition(
            projects: [tree.workspaceURL.path], secrets: [entry]
        )
        let context = try e1dActiveContext(supervisor, definition: definition)
        // A real readable source so the probe stage emits a pair for the
        // freeze map to refuse (a missing source drops at stage time,
        // exactly like the spawn path).
        let source = tree.rootURL.appendingPathComponent("e1d-source-secret")
        try "e1d-file-material".write(to: source, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: source.path
        )
        let provider = E1DStubProvider("file") {
            $0.values = [ref: .filePath(source.path)]
        }
        let (host, generation) = e1dHost()
        let result = supervisor.prepareIdentityLaunch(
            selection: e1dSelection(definition),
            arguments: [], io: .discard,
            host: host, generation: generation,
            brokerCallerContext: context,
            brokerProviders: [provider]
        )
        guard case .failure(let error) = result else {
            Issue.record("file-valued secret must refuse prepare, got \(result)")
            return
        }
        #expect(
            error
                == .brokerSecretsUnavailable(
                    "broker file values from provider 'file' cannot freeze"
                )
        )
        #expect("\(error)".contains("e1d-source-secret") == false)
        #expect("\(error)".contains("e1d-file-material") == false)
    }

    @Test func prepareWithoutSecretsIgnoresBrokerParams() throws {
        let tree = try ContainmentTree()
        let supervisor = try e1dSupervisor(tree)
        defer { _ = supervisor.close() }
        let definition = e1dDefinition(projects: [tree.workspaceURL.path])
        let context = try e1dActiveContext(supervisor, definition: definition)
        let ref = try SecretRef(provider: "file", item: "github")
        let provider = E1DStubProvider("file") {
            $0.values = [ref: .text("synthetic-v1")]
        }
        let (host, generation) = e1dHost()
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: e1dSelection(definition),
            arguments: [], io: .discard,
            host: host, generation: generation,
            brokerCallerContext: context,
            brokerProviders: [provider]
        ).get()
        #expect(prepared.environment.entries.contains(where: { $0.hasPrefix("E1D_") }) == false)
        #expect(provider.healthCalls == 0)
        #expect(provider.resolveCalls.isEmpty)
    }

    @Test func tagFilteredEntriesFreezeNothingWithoutProviderTouch() throws {
        let tree = try ContainmentTree()
        let supervisor = try e1dSupervisor(tree)
        defer { _ = supervisor.close() }
        let entry = e1dEntry(env: "E1D_FIRST", agents: ["other-agent"])
        let ref = try #require(entry.ref)
        let definition = e1dDefinition(
            projects: [tree.workspaceURL.path], secrets: [entry]
        )
        let context = try e1dActiveContext(supervisor, definition: definition)
        let provider = E1DStubProvider("file") {
            $0.values = [ref: .text("synthetic-v1")]
        }
        let (host, generation) = e1dHost()
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: e1dSelection(definition),
            arguments: [], io: .discard,
            host: host, generation: generation,
            brokerCallerContext: context,
            brokerProviders: [provider]
        ).get()
        #expect(prepared.environment.entries.contains(where: { $0.hasPrefix("E1D_FIRST=") }) == false)
        #expect(provider.healthCalls == 0)
        #expect(provider.resolveCalls.isEmpty)
    }

    @Test func legacyShapesStillRefusedWithBrokerContext() throws {
        let tree = try ContainmentTree()
        let supervisor = try e1dSupervisor(tree)
        defer { _ = supervisor.close() }
        let (host, generation) = e1dHost()
        // A broker context must not smuggle legacy credential shapes
        // through the identity door.
        for credentialed in [
            e1dDefinition(
                projects: [tree.workspaceURL.path], credentialBindings: ["token"]
            ),
            e1dDefinition(
                projects: [tree.workspaceURL.path],
                credentials: [.init(source: "a", destination: "b")]
            ),
            e1dDefinition(
                projects: [tree.workspaceURL.path],
                keychain: [.init(service: "s", account: "a", env: "E")]
            ),
        ] {
            let context = try e1dActiveContext(supervisor, definition: credentialed)
            let provider = E1DStubProvider("file")
            #expect(
                supervisor.prepareIdentityLaunch(
                    selection: e1dSelection(credentialed),
                    arguments: [], io: .discard,
                    host: host, generation: generation,
                    brokerCallerContext: context,
                    brokerProviders: [provider]
                ) == .failure(.credentialStagingNotSupported)
            )
            #expect(provider.healthCalls == 0)
            #expect(provider.resolveCalls.isEmpty)
        }
    }

    @Test func prepareStagingProbeFailureFailsPrepareClosed() throws {
        let tree = try ContainmentTree()
        let supervisor = try e1dSupervisor(tree)
        defer { _ = supervisor.close() }
        // An existing but non-executable link target passes every gate
        // before the probe, then fails the throwaway stage exactly as
        // the spawn-time stage would fail.
        let target = tree.rootURL.appendingPathComponent("e1d-not-executable")
        try "not-executable".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: target.path
        )
        let entry = e1dEntry(env: "E1D_FIRST")
        let ref = try #require(entry.ref)
        let definition = e1dDefinition(
            target: target.path,
            projects: [tree.workspaceURL.path], secrets: [entry]
        )
        let context = try e1dActiveContext(supervisor, definition: definition)
        let provider = E1DStubProvider("file") {
            $0.values = [ref: .text("synthetic-v1")]
        }
        let (host, generation) = e1dHost()
        #expect(
            supervisor.prepareIdentityLaunch(
                selection: e1dSelection(definition),
                arguments: [], io: .discard,
                host: host, generation: generation,
                brokerCallerContext: context,
                brokerProviders: [provider]
            ) == .failure(
                .preparationFailed(.resourceStagingFailed("executable link 'e1d-agent'"))
            )
        )
    }

    @Test func prepareAuditsDropsToLedgerWithoutValues() throws {
        let tree = try ContainmentTree()
        let supervisor = try e1dSupervisor(tree)
        defer { _ = supervisor.close() }
        let marker = "e1d-leakprobe-\(UUID().uuidString.lowercased())"
        let valid = e1dEntry(env: "E1D_FIRST")
        let invalid = e1dEntry(provider: "nope", env: "E1D_BAD")
        let validRef = try #require(valid.ref)
        #expect(invalid.ref == nil)
        let definition = e1dDefinition(
            projects: [tree.workspaceURL.path], secrets: [valid, invalid]
        )
        let context = try e1dActiveContext(supervisor, definition: definition)
        let provider = E1DStubProvider("file") {
            $0.values = [validRef: .text(marker)]
        }
        let auditDir = try e1dScratch(prefix: "rv-e1d-audit")
        defer { try? FileManager.default.removeItem(at: auditDir) }
        let (host, generation) = e1dHost()
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: e1dSelection(definition),
            arguments: [], io: .discard,
            host: host, generation: generation,
            brokerCallerContext: context,
            brokerProviders: [provider],
            secretsConfigDirectory: auditDir
        ).get()
        #expect(prepared.environment.entries.contains("E1D_FIRST=\(marker)"))
        #expect(prepared.environment.entries.contains(where: { $0.hasPrefix("E1D_BAD=") }) == false)
        let ledgerURL = auditDir.appendingPathComponent(
            "secrets-audit.jsonl", isDirectory: false
        )
        #expect(FileManager.default.fileExists(atPath: ledgerURL.path))
        let rows = SecretsLedger.loadRecords(fileURL: ledgerURL)
        guard let drop = rows.first(where: { $0.decision == .denied }) else {
            Issue.record("prepare-time drop must audit a denied row, got \(rows)")
            return
        }
        #expect(drop.kind == .secretResolve)
        #expect(drop.cause?.redacted == "stagingDrop:invalidRef:E1D_BAD")
        // Neither the injected value nor any drop-adjacent material may
        // appear in the ledger bytes.
        let ledgerText = try String(contentsOf: ledgerURL, encoding: .utf8)
        #expect(ledgerText.contains(marker) == false)
    }

    @Test func factoryBackedFreezeEndToEnd() throws {
        // Zero stubs: the E1-A factory builds real providers from the
        // config directory and the file provider resolves at prepare.
        let tree = try ContainmentTree()
        let supervisor = try e1dSupervisor(tree)
        defer { _ = supervisor.close() }
        let configDir = try e1dScratch(prefix: "rv-e1d-factory")
        defer { try? FileManager.default.removeItem(at: configDir) }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: configDir.path
        )
        let valuesURL = configDir.appendingPathComponent("secrets-file.json")
        try #"{"version":1,"items":{"github":{"text":"factory-frozen-1"}}}"#.write(
            to: valuesURL, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: valuesURL.path
        )
        let entry = e1dEntry(env: "E1D_FACTORY")
        let definition = e1dDefinition(
            projects: [tree.workspaceURL.path], secrets: [entry]
        )
        let context = try e1dActiveContext(supervisor, definition: definition)
        let (host, generation) = e1dHost()
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: e1dSelection(definition),
            arguments: [], io: .discard,
            host: host, generation: generation,
            brokerCallerContext: context,
            brokerProviders: nil,
            secretsConfigDirectory: configDir
        ).get()
        #expect(prepared.environment.entries.contains("E1D_FACTORY=factory-frozen-1"))
    }

    @Test func dispatchInjectsFrozenBrokerValuesWithoutReresolving() async throws {
        // Broker-bearing prepared launches dispatch: the frozen pairs
        // inject verbatim and dispatch never re-resolves (the provider
        // observes exactly the prepare-time call even though its values
        // changed before dispatch). Uses real /bin/sh in the cage.
        let tree = try ContainmentTree()
        let supervisor = try e1dSupervisor(tree)
        defer { _ = supervisor.close() }
        let outPath = tree.workspaceURL.appendingPathComponent("e1d-dispatch-out").path
        let entry = e1dEntry(env: "E1D_FIRST")
        let ref = try #require(entry.ref)
        let definition = e1dDefinition(
            target: "/bin/sh",
            projects: [tree.workspaceURL.path], secrets: [entry]
        )
        let context = try e1dActiveContext(supervisor, definition: definition)
        let provider = E1DStubProvider("file") {
            $0.values = [ref: .text("synthetic-v1")]
        }
        let (host, generation) = e1dHost()
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: e1dSelection(definition),
            arguments: ["-c", "printf %s \"$E1D_FIRST\" > " + outPath + "; sleep 30"],
            io: .discard,
            host: host, generation: generation,
            brokerCallerContext: context,
            brokerProviders: [provider]
        ).get()
        #expect(prepared.environment.entries.contains("E1D_FIRST=synthetic-v1"))
        #expect(provider.resolveCalls == [ref])
        provider.setValues([ref: .text("synthetic-v2")])
        let runtime = try supervisor.dispatchPreparedLaunch(
            prepared,
            sessionStore: .file(tree.rootURL.appendingPathComponent("e1d-dispatch-runtime.jsonl")),
            admission: .failClosed
        ).get()
        let deadline = Date().addingTimeInterval(10)
        while (try? String(contentsOfFile: outPath, encoding: .utf8)) == nil,
            Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let body = try String(contentsOfFile: outPath, encoding: .utf8)
        #expect(body == "synthetic-v1")
        #expect(provider.resolveCalls == [ref])
        try supervisor.cancel(runtime.id).get()
    }

    @Test func redemptionInjectsFrozenBrokerValuesWithoutReresolving() async throws {
        // The authorized path agrees: redemption of a broker-bearing
        // preparation launches, injects the frozen pairs, and never
        // re-resolves.
        let tree = try ContainmentTree()
        let supervisor = try e1dSupervisor(tree)
        defer { _ = supervisor.close() }
        let outPath = tree.workspaceURL.appendingPathComponent("e1d-redeem-out").path
        let entry = e1dEntry(env: "E1D_FIRST")
        let ref = try #require(entry.ref)
        let definition = e1dDefinition(
            target: "/bin/sh",
            projects: [tree.workspaceURL.path], secrets: [entry]
        )
        let context = try e1dActiveContext(supervisor, definition: definition)
        let provider = E1DStubProvider("file") {
            $0.values = [ref: .text("synthetic-v1")]
        }
        let (host, generation) = e1dHost()
        let prepared = try supervisor.prepareIdentityLaunch(
            selection: e1dSelection(definition),
            arguments: ["-c", "printf %s \"$E1D_FIRST\" > " + outPath + "; sleep 30"],
            io: .discard,
            host: host, generation: generation,
            brokerCallerContext: context,
            brokerProviders: [provider]
        ).get()
        #expect(provider.resolveCalls == [ref])
        provider.setValues([ref: .text("synthetic-v2")])
        let outcome = supervisor.redeemPreparedLaunch(
            commit: e1dCommit(prepared: prepared),
            sessionStore: .file(tree.rootURL.appendingPathComponent("e1d-redeem-runtime.jsonl")),
            admission: .failClosed
        )
        guard case .launched(let runtime, _) = outcome else {
            Issue.record("broker-bearing redemption must launch, got \(outcome)")
            return
        }
        let deadline = Date().addingTimeInterval(10)
        while (try? String(contentsOfFile: outPath, encoding: .utf8)) == nil,
            Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let body = try String(contentsOfFile: outPath, encoding: .utf8)
        #expect(body == "synthetic-v1")
        #expect(provider.resolveCalls == [ref])
        try supervisor.cancel(runtime).get()
    }
}

#endif
