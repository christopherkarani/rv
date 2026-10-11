#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVFileStore
import Synchronization
import Testing
@testable import RVIsolation
@testable import RVPolicy

// MARK: - Helpers

/// Scripted provider: records every call so tests prove what the broker
/// door did and did not touch.
private struct BrokerStubScript: Sendable {
    var healthOK = true
    var resolveError: SecretsError?
    var values: [SecretRef: SecretValue] = [:]
    var healthCalls = 0
    var resolveCalls: [SecretRef] = []
}

private final class BrokerStubState: Sendable {
    let mutex = Mutex(BrokerStubScript())
}

private struct BrokerStubProvider: SecretsProvider, Sendable {
    var id: String
    var state: BrokerStubState

    init(_ id: String, configure: (inout BrokerStubScript) -> Void = { _ in }) {
        self.id = id
        let state = BrokerStubState()
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
        let script = state.mutex.withLock { script -> BrokerStubScript in
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

private final class BrokerAuditCapture: Sendable {
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

private final class NormalizeCount: Sendable {
    private let box = Mutex(0)

    var count: Int { box.withLock { $0 } }

    func record() { box.withLock { $0 += 1 } }
}

private func brokerDefinition(
    bindings: [String] = [],
    credentials: [RuntimeResourceProfile.Credential] = [],
    keychain: [RuntimeResourceProfile.KeychainEntry] = [],
    secrets: [RuntimeResourceProfile.BrokerEntry] = []
) -> AgentDefinition {
    AgentDefinition(
        id: AgentDefinitionID(rawValue: "broker-admission"),
        displayName: "Broker admission",
        blurb: "",
        executableRequirement: ExecutableRequirement(allowsUnsigned: true),
        hookHost: .opencode,
        agentTag: "opencode",
        resourceProfile: RuntimeResourceProfile(
            id: "broker-admission",
            projects: ["/tmp/broker-project"],
            executableLinks: [.init(name: "broker-admission", target: "/bin/sleep")],
            credentials: credentials,
            keychain: keychain,
            secrets: secrets
        ),
        credentialBindings: bindings,
        requiredAssurance: .launchObserved,
        authorityCeiling: AgentAuthority(scopes: ["shell"])
    )
}

private func brokerSelection(
    _ definition: AgentDefinition,
    carriedProfile: RuntimeResourceProfile?
) -> ResolvedAgentLaunch {
    ResolvedAgentLaunch(
        resolved: ResolvedAgentDefinition(
            definition: definition,
            revision: AgentDefinitionRevision.resolve(definition)
        ),
        executable: "/bin/sleep",
        resourceProfile: carriedProfile
    )
}

private func brokerEntry(
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

private struct BrokerAdmissionHarness: Sendable {
    let root: URL
    let runtime: RuntimeSession
    let capability: RuntimeCapability
    let registry: AgentInstanceRegistry
    let instance: AgentInstance
    let normalized: NormalizeCount
    let session: RuntimeAdmissionSession

    init(bound: Bool) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-broker-admission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = try #require(WorkingDirectory(validating: root.path))
        let runtime = RuntimeSession(
            id: RuntimeSessionID(),
            workspaceSessionID: WorkspaceSessionID(),
            host: .opencode,
            workspace: workspace,
            backend: .seatbelt,
            startedAt: Date(),
            child: nil
        )
        let capability = RuntimeCapability()
        let normalized = NormalizeCount()
        let configuration = RuntimeAdmissionConfiguration(
            normalize: { _, _ in
                normalized.record()
                return .failure(.failed)
            },
            executor: .refuse,
            approval: { _, _ in nil },
            policy: { _ in .empty },
            evidence: RuntimeAdmissionEvidence()
        )
        let definition = brokerDefinition()
        let registry = AgentInstanceRegistry(
            journal: .file(root.appendingPathComponent("agent-instances.jsonl")))
        let instance = AgentInstance(
            id: AgentInstanceID(),
            owner: OwnerPrincipal(uid: 501),
            definitionID: definition.id,
            definitionRevision: AgentDefinitionRevision.resolve(definition),
            workspaceSessionID: runtime.workspaceSessionID,
            runtimeSessionID: runtime.id,
            executableEvidence: .none,
            assurance: .launchObserved,
            groupLeader: RuntimeChildIdentity(pid: 100),
            workloadProcess: nil,
            parent: nil,
            effectiveAuthority: definition.authorityCeiling,
            delegableAuthority: definition.authorityCeiling,
            mintedAt: Date()
        )
        let session = RuntimeAdmissionSession(
            binding: RuntimeChannelBinding(session: runtime, capability: capability),
            configuration: configuration,
            launch: AdmittedLaunchContext(
                plan: compileContainedPlan(workspace: workspace),
                profileSource: "(deny file-link)",
                workspacePath: workspace.rawValue
            ),
            requestRead: -1,
            responseWrite: -1
        )
        if bound {
            guard registry.announce(instance) else { throw BrokerHarnessError.announceFailed }
            guard let established = EstablishedRuntimeSession(
                session: runtime, instance: instance, establishedAt: Date()),
                registry.activate(established) != nil
            else {
                throw BrokerHarnessError.activateFailed
            }
            guard session.bindAgentInstance(instance.id, registry: registry) else {
                throw BrokerHarnessError.bindFailed
            }
        }
        self.root = root
        self.runtime = runtime
        self.capability = capability
        self.registry = registry
        self.instance = instance
        self.normalized = normalized
        self.session = session
    }

    func frame(_ command: String, id: UUID = UUID()) -> RuntimeActionFrame {
        RuntimeActionFrame(
            version: 1,
            requestID: RuntimeActionRequestID(validating: id.uuidString)!,
            capability: capability,
            claimedSession: RuntimeSessionClaim(validating: runtime.id.rawValue.uuidString)!,
            action: .shell(ShellCommand(rawValue: command))
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum BrokerHarnessError: Error {
    case announceFailed
    case activateFailed
    case bindFailed
}

private func brokerTempRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-broker-stage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeOwnerOnly(_ text: String, name: String, root: URL) throws -> URL {
    let url = root.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return url
}

private func posixPermissions(_ path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return try #require(attributes[.posixPermissions] as? Int) & 0o777
}

// MARK: - Credential gate

/// T5 lift: the legacy predicate stays credential-free (broker entries
/// rejected), while the identity predicate admits broker-bound entries.
@Suite("Broker admission credential gate")
struct BrokerAdmissionGateTests {
    @Test func legacyAdmitsFullyCredentialFreeSelection() {
        let definition = brokerDefinition()
        #expect(isCredentialFreeSelection(brokerSelection(definition, carriedProfile: definition.resourceProfile)))
        #expect(isCredentialFreeSelection(brokerSelection(definition, carriedProfile: nil)))
    }

    @Test func legacyRejectsCredentialBindings() {
        let definition = brokerDefinition(bindings: ["github-token"])
        #expect(isCredentialFreeSelection(brokerSelection(definition, carriedProfile: definition.resourceProfile)) == false)
    }

    @Test func legacyRejectsDefinitionCredentials() {
        let definition = brokerDefinition(credentials: [.init(source: "a", destination: "b")])
        #expect(isCredentialFreeSelection(brokerSelection(definition, carriedProfile: definition.resourceProfile)) == false)
    }

    @Test func legacyRejectsDefinitionKeychain() {
        let definition = brokerDefinition(keychain: [.init(service: "s", account: "a", env: "SYNTHETIC_FIRST")])
        #expect(isCredentialFreeSelection(brokerSelection(definition, carriedProfile: definition.resourceProfile)) == false)
    }

    @Test func legacyRejectsDefinitionBrokerEntries() {
        let definition = brokerDefinition(secrets: [brokerEntry(env: "SYNTHETIC_FIRST")])
        #expect(isCredentialFreeSelection(brokerSelection(definition, carriedProfile: definition.resourceProfile)) == false)
    }

    @Test func legacyRejectsCarriedProfileShapes() {
        let clean = brokerDefinition()
        let credentialed = brokerDefinition(credentials: [.init(source: "a", destination: "b")])
        let keyed = brokerDefinition(keychain: [.init(service: "s", account: "a", env: "SYNTHETIC_FIRST")])
        let brokered = brokerDefinition(secrets: [brokerEntry(env: "SYNTHETIC_FIRST")])
        for carried in [credentialed.resourceProfile, keyed.resourceProfile, brokered.resourceProfile] {
            #expect(isCredentialFreeSelection(brokerSelection(clean, carriedProfile: carried)) == false)
        }
    }

    @Test func legacyMatchesPreBrokerRuleOnLegacyShapes() {
        // Byte-identical legacy behavior: with no broker entries anywhere,
        // the predicate equals the pre-T5 rule exactly.
        for bindings in [[], ["b"]] as [[String]] {
            for shape in 0..<4 {
                let definition = brokerDefinition(
                    bindings: bindings,
                    credentials: shape & 1 == 0 ? [] : [.init(source: "a", destination: "b")],
                    keychain: shape & 2 == 0 ? [] : [.init(service: "s", account: "a", env: "SYNTHETIC_FIRST")]
                )
                for carried in [definition.resourceProfile, brokerDefinition().resourceProfile] as [RuntimeResourceProfile?] + [nil] {
                    let expected = bindings.isEmpty
                        && definition.resourceProfile.credentials.isEmpty
                        && definition.resourceProfile.keychain.isEmpty
                        && (carried?.credentials.isEmpty ?? true)
                        && (carried?.keychain.isEmpty ?? true)
                    #expect(isCredentialFreeSelection(brokerSelection(definition, carriedProfile: carried)) == expected)
                }
            }
        }
    }

    @Test func identityAdmitsFullyCredentialFreeSelection() {
        let definition = brokerDefinition()
        #expect(isIdentityAdmissibleSelection(brokerSelection(definition, carriedProfile: definition.resourceProfile)))
        #expect(isIdentityAdmissibleSelection(brokerSelection(definition, carriedProfile: nil)))
    }

    @Test func identityAdmitsDefinitionBrokerEntries() {
        let definition = brokerDefinition(secrets: [
            brokerEntry(env: "SYNTHETIC_FIRST"),
            brokerEntry(provider: "keychain", item: "svc", field: "f", env: "SYNTHETIC_SECOND", agents: ["opencode"]),
        ])
        #expect(isIdentityAdmissibleSelection(brokerSelection(definition, carriedProfile: definition.resourceProfile)))
    }

    @Test func identityAdmitsCarriedProfileBrokerEntries() {
        let clean = brokerDefinition()
        let brokered = brokerDefinition(secrets: [brokerEntry(env: "SYNTHETIC_FIRST")])
        #expect(isIdentityAdmissibleSelection(brokerSelection(clean, carriedProfile: brokered.resourceProfile)))
    }

    @Test func identityRejectsLegacyCredentialShapes() {
        let bound = brokerDefinition(bindings: ["t"])
        let credentialed = brokerDefinition(credentials: [.init(source: "a", destination: "b")])
        let keyed = brokerDefinition(keychain: [.init(service: "s", account: "a", env: "SYNTHETIC_FIRST")])
        for definition in [bound, credentialed, keyed] {
            #expect(isIdentityAdmissibleSelection(brokerSelection(definition, carriedProfile: definition.resourceProfile)) == false)
        }
        let clean = brokerDefinition()
        // Bindings live on the definition, never on a carried profile,
        // so only profile-level shapes vary here.
        for carried in [credentialed.resourceProfile, keyed.resourceProfile] {
            #expect(isIdentityAdmissibleSelection(brokerSelection(clean, carriedProfile: carried)) == false)
        }
    }

    @Test func identityAdmitsBrokerEntriesAlongsideNeitherLegacyShape() {
        // Broker entries plus legacy credentials stay rejected: admission
        // is broker-only, never a downgrade that smuggles legacy shapes.
        let mixed = brokerDefinition(
            credentials: [.init(source: "a", destination: "b")],
            secrets: [brokerEntry(env: "SYNTHETIC_FIRST")]
        )
        #expect(isIdentityAdmissibleSelection(brokerSelection(mixed, carriedProfile: mixed.resourceProfile)) == false)
        #expect(isCredentialFreeSelection(brokerSelection(mixed, carriedProfile: mixed.resourceProfile)) == false)
    }
}

// MARK: - Entry selection

/// `RuntimeAdmissionGate.admittedBrokerEntries`: pure resolve-side
/// selection shared by the preparation path and staging.
@Suite("Broker admission entry selection")
struct BrokerAdmissionSelectionTests {
    @Test func unfilteredEntriesAdmitForNilAndNamedAgent() throws {
        let entries = [brokerEntry(env: "SYNTHETIC_FIRST"), brokerEntry(item: "npm", env: "SYNTHETIC_SECOND")]
        for agent in [nil, "opencode", "codex"] as [String?] {
            let admitted = RuntimeAdmissionGate.admittedBrokerEntries(entries: entries, agent: agent)
            #expect(admitted.map(\.entry.env) == ["SYNTHETIC_FIRST", "SYNTHETIC_SECOND"])
            #expect(admitted.map(\.ref.item) == ["github", "npm"])
        }
    }

    @Test func filteredEntriesMatchTagOnly() {
        let entries = [brokerEntry(env: "SYNTHETIC_FIRST", agents: ["opencode"])]
        #expect(RuntimeAdmissionGate.admittedBrokerEntries(entries: entries, agent: "opencode").count == 1)
        #expect(RuntimeAdmissionGate.admittedBrokerEntries(entries: entries, agent: "codex").isEmpty)
        #expect(RuntimeAdmissionGate.admittedBrokerEntries(entries: entries, agent: nil).isEmpty)
    }

    @Test func invalidRefEntriesAreSkipped() {
        let entries = [
            brokerEntry(provider: "nope", env: "SYNTHETIC_FIRST"),
            brokerEntry(provider: "", env: "SYNTHETIC_SECOND"),
            brokerEntry(item: "", env: "SYNTHETIC_THIRD"),
            brokerEntry(env: "SYNTHETIC_FOURTH"),
        ]
        let admitted = RuntimeAdmissionGate.admittedBrokerEntries(entries: entries, agent: nil)
        #expect(admitted.map(\.entry.env) == ["SYNTHETIC_FOURTH"])
    }

    @Test func emptyAgentsFilterMatchesAll() {
        let entries = [brokerEntry(env: "SYNTHETIC_FIRST", agents: [])]
        #expect(entries[0].agents == nil)
        #expect(RuntimeAdmissionGate.admittedBrokerEntries(entries: entries, agent: nil).count == 1)
        #expect(RuntimeAdmissionGate.admittedBrokerEntries(entries: entries, agent: "opencode").count == 1)
    }

    @Test func orderPreserved() {
        let entries = [
            brokerEntry(item: "c", env: "SYNTHETIC_THIRD"),
            brokerEntry(item: "a", env: "SYNTHETIC_FIRST"),
            brokerEntry(item: "b", env: "SYNTHETIC_SECOND"),
        ]
        let admitted = RuntimeAdmissionGate.admittedBrokerEntries(entries: entries, agent: nil)
        #expect(admitted.map(\.ref.item) == ["c", "a", "b"])
    }
}

// MARK: - Identity door

/// Session `submitIdentityRequired` broker overload: fresh-context
/// resolution with a principal gate before any provider is touched.
@Suite("Broker admission identity door")
struct BrokerAdmissionIdentityTests {
    @Test func unboundChannelThrowsWithoutTouchingBroker() async throws {
        let harness = try BrokerAdmissionHarness(bound: false)
        defer { harness.cleanup() }
        let provider = BrokerStubProvider("file")
        let audit = BrokerAuditCapture()
        let broker = SecretBroker(
            providers: [provider], audit: audit.sink, liveness: .usableOnly
        )
        let ref = try SecretRef(provider: "file", item: "github")
        await #expect(throws: SecretsError.identityRequired) {
            try await harness.session.submitIdentityRequired([ref], broker: broker)
        }
        #expect(provider.healthCalls == 0)
        #expect(provider.resolveCalls.isEmpty)
        #expect(audit.events.isEmpty)
        #expect(harness.normalized.count == 0)
    }

    @Test func unknownInstanceThrowsWithoutTouchingBroker() async throws {
        let harness = try BrokerAdmissionHarness(bound: false)
        defer { harness.cleanup() }
        #expect(harness.session.bindAgentInstance(AgentInstanceID(), registry: harness.registry))
        let provider = BrokerStubProvider("file")
        let audit = BrokerAuditCapture()
        let broker = SecretBroker(
            providers: [provider], audit: audit.sink, liveness: .usableOnly
        )
        let ref = try SecretRef(provider: "file", item: "github")
        await #expect(throws: SecretsError.identityRequired) {
            try await harness.session.submitIdentityRequired([ref], broker: broker)
        }
        #expect(provider.healthCalls == 0)
        #expect(provider.resolveCalls.isEmpty)
        #expect(audit.events.isEmpty)
    }

    @Test func boundActivePrincipalResolvesEndToEnd() async throws {
        let harness = try BrokerAdmissionHarness(bound: true)
        defer { harness.cleanup() }
        let first = try SecretRef(provider: "file", item: "github")
        let second = try SecretRef(provider: "file", item: "npm", field: "f")
        let provider = BrokerStubProvider("file") {
            $0.values = [first: .text("synthetic-first"), second: .text("synthetic-second")]
        }
        let audit = BrokerAuditCapture()
        let broker = SecretBroker(
            providers: [provider], audit: audit.sink, liveness: .usableOnly
        )
        let resolved = try await harness.session.submitIdentityRequired([first, second], broker: broker)
        #expect(resolved == [first: .text("synthetic-first"), second: .text("synthetic-second")])
        #expect(provider.healthCalls == 1)
        #expect(provider.resolveCalls == [first, second])
        #expect(harness.normalized.count == 0)
        let events = audit.events
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.decision == .resolved && $0.cause == nil })
        #expect(events.allSatisfy { $0.principal.instanceID == harness.instance.id })
        #expect(events.allSatisfy { $0.principal.definitionID == "broker-admission" })
    }

    @Test func revokedPrincipalDeniedByBrokerWithoutProviderContact() async throws {
        let harness = try BrokerAdmissionHarness(bound: true)
        defer { harness.cleanup() }
        #expect(harness.registry.revoke(harness.instance.id, reason: .explicitRevoke) { true } == .revoked)
        let provider = BrokerStubProvider("file")
        let audit = BrokerAuditCapture()
        let broker = SecretBroker(
            providers: [provider], audit: audit.sink, liveness: .usableOnly
        )
        let ref = try SecretRef(provider: "file", item: "github")
        await #expect(throws: SecretsError.identityRequired) {
            try await harness.session.submitIdentityRequired([ref], broker: broker)
        }
        #expect(provider.healthCalls == 0)
        #expect(provider.resolveCalls.isEmpty)
        let events = audit.events
        #expect(events.count == 1)
        #expect(events.first?.decision == .denied)
        #expect(events.first?.cause?.redacted == "identityRequired")
    }

    @Test func revocationBetweenCallsTakesEffect() async throws {
        let harness = try BrokerAdmissionHarness(bound: true)
        defer { harness.cleanup() }
        let ref = try SecretRef(provider: "file", item: "github")
        let provider = BrokerStubProvider("file") {
            $0.values = [ref: .text("synthetic-first")]
        }
        let broker = SecretBroker(
            providers: [provider], audit: BrokerAuditCapture().sink, liveness: .usableOnly
        )
        let resolved = try await harness.session.submitIdentityRequired([ref], broker: broker)
        #expect(resolved == [ref: .text("synthetic-first")])
        #expect(harness.registry.revoke(harness.instance.id, reason: .explicitRevoke) { true } == .revoked)
        await #expect(throws: SecretsError.identityRequired) {
            try await harness.session.submitIdentityRequired([ref], broker: broker)
        }
        #expect(provider.resolveCalls == [ref])
    }

    @Test func emptyRefsReturnEmptyWithoutProviderContact() async throws {
        let harness = try BrokerAdmissionHarness(bound: true)
        defer { harness.cleanup() }
        let provider = BrokerStubProvider("file")
        let audit = BrokerAuditCapture()
        let broker = SecretBroker(
            providers: [provider], audit: audit.sink, liveness: .usableOnly
        )
        let resolved = try await harness.session.submitIdentityRequired([], broker: broker)
        #expect(resolved.isEmpty)
        #expect(provider.healthCalls == 0)
        #expect(provider.resolveCalls.isEmpty)
        #expect(audit.events.isEmpty)
    }

    @Test func brokerErrorsPropagateUnmasked() async throws {
        let harness = try BrokerAdmissionHarness(bound: true)
        defer { harness.cleanup() }
        let provider = BrokerStubProvider("file") { $0.resolveError = .notFound("intruder") }
        let broker = SecretBroker(
            providers: [provider], audit: BrokerAuditCapture().sink, liveness: .usableOnly
        )
        let ref = try SecretRef(provider: "file", item: "github")
        // The broker re-tags provider-thrown errors to the throwing
        // provider; the door passes the broker outcome through as-is.
        await #expect(throws: SecretsError.notFound("file")) {
            try await harness.session.submitIdentityRequired([ref], broker: broker)
        }
        #expect(provider.resolveCalls == [ref])
    }

    @Test func legacyFrameDoorUnaffectedOnSameSession() async throws {
        // The legacy frame door still authenticates a principal-less
        // channel (proposal attempted, never principal-gated) while the
        // broker door on the same session throws identity-required.
        let harness = try BrokerAdmissionHarness(bound: false)
        defer { harness.cleanup() }
        let decision = harness.session.submitLegacy(.success(harness.frame("touch marker")))
        #expect(decision.response == .evaluationFailed)
        #expect(harness.normalized.count == 1)
        let broker = SecretBroker(
            providers: [BrokerStubProvider("file")],
            audit: BrokerAuditCapture().sink,
            liveness: .usableOnly
        )
        let ref = try SecretRef(provider: "file", item: "github")
        await #expect(throws: SecretsError.identityRequired) {
            try await harness.session.submitIdentityRequired([ref], broker: broker)
        }
    }

    @Test func frameDoorsIntactOnBoundSession() throws {
        // Bound session, frame doors intact: the identity frame door
        // still mediates (proposal attempted) and the legacy frame door
        // is unchanged. The broker door is additive only.
        let harness = try BrokerAdmissionHarness(bound: true)
        defer { harness.cleanup() }
        let identity = harness.session.submitIdentityRequired(.success(harness.frame("touch marker")))
        #expect(identity.response == .evaluationFailed)
        #expect(harness.normalized.count == 1)
        let legacy = harness.session.submitLegacy(.success(harness.frame("touch marker", id: UUID())))
        #expect(legacy.response == .evaluationFailed)
        #expect(harness.normalized.count == 2)
    }

    @Test func fullChainResolvesThenStages() async throws {
        let harness = try BrokerAdmissionHarness(bound: true)
        defer { harness.cleanup() }
        let entries = [
            brokerEntry(env: "SYNTHETIC_FIRST"),
            brokerEntry(item: "npm", env: "SYNTHETIC_SECOND"),
        ]
        let profile = RuntimeResourceProfile(
            id: "broker-chain", projects: ["/tmp/broker-project"], secrets: entries
        )
        let admitted = RuntimeAdmissionGate.admittedBrokerEntries(entries: entries, agent: "opencode")
        let refs = admitted.map(\.ref)
        #expect(refs.count == 2)
        let provider = BrokerStubProvider("file") {
            $0.values = [
                refs[0]: .text("synthetic-first"),
                refs[1]: .text("synthetic-second"),
            ]
        }
        let broker = SecretBroker(
            providers: [provider], audit: BrokerAuditCapture().sink, liveness: .usableOnly
        )
        let values = try await harness.session.submitIdentityRequired(refs, broker: broker)
        let manifest = RuntimeResourceManifest(profile)
        defer { manifest.remove() }
        let drops = Mutex<[BrokerStagingDrop]>([])
        let staged = manifest.stage(
            forAgent: "opencode", brokerValues: values,
            brokerAudit: { drop in drops.withLock { $0.append(drop) } }
        )
        guard case .success(let pairs) = staged else {
            Issue.record("chained staging must succeed, got \(staged)")
            return
        }
        #expect(pairs.map(\.name) == ["SYNTHETIC_FIRST", "SYNTHETIC_SECOND"])
        #expect(pairs.map(\.value) == ["synthetic-first", "synthetic-second"])
        #expect(drops.withLock { $0.isEmpty })
    }
}

// MARK: - Staging

private func stageBrokerForTest(
    _ profile: RuntimeResourceProfile,
    agent: String? = nil,
    values: [SecretRef: SecretValue]?
) -> (
    manifest: RuntimeResourceManifest,
    result: Result<[(name: String, value: String)], ResourceStagingError>,
    drops: [BrokerStagingDrop]
) {
    let manifest = RuntimeResourceManifest(profile)
    let box = Mutex<[BrokerStagingDrop]>([])
    let result = manifest.stage(
        forAgent: agent, brokerValues: values,
        brokerAudit: { drop in box.withLock { $0.append(drop) } }
    )
    return (manifest, result, box.withLock { $0 })
}

private func brokerProfile(
    secrets: [RuntimeResourceProfile.BrokerEntry],
    credentials: [RuntimeResourceProfile.Credential] = []
) -> RuntimeResourceProfile {
    RuntimeResourceProfile(
        id: "broker-stage", projects: ["/tmp/broker-project"],
        credentials: credentials, secrets: secrets
    )
}

/// `RuntimeResourceManifest.stage` broker mediation: 0700 file staging
/// plus at-most-8KB env injection with per-variable audited drops.
@Suite("Broker admission staging")
struct BrokerAdmissionStagingTests {
    @Test func nilBrokerValuesIgnoresSecretsEntries() {
        let profile = brokerProfile(secrets: [brokerEntry(env: "SYNTHETIC_FIRST")])
        let staged = stageBrokerForTest(profile, values: nil)
        defer { staged.manifest.remove() }
        guard case .success(let pairs) = staged.result else {
            Issue.record("legacy staging must succeed, got \(staged.result)")
            return
        }
        #expect(pairs.isEmpty)
        #expect(staged.drops.isEmpty)
        #expect(FileManager.default.fileExists(atPath: staged.manifest.privateHome + "/secrets") == false)
    }

    @Test func textValuesInjectInOrder() throws {
        let entries = [
            brokerEntry(item: "c", env: "SYNTHETIC_THIRD"),
            brokerEntry(item: "a", env: "SYNTHETIC_FIRST"),
        ]
        let first = try #require(entries[0].ref)
        let second = try #require(entries[1].ref)
        let staged = stageBrokerForTest(
            brokerProfile(secrets: entries),
            values: [first: .text("synthetic-c"), second: .text("synthetic-a")]
        )
        defer { staged.manifest.remove() }
        guard case .success(let pairs) = staged.result else {
            Issue.record("broker staging must succeed, got \(staged.result)")
            return
        }
        #expect(pairs.map(\.name) == ["SYNTHETIC_THIRD", "SYNTHETIC_FIRST"])
        #expect(pairs.map(\.value) == ["synthetic-c", "synthetic-a"])
        #expect(staged.drops.isEmpty)
    }

    @Test func sizeBoundaryCountsBytes() throws {
        let entries = [
            brokerEntry(item: "exact", env: "SYNTHETIC_EXACT"),
            brokerEntry(item: "over", env: "SYNTHETIC_OVER"),
            brokerEntry(item: "wide-exact", env: "SYNTHETIC_WIDE"),
            brokerEntry(item: "wide-over", env: "SYNTHETIC_WIDE_OVER"),
        ]
        let refs = try entries.map { try #require($0.ref) }
        let staged = stageBrokerForTest(
            brokerProfile(secrets: entries),
            values: [
                refs[0]: .text(String(repeating: "v", count: 8_192)),
                refs[1]: .text(String(repeating: "v", count: 8_193)),
                refs[2]: .text(String(repeating: "é", count: 4_096)),
                refs[3]: .text(String(repeating: "é", count: 4_097)),
            ]
        )
        defer { staged.manifest.remove() }
        guard case .success(let pairs) = staged.result else {
            Issue.record("broker staging must succeed, got \(staged.result)")
            return
        }
        #expect(pairs.map(\.name) == ["SYNTHETIC_EXACT", "SYNTHETIC_WIDE"])
        #expect(staged.drops == [
            BrokerStagingDrop(env: "SYNTHETIC_OVER", reason: .oversized),
            BrokerStagingDrop(env: "SYNTHETIC_WIDE_OVER", reason: .oversized),
        ])
    }

    @Test func oversizedDropKeepsBatch() throws {
        let entries = [
            brokerEntry(item: "a", env: "SYNTHETIC_FIRST"),
            brokerEntry(item: "big", env: "SYNTHETIC_BIG"),
            brokerEntry(item: "b", env: "SYNTHETIC_SECOND"),
        ]
        let refs = try entries.map { try #require($0.ref) }
        let staged = stageBrokerForTest(
            brokerProfile(secrets: entries),
            values: [
                refs[0]: .text("synthetic-a"),
                refs[1]: .text(String(repeating: "v", count: 1_000_000)),
                refs[2]: .text("synthetic-b"),
            ]
        )
        defer { staged.manifest.remove() }
        guard case .success(let pairs) = staged.result else {
            Issue.record("broker staging must succeed, got \(staged.result)")
            return
        }
        #expect(pairs.map(\.name) == ["SYNTHETIC_FIRST", "SYNTHETIC_SECOND"])
        #expect(staged.drops == [BrokerStagingDrop(env: "SYNTHETIC_BIG", reason: .oversized)])
    }

    @Test func agentFilterSkipsSilently() throws {
        let entries = [
            brokerEntry(item: "match", env: "SYNTHETIC_FIRST", agents: ["opencode"]),
            brokerEntry(item: "miss", env: "SYNTHETIC_SECOND", agents: ["codex"]),
        ]
        let refs = try entries.map { try #require($0.ref) }
        let values = [refs[0]: SecretValue.text("synthetic-a"), refs[1]: .text("synthetic-b")]
        let matched = stageBrokerForTest(brokerProfile(secrets: entries), agent: "opencode", values: values)
        defer { matched.manifest.remove() }
        guard case .success(let pairs) = matched.result else {
            Issue.record("broker staging must succeed, got \(matched.result)")
            return
        }
        #expect(pairs.map(\.name) == ["SYNTHETIC_FIRST"])
        #expect(matched.drops.isEmpty)
        let untagged = stageBrokerForTest(brokerProfile(secrets: entries), values: values)
        defer { untagged.manifest.remove() }
        guard case .success(let untaggedPairs) = untagged.result else {
            Issue.record("broker staging must succeed, got \(untagged.result)")
            return
        }
        #expect(untaggedPairs.isEmpty)
        #expect(untagged.drops.isEmpty)
    }

    @Test func invalidNamesDrop() throws {
        let entries = [
            brokerEntry(item: "e", env: ""),
            brokerEntry(item: "d", env: "9BAD"),
            brokerEntry(item: "s", env: "HAS SPACE"),
            brokerEntry(item: "l", env: String(repeating: "A", count: 129)),
            brokerEntry(item: "ok", env: "SYNTHETIC_FIRST"),
        ]
        let refs = try entries.map { try #require($0.ref) }
        var values: [SecretRef: SecretValue] = [:]
        for (index, ref) in refs.enumerated() {
            values[ref] = .text("synthetic-\(index)")
        }
        let staged = stageBrokerForTest(brokerProfile(secrets: entries), values: values)
        defer { staged.manifest.remove() }
        guard case .success(let pairs) = staged.result else {
            Issue.record("broker staging must succeed, got \(staged.result)")
            return
        }
        #expect(pairs.map(\.name) == ["SYNTHETIC_FIRST"])
        #expect(staged.drops == [
            BrokerStagingDrop(env: "", reason: .invalidName),
            BrokerStagingDrop(env: "9BAD", reason: .invalidName),
            BrokerStagingDrop(env: "HAS SPACE", reason: .invalidName),
            BrokerStagingDrop(env: String(repeating: "A", count: 129), reason: .invalidName),
        ])
    }

    @Test func blockedNamesDrop() throws {
        let entries = [
            brokerEntry(item: "managed", env: "PATH"),
            brokerEntry(item: "exact", env: "LD_PRELOAD"),
            brokerEntry(item: "token", env: "SYNTHETIC_TOKEN"),
            brokerEntry(item: "prefix", env: "DYLD_INSERT_LIBRARIES"),
            brokerEntry(item: "ok", env: "SYNTHETIC_FIRST"),
        ]
        let refs = try entries.map { try #require($0.ref) }
        var values: [SecretRef: SecretValue] = [:]
        for (index, ref) in refs.enumerated() {
            values[ref] = .text("synthetic-\(index)")
        }
        let staged = stageBrokerForTest(brokerProfile(secrets: entries), values: values)
        defer { staged.manifest.remove() }
        guard case .success(let pairs) = staged.result else {
            Issue.record("broker staging must succeed, got \(staged.result)")
            return
        }
        #expect(pairs.map(\.name) == ["SYNTHETIC_FIRST"])
        #expect(staged.drops == [
            BrokerStagingDrop(env: "PATH", reason: .blockedName),
            BrokerStagingDrop(env: "LD_PRELOAD", reason: .blockedName),
            BrokerStagingDrop(env: "SYNTHETIC_TOKEN", reason: .blockedName),
            BrokerStagingDrop(env: "DYLD_INSERT_LIBRARIES", reason: .blockedName),
        ])
    }

    @Test func nulDropsWhileNewlineInjects() throws {
        let entries = [
            brokerEntry(item: "nul", env: "SYNTHETIC_NUL"),
            brokerEntry(item: "pem", env: "SYNTHETIC_DOC"),
        ]
        let refs = try entries.map { try #require($0.ref) }
        let staged = stageBrokerForTest(
            brokerProfile(secrets: entries),
            values: [
                refs[0]: .text("synthetic\0nul"),
                refs[1]: .text("line-one\nline-two\n"),
            ]
        )
        defer { staged.manifest.remove() }
        guard case .success(let pairs) = staged.result else {
            Issue.record("broker staging must succeed, got \(staged.result)")
            return
        }
        #expect(pairs.map(\.name) == ["SYNTHETIC_DOC"])
        #expect(pairs.first?.value == "line-one\nline-two\n")
        #expect(staged.drops == [BrokerStagingDrop(env: "SYNTHETIC_NUL", reason: .invalidValue)])
    }

    @Test func invalidRefAndUnresolvedDrop() throws {
        let entries = [
            brokerEntry(provider: "nope", item: "x", env: "SYNTHETIC_BADREF"),
            brokerEntry(item: "missing", env: "SYNTHETIC_MISSING"),
            brokerEntry(item: "present", env: "SYNTHETIC_FIRST"),
        ]
        let present = try #require(entries[2].ref)
        let staged = stageBrokerForTest(
            brokerProfile(secrets: entries),
            values: [present: .text("synthetic-a")]
        )
        defer { staged.manifest.remove() }
        guard case .success(let pairs) = staged.result else {
            Issue.record("broker staging must succeed, got \(staged.result)")
            return
        }
        #expect(pairs.map(\.name) == ["SYNTHETIC_FIRST"])
        #expect(staged.drops == [
            BrokerStagingDrop(env: "SYNTHETIC_BADREF", reason: .invalidRef),
            BrokerStagingDrop(env: "SYNTHETIC_MISSING", reason: .unresolved),
        ])
    }

    @Test func fileValueStagesTo0700Home() throws {
        let root = try brokerTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writeOwnerOnly("synthetic-file-payload", name: "source.doc", root: root)
        let entries = [brokerEntry(item: "doc", env: "SYNTHETIC_DOC")]
        let ref = try #require(entries[0].ref)
        let staged = stageBrokerForTest(
            brokerProfile(secrets: entries),
            values: [ref: .filePath(source.path)]
        )
        defer { staged.manifest.remove() }
        guard case .success(let pairs) = staged.result else {
            Issue.record("broker staging must succeed, got \(staged.result)")
            return
        }
        let expected = staged.manifest.privateHome + "/secrets/SYNTHETIC_DOC"
        #expect(pairs.map(\.name) == ["SYNTHETIC_DOC"])
        #expect(pairs.first?.value == expected)
        #expect(try String(contentsOfFile: expected, encoding: .utf8) == "synthetic-file-payload")
        #expect(staged.drops.isEmpty)
        #expect(try String(contentsOf: source, encoding: .utf8) == "synthetic-file-payload")
    }

    @Test func unreadableFileValuesDrop() throws {
        let root = try brokerTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writeOwnerOnly("synthetic-file-payload", name: "source.doc", root: root)
        let alias = root.appendingPathComponent("alias.doc")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let entries = [
            brokerEntry(item: "absent", env: "SYNTHETIC_ABSENT"),
            brokerEntry(item: "alias", env: "SYNTHETIC_ALIAS"),
            brokerEntry(item: "ok", env: "SYNTHETIC_FIRST"),
        ]
        let refs = try entries.map { try #require($0.ref) }
        let staged = stageBrokerForTest(
            brokerProfile(secrets: entries),
            values: [
                refs[0]: .filePath(root.appendingPathComponent("absent.doc").path),
                refs[1]: .filePath(alias.path),
                refs[2]: .text("synthetic-a"),
            ]
        )
        defer { staged.manifest.remove() }
        guard case .success(let pairs) = staged.result else {
            Issue.record("broker staging must succeed, got \(staged.result)")
            return
        }
        #expect(pairs.map(\.name) == ["SYNTHETIC_FIRST"])
        #expect(staged.drops == [
            BrokerStagingDrop(env: "SYNTHETIC_ABSENT", reason: .fileUnreadable),
            BrokerStagingDrop(env: "SYNTHETIC_ALIAS", reason: .fileUnreadable),
        ])
    }

    @Test func legacyFailureRemovesHomeIncludingBrokerFiles() throws {
        let root = try brokerTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writeOwnerOnly("synthetic-file-payload", name: "source.doc", root: root)
        let entries = [brokerEntry(item: "doc", env: "SYNTHETIC_DOC")]
        let ref = try #require(entries[0].ref)
        let profile = brokerProfile(
            secrets: entries,
            credentials: [.init(source: root.appendingPathComponent("absent").path, destination: "auth")]
        )
        let staged = stageBrokerForTest(profile, values: [ref: .filePath(source.path)])
        defer { staged.manifest.remove() }
        guard case .failure(let error) = staged.result else {
            Issue.record("broken credential must fail staging, got \(staged.result)")
            return
        }
        #expect(error == .credential(destination: "auth"))
        #expect(FileManager.default.fileExists(atPath: staged.manifest.privateHome) == false)
    }

    @Test func emptyMapDropsAllSelected() throws {
        let entries = [
            brokerEntry(item: "a", env: "SYNTHETIC_FIRST"),
            brokerEntry(item: "b", env: "SYNTHETIC_SECOND"),
        ]
        let staged = stageBrokerForTest(brokerProfile(secrets: entries), values: [:])
        defer { staged.manifest.remove() }
        guard case .success(let pairs) = staged.result else {
            Issue.record("broker staging must succeed, got \(staged.result)")
            return
        }
        #expect(pairs.isEmpty)
        #expect(staged.drops == [
            BrokerStagingDrop(env: "SYNTHETIC_FIRST", reason: .unresolved),
            BrokerStagingDrop(env: "SYNTHETIC_SECOND", reason: .unresolved),
        ])
    }

    @Test func defaultBrokerAuditDropsSilently() throws {
        let entries = [brokerEntry(item: "a", env: "SYNTHETIC_FIRST")]
        let manifest = RuntimeResourceManifest(brokerProfile(secrets: entries))
        defer { manifest.remove() }
        guard case .success(let pairs) = manifest.stage(brokerValues: [:]) else {
            Issue.record("broker staging must succeed without an explicit audit closure")
            return
        }
        #expect(pairs.isEmpty)
    }

    @Test func duplicateEnvAppendsInOrder() throws {
        let entries = [
            brokerEntry(item: "a", env: "SYNTHETIC_DUP"),
            brokerEntry(item: "b", env: "SYNTHETIC_DUP"),
        ]
        let refs = try entries.map { try #require($0.ref) }
        let staged = stageBrokerForTest(
            brokerProfile(secrets: entries),
            values: [refs[0]: .text("synthetic-a"), refs[1]: .text("synthetic-b")]
        )
        defer { staged.manifest.remove() }
        guard case .success(let pairs) = staged.result else {
            Issue.record("broker staging must succeed, got \(staged.result)")
            return
        }
        #expect(pairs.count == 2)
        #expect(pairs.map(\.name) == ["SYNTHETIC_DUP", "SYNTHETIC_DUP"])
        #expect(pairs.map(\.value) == ["synthetic-a", "synthetic-b"])
        #expect(staged.drops.isEmpty)
    }

    @Test func dropsCarryLabelsOnly() throws {
        let entries = [brokerEntry(item: "big", env: "SYNTHETIC_BIG")]
        let ref = try #require(entries[0].ref)
        let marker = "synthetic-marker-7f3a"
        let staged = stageBrokerForTest(
            brokerProfile(secrets: entries),
            values: [ref: .text(marker + String(repeating: "v", count: 9_000))]
        )
        defer { staged.manifest.remove() }
        guard case .success = staged.result else {
            Issue.record("broker staging must succeed, got \(staged.result)")
            return
        }
        #expect(staged.drops.count == 1)
        let rendered = staged.drops.map { "\($0.env):\($0.reason.rawValue)" }.joined(separator: ",")
        #expect(rendered == "SYNTHETIC_BIG:oversized")
        #expect(rendered.contains(marker) == false)
    }

    @Test func homeAndStagedFilePermissions() throws {
        let root = try brokerTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writeOwnerOnly("synthetic-file-payload", name: "source.doc", root: root)
        let entries = [
            brokerEntry(item: "doc", env: "SYNTHETIC_DOC"),
            brokerEntry(item: "note", env: "SYNTHETIC_FIRST"),
        ]
        let refs = try entries.map { try #require($0.ref) }
        let staged = stageBrokerForTest(
            brokerProfile(secrets: entries),
            values: [refs[0]: .filePath(source.path), refs[1]: .text("synthetic-a")]
        )
        defer { staged.manifest.remove() }
        guard case .success(let pairs) = staged.result else {
            Issue.record("broker staging must succeed, got \(staged.result)")
            return
        }
        #expect(pairs.count == 2)
        #expect(try posixPermissions(staged.manifest.privateHome) == 0o700)
        #expect(try posixPermissions(staged.manifest.privateHome + "/secrets") == 0o700)
        #expect(try posixPermissions(staged.manifest.privateHome + "/secrets/SYNTHETIC_DOC") == 0o600)
        #expect(FileManager.default.fileExists(atPath: staged.manifest.bin))
        #expect(FileManager.default.fileExists(atPath: staged.manifest.tmp))
    }

    @Test func traversalShapedNamesDropAsInvalid() throws {
        let entries = [
            brokerEntry(item: "dotdot", env: "../X"),
            brokerEntry(item: "slash", env: "a/b"),
            brokerEntry(item: "dot", env: "."),
            brokerEntry(item: "ok", env: "SYNTHETIC_FIRST"),
        ]
        let refs = try entries.map { try #require($0.ref) }
        var values: [SecretRef: SecretValue] = [:]
        for (index, ref) in refs.enumerated() {
            values[ref] = .text("synthetic-\(index)")
        }
        let staged = stageBrokerForTest(brokerProfile(secrets: entries), values: values)
        defer { staged.manifest.remove() }
        guard case .success(let pairs) = staged.result else {
            Issue.record("broker staging must succeed, got \(staged.result)")
            return
        }
        #expect(pairs.map(\.name) == ["SYNTHETIC_FIRST"])
        #expect(staged.drops == [
            BrokerStagingDrop(env: "../X", reason: .invalidName),
            BrokerStagingDrop(env: "a/b", reason: .invalidName),
            BrokerStagingDrop(env: ".", reason: .invalidName),
        ])
    }

    @Test func groupWritableFileValuesDrop() throws {
        let root = try brokerTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let loose = root.appendingPathComponent("loose.doc")
        try Data("synthetic-loose-payload".utf8).write(to: loose)
        try FileManager.default.setAttributes([.posixPermissions: 0o664], ofItemAtPath: loose.path)
        let entries = [
            brokerEntry(item: "loose", env: "SYNTHETIC_LOOSE"),
            brokerEntry(item: "ok", env: "SYNTHETIC_FIRST"),
        ]
        let refs = try entries.map { try #require($0.ref) }
        let staged = stageBrokerForTest(
            brokerProfile(secrets: entries),
            values: [refs[0]: .filePath(loose.path), refs[1]: .text("synthetic-a")]
        )
        defer { staged.manifest.remove() }
        guard case .success(let pairs) = staged.result else {
            Issue.record("broker staging must succeed, got \(staged.result)")
            return
        }
        #expect(pairs.map(\.name) == ["SYNTHETIC_FIRST"])
        #expect(staged.drops == [BrokerStagingDrop(env: "SYNTHETIC_LOOSE", reason: .fileUnreadable)])
        #expect(FileManager.default.fileExists(atPath: staged.manifest.privateHome + "/secrets/SYNTHETIC_LOOSE") == false)
    }

    @Test func fileBlockingSecretsDirDrops() throws {
        let root = try brokerTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = try writeOwnerOnly("synthetic-blocker", name: "blocker.doc", root: root)
        let source = try writeOwnerOnly("synthetic-file-payload", name: "source.doc", root: root)
        let entries = [brokerEntry(item: "doc", env: "SYNTHETIC_DOC")]
        let ref = try #require(entries[0].ref)
        let profile = brokerProfile(
            secrets: entries,
            credentials: [RuntimeResourceProfile.Credential(source: blocker.path, destination: "secrets")]
        )
        let staged = stageBrokerForTest(profile, values: [ref: .filePath(source.path)])
        defer { staged.manifest.remove() }
        guard case .success(let pairs) = staged.result else {
            Issue.record("broker staging must succeed, got \(staged.result)")
            return
        }
        #expect(pairs.isEmpty)
        #expect(staged.drops == [BrokerStagingDrop(env: "SYNTHETIC_DOC", reason: .fileUnreadable)])
    }

    @Test func tagMismatchSkipsBeforeInvalidRefAudit() throws {
        let entries = [
            brokerEntry(provider: "nope", env: "SYNTHETIC_FIRST", agents: ["someone-else"]),
            brokerEntry(env: "SYNTHETIC_SECOND"),
        ]
        let admitted = RuntimeAdmissionGate.admittedBrokerEntries(entries: entries, agent: "opencode")
        #expect(admitted.map(\.entry.env) == ["SYNTHETIC_SECOND"])
        let ref = try #require(entries[1].ref)
        let staged = stageBrokerForTest(
            brokerProfile(secrets: entries), agent: "opencode",
            values: [ref: .text("synthetic-a")]
        )
        defer { staged.manifest.remove() }
        guard case .success(let pairs) = staged.result else {
            Issue.record("broker staging must succeed, got \(staged.result)")
            return
        }
        #expect(pairs.map(\.name) == ["SYNTHETIC_SECOND"])
        #expect(staged.drops.isEmpty)
    }
}
