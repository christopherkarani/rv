#if os(macOS)
import Darwin
import Foundation
import RVDomain
import RVPolicy
import Testing
@testable import RVIsolation

/// Step 7: process death must propagate into AgentInstance revocation.
///
/// A dead execution must not remain an active principal: once the kernel
/// reports the agent's process group leader gone, the authoritative path
/// (registry → principal authority → host validity → service validation)
/// must report non-active without waiting for the full teardown tail, and
/// without requiring a new privileged request to discover the death.
@Suite(.serialized)
struct AgentInstanceDeathTests {
    @Test func sigkillOfLeaderInvalidatesPrincipalThroughAuthority() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try openDeathWorkspace(tree)
        defer { _ = supervisor.close() }
        let selection = try deathOperatorSelection(tree, executable: "/bin/sleep")
        let runtime = try supervisor.launchAgent(
            selection: selection, arguments: ["30"],
            io: .discard, admission: .failClosed,
            sessionStore: .file(tree.rootURL.appendingPathComponent("death-runtime.jsonl")),
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        let instance = try #require(supervisor.agentInstances.instance(forRuntime: runtime.id))
        #expect(supervisor.agentInstances.validity(of: instance.id) == .active)
        let authority = WorkspacePrincipalAuthority(
            registry: supervisor.agentInstances, workspace: supervisor.id, host: WorkspaceHostID()
        )
        let reference = try #require(authority.reference(forRuntime: runtime.id))
        #expect(authority.resolve(reference)?.validity == .active)

        // Kill the leader and confirm kernel death without reaping: the
        // supervisor's watch thread owns waitpid. WNOWAIT observes the
        // zombie; ECHILD afterwards means the watcher already reaped it.
        let leader = instance.groupLeader.pid
        let killWall = Date()
        #expect(kill(leader, SIGKILL) == 0)
        let deathWall = try waitForKernelDeath(leader, timeout: 10)
        let firstSample = supervisor.agentInstances.validity(of: instance.id)
        let flipWall = try waitForValidity(
            supervisor.agentInstances, instance: instance.id, timeout: 15)
        let resolveWall = try waitForResolveNil(authority, reference: reference, timeout: 15)
        print(
            "STEP7-PROBE sigkill leader=\(leader)"
                + " killToDeathMs=\(ms(killWall, deathWall))"
                + " deathToFlipMs=\(ms(deathWall, flipWall))"
                + " flipToResolveNilMs=\(ms(flipWall, resolveWall))"
                + " firstSampleAfterDeath=\(firstSample)"
        )
        #expect(authority.reference(forRuntime: runtime.id) == nil)
    }

    @Test func sigtermOfLeaderInvalidatesPrincipal() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try openDeathWorkspace(tree)
        defer { _ = supervisor.close() }
        let selection = try deathOperatorSelection(tree, executable: "/bin/sleep")
        let runtime = try supervisor.launchAgent(
            selection: selection, arguments: ["30"],
            io: .discard, admission: .failClosed,
            sessionStore: .file(tree.rootURL.appendingPathComponent("death-term-runtime.jsonl")),
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        let instance = try #require(supervisor.agentInstances.instance(forRuntime: runtime.id))
        #expect(supervisor.agentInstances.validity(of: instance.id) == .active)
        #expect(kill(instance.groupLeader.pid, SIGTERM) == 0)
        _ = try waitForValidity(supervisor.agentInstances, instance: instance.id, timeout: 15)
        #expect(supervisor.agentInstances.validity(ofRuntime: runtime.id) == .inactive)
    }

    @Test func normalExitInvalidatesPrincipal() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try openDeathWorkspace(tree)
        defer { _ = supervisor.close() }
        let trigger = tree.workspaceURL.appendingPathComponent("death-exit-trigger")
        // Loops until the trigger appears, then exits 0: established first,
        // so this is a genuine normal exit, not an instant-exit launch.
        let selection = try deathOperatorSelection(tree, executable: "/bin/sh")
        let runtime = try supervisor.launchAgent(
            selection: selection,
            arguments: ["-c", "while [ ! -e \"$1\" ]; do sleep 0.05; done; exit 0", "sh", trigger.path],
            io: .discard, admission: .failClosed,
            sessionStore: .file(tree.rootURL.appendingPathComponent("death-exit-runtime.jsonl")),
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        let instance = try #require(supervisor.agentInstances.instance(forRuntime: runtime.id))
        #expect(supervisor.agentInstances.validity(of: instance.id) == .active)
        try Data().write(to: trigger)
        _ = try waitForValidity(supervisor.agentInstances, instance: instance.id, timeout: 15)
        #expect(supervisor.agentInstances.validity(ofRuntime: runtime.id) == .inactive)
    }

    @Test func groupKillInvalidatesExactlyOnce() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let journalURL = tree.rootURL.appendingPathComponent("death-group-instances.jsonl")
        let supervisor = try WorkspaceSessionSupervisor.open(
            try #require(WorkingDirectory(validating: tree.workspaceURL.path)),
            lifecycleLog: .file(tree.rootURL.appendingPathComponent("death-group-workspace.jsonl")),
            runtimeLog: tree.rootURL.appendingPathComponent("death-group-runtime.jsonl"),
            instanceJournal: .file(journalURL)
        ).get()
        defer { _ = supervisor.close() }
        let selection = try deathOperatorSelection(tree, executable: "/bin/sleep")
        let runtime = try supervisor.launchAgent(
            selection: selection, arguments: ["30"],
            io: .discard, admission: .failClosed,
            sessionStore: .file(tree.rootURL.appendingPathComponent("death-group-store.jsonl")),
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        let instance = try #require(supervisor.agentInstances.instance(forRuntime: runtime.id))
        #expect(supervisor.agentInstances.validity(of: instance.id) == .active)
        // The launch proves pgid == leader pid: killing the group kills the leader.
        #expect(kill(-instance.groupLeader.pid, SIGKILL) == 0)
        _ = try waitForValidity(supervisor.agentInstances, instance: instance.id, timeout: 15)
        _ = try waitForJournalFinished(journalURL, timeout: 15)
        usleep(300_000)
        let records = AgentInstanceJournal.records(at: journalURL)
        #expect(records.map(\.kind) == [.attempted, .established, .revoking, .finished])
        #expect(records.last?.detail == "revoked:runtimeEnded")
    }

    @Test func deathObservedRevokesImmediatelyWithoutResurrection() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try openDeathWorkspace(tree)
        defer { _ = supervisor.close() }
        let selection = try deathOperatorSelection(tree, executable: "/bin/sleep")
        let runtime = try supervisor.launchAgent(
            selection: selection, arguments: ["30"],
            io: .discard, admission: .failClosed,
            sessionStore: .file(tree.rootURL.appendingPathComponent("death-direct-runtime.jsonl")),
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        let instance = try #require(supervisor.agentInstances.instance(forRuntime: runtime.id))
        let authority = WorkspacePrincipalAuthority(
            registry: supervisor.agentInstances, workspace: supervisor.id, host: WorkspaceHostID()
        )
        let reference = try #require(authority.reference(forRuntime: runtime.id))
        // Direct handler invocation: the watch thread's exact call, with no
        // timing involved. Authority dies synchronously in this call.
        supervisor.noteDeathObserved(runtime.session)
        #expect(supervisor.agentInstances.validity(of: instance.id) == .inactive)
        #expect(supervisor.agentInstances.validity(ofRuntime: runtime.id) == .inactive)
        #expect(authority.resolve(reference) == nil)
        #expect(authority.reference(forRuntime: runtime.id) == nil)
        // Terminal: no resurrection through any entry.
        let established = try #require(EstablishedRuntimeSession(
            session: runtime.session, instance: instance, establishedAt: Date()))
        #expect(supervisor.agentInstances.activate(established) == nil)
        #expect(supervisor.agentInstances.revoke(instance.id, reason: .explicitRevoke) { true } == .alreadyInactive)
        _ = try waitForValidity(supervisor.agentInstances, instance: instance.id, timeout: 1)
        try supervisor.cancel(runtime.id).get()
    }

    @Test func deathVersusExplicitRevokeRetiresOnce() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try openDeathWorkspace(tree)
        defer { _ = supervisor.close() }
        let selection = try deathOperatorSelection(tree, executable: "/bin/sleep")
        func launch() throws -> RunningRuntime {
            try supervisor.launchAgent(
                selection: selection, arguments: ["30"],
                io: .discard, admission: .failClosed,
                sessionStore: .file(tree.rootURL.appendingPathComponent("death-race-\(UUID().uuidString).jsonl")),
                host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
            ).get()
        }
        // Death wins: explicit revoke observes the terminal state.
        let first = try launch()
        let firstInstance = try #require(supervisor.agentInstances.instance(forRuntime: first.id))
        supervisor.noteDeathObserved(first.session)
        #expect(supervisor.agentInstances.revoke(firstInstance.id, reason: .explicitRevoke) { true } == .alreadyInactive)
        try supervisor.cancel(first.id).get()
        // Explicit revoke wins: death observes the terminal state.
        let second = try launch()
        let secondInstance = try #require(supervisor.agentInstances.instance(forRuntime: second.id))
        #expect(supervisor.agentInstances.revoke(secondInstance.id, reason: .explicitRevoke) { true } == .revoked)
        supervisor.noteDeathObserved(second.session)
        #expect(supervisor.agentInstances.validity(of: secondInstance.id) == .inactive)
        try supervisor.cancel(second.id).get()
    }

    @Test func replacementInstanceGetsFreshAuthority() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try openDeathWorkspace(tree)
        defer { _ = supervisor.close() }
        let selection = try deathOperatorSelection(tree, executable: "/bin/sleep")
        func launch(store: String) throws -> RunningRuntime {
            try supervisor.launchAgent(
                selection: selection, arguments: ["30"],
                io: .discard, admission: .failClosed,
                sessionStore: .file(tree.rootURL.appendingPathComponent(store)),
                host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
            ).get()
        }
        let authority = WorkspacePrincipalAuthority(
            registry: supervisor.agentInstances, workspace: supervisor.id, host: WorkspaceHostID()
        )
        let first = try launch(store: "death-replace-1.jsonl")
        let firstInstance = try #require(supervisor.agentInstances.instance(forRuntime: first.id))
        let firstReference = try #require(authority.reference(forRuntime: first.id))
        #expect(kill(firstInstance.groupLeader.pid, SIGKILL) == 0)
        _ = try waitForValidity(supervisor.agentInstances, instance: firstInstance.id, timeout: 15)
        let second = try launch(store: "death-replace-2.jsonl")
        let secondInstance = try #require(supervisor.agentInstances.instance(forRuntime: second.id))
        #expect(secondInstance.id != firstInstance.id)
        #expect(supervisor.agentInstances.validity(of: secondInstance.id) == .active)
        #expect(supervisor.agentInstances.validity(of: firstInstance.id) == .inactive)
        #expect(authority.resolve(firstReference) == nil)
        let secondReference = try #require(authority.reference(forRuntime: second.id))
        #expect(authority.resolve(secondReference)?.validity == .active)
        try supervisor.cancel(second.id).get()
    }

    @Test func closeAfterDeathLeavesNoStaleInstance() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let journalURL = tree.rootURL.appendingPathComponent("death-close-instances.jsonl")
        let supervisor = try WorkspaceSessionSupervisor.open(
            try #require(WorkingDirectory(validating: tree.workspaceURL.path)),
            lifecycleLog: .file(tree.rootURL.appendingPathComponent("death-close-workspace.jsonl")),
            runtimeLog: tree.rootURL.appendingPathComponent("death-close-runtime.jsonl"),
            instanceJournal: .file(journalURL)
        ).get()
        let selection = try deathOperatorSelection(tree, executable: "/bin/sleep")
        let runtime = try supervisor.launchAgent(
            selection: selection, arguments: ["30"],
            io: .discard, admission: .failClosed,
            sessionStore: .file(tree.rootURL.appendingPathComponent("death-close-store.jsonl")),
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        let instance = try #require(supervisor.agentInstances.instance(forRuntime: runtime.id))
        #expect(kill(instance.groupLeader.pid, SIGKILL) == 0)
        _ = try waitForValidity(supervisor.agentInstances, instance: instance.id, timeout: 15)
        _ = try waitForJournalFinished(journalURL, timeout: 15)
        _ = supervisor.close()
        #expect(supervisor.agentInstances.validity(of: instance.id) == .inactive)
        #expect(supervisor.agentInstances.validity(ofRuntime: runtime.id) == .inactive)
        // Exactly once, with the death's reason preserved: close's
        // pre-revoke observes the terminal state, never double-journals.
        usleep(300_000)
        let records = AgentInstanceJournal.records(at: journalURL)
        #expect(records.map(\.kind) == [.attempted, .established, .revoking, .finished])
        #expect(records.last?.detail == "revoked:runtimeEnded")
    }

    @Test func closeRevokesLiveChildAsCancelled() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let journalURL = tree.rootURL.appendingPathComponent("death-close-live-instances.jsonl")
        let supervisor = try WorkspaceSessionSupervisor.open(
            try #require(WorkingDirectory(validating: tree.workspaceURL.path)),
            lifecycleLog: .file(tree.rootURL.appendingPathComponent("death-close-live-workspace.jsonl")),
            runtimeLog: tree.rootURL.appendingPathComponent("death-close-live-runtime.jsonl"),
            instanceJournal: .file(journalURL)
        ).get()
        let selection = try deathOperatorSelection(tree, executable: "/bin/sleep")
        let runtime = try supervisor.launchAgent(
            selection: selection, arguments: ["30"],
            io: .discard, admission: .failClosed,
            sessionStore: .file(tree.rootURL.appendingPathComponent("death-close-live-store.jsonl")),
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        let instance = try #require(supervisor.agentInstances.instance(forRuntime: runtime.id))
        #expect(supervisor.agentInstances.validity(of: instance.id) == .active)
        // Authority dies synchronously in close, mirroring cancel(): the
        // pre-revoke wins before the watch observes the teardown kill.
        _ = supervisor.close()
        #expect(supervisor.agentInstances.validity(of: instance.id) == .inactive)
        let records = AgentInstanceJournal.records(at: journalURL)
        #expect(records.map(\.kind) == [.attempted, .established, .revoking, .finished])
        #expect(records.last?.detail == "revoked:cancelled")
    }

    @Test func authorityCloseVersusDeathBothOrdersFailClosed() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try openDeathWorkspace(tree)
        defer { _ = supervisor.close() }
        let selection = try deathOperatorSelection(tree, executable: "/bin/sleep")
        func launch(store: String) throws -> RunningRuntime {
            try supervisor.launchAgent(
                selection: selection, arguments: ["30"],
                io: .discard, admission: .failClosed,
                sessionStore: .file(tree.rootURL.appendingPathComponent(store)),
                host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
            ).get()
        }
        // Host shutdown first, then death: no resolution either way.
        let first = try launch(store: "death-shutdown-1.jsonl")
        let firstAuthority = WorkspacePrincipalAuthority(
            registry: supervisor.agentInstances, workspace: supervisor.id, host: WorkspaceHostID())
        let firstReference = try #require(firstAuthority.reference(forRuntime: first.id))
        firstAuthority.close()
        supervisor.noteDeathObserved(first.session)
        #expect(firstAuthority.resolve(firstReference) == nil)
        // Death first, then host shutdown: still nothing.
        let second = try launch(store: "death-shutdown-2.jsonl")
        let secondAuthority = WorkspacePrincipalAuthority(
            registry: supervisor.agentInstances, workspace: supervisor.id, host: WorkspaceHostID())
        let secondReference = try #require(secondAuthority.reference(forRuntime: second.id))
        supervisor.noteDeathObserved(second.session)
        secondAuthority.close()
        #expect(secondAuthority.resolve(secondReference) == nil)
        try supervisor.cancel(first.id).get()
        try supervisor.cancel(second.id).get()
    }

    @Test func numericPidReuseCannotResurrect() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-death-pidreuse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AgentInstanceRegistry(
            journal: .file(root.appendingPathComponent("instances.jsonl")))
        let workspace = WorkspaceSessionID()
        let definition = makeDeathDefinition()
        // First execution on numeric pid 4242: announce, activate, die.
        let firstRuntime = RuntimeSessionID()
        let first = makeDeathInstance(
            definition: definition, workspace: workspace, runtime: firstRuntime, pid: 4242)
        #expect(registry.announce(first))
        let firstSession = makeDeathSession(runtime: firstRuntime, workspace: workspace)
        let firstEstablished = try #require(EstablishedRuntimeSession(
            session: firstSession, instance: first, establishedAt: Date()))
        _ = try #require(registry.activate(firstEstablished))
        #expect(registry.finishRuntime(firstRuntime, reason: .runtimeEnded) == .revoked)
        // The kernel recycles numeric pid 4242 for an unrelated execution.
        // Same number, fresh ids: the old principal stays dead.
        let secondRuntime = RuntimeSessionID()
        let second = makeDeathInstance(
            definition: definition, workspace: workspace, runtime: secondRuntime, pid: 4242)
        #expect(registry.announce(second))
        let secondSession = makeDeathSession(runtime: secondRuntime, workspace: workspace)
        let secondEstablished = try #require(EstablishedRuntimeSession(
            session: secondSession, instance: second, establishedAt: Date()))
        _ = try #require(registry.activate(secondEstablished))
        #expect(registry.validity(of: first.id) == .inactive)
        #expect(registry.validity(of: second.id) == .active)
        let authority = WorkspacePrincipalAuthority(
            registry: registry, workspace: workspace, host: WorkspaceHostID())
        let firstReference = AgentPrincipalReference(
            agentInstanceID: first.id, runtimeSessionID: firstRuntime,
            workspaceSessionID: workspace, workspaceHostID: authority.host,
            workspaceHostGeneration: authority.generation)
        #expect(authority.resolve(firstReference) == nil)
        #expect(authority.reference(forRuntime: secondRuntime)?.agentInstanceID == second.id)
    }

    @Test func deadInstanceSubmitIsRefused() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try openDeathWorkspace(tree)
        defer { _ = supervisor.close() }
        let selection = try deathOperatorSelection(tree, executable: "/bin/sleep")
        let runtime = try supervisor.launchAgent(
            selection: selection, arguments: ["30"],
            io: .discard, admission: .failClosed,
            sessionStore: .file(tree.rootURL.appendingPathComponent("death-submit-runtime.jsonl")),
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        let instance = try #require(supervisor.agentInstances.instance(forRuntime: runtime.id))
        #expect(supervisor.agentInstances.validity(of: instance.id) == .active)
        #expect(kill(instance.groupLeader.pid, SIGKILL) == 0)
        _ = try waitForValidity(supervisor.agentInstances, instance: instance.id, timeout: 15)
        // The old runtime capability path cannot authorize after death: the
        // channel is finished and the principal is inactive, so the gate
        // refuses. A missing child is equally fail-closed (no execution).
        let frame = RuntimeActionFrame(
            version: 1,
            requestID: RuntimeActionRequestID(validating: UUID().uuidString)!,
            capability: runtime.capability,
            claimedSession: RuntimeSessionClaim(validating: runtime.id.rawValue.uuidString)!,
            action: .shell(ShellCommand(rawValue: "touch should-never-run")))
        if let decision = supervisor.submit(frame, to: runtime.id) {
            #expect(decision.response == .rejected(.inactiveSession))
        }
    }
}

private func waitForKernelDeath(_ pid: pid_t, timeout: TimeInterval) throws -> Date {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if sessionLeaderHasExited(pid) { return Date() }
        if kill(pid, 0) == -1, errno == ESRCH { return Date() }
        usleep(1_000)
    }
    Issue.record("leader \(pid) never observably died")
    return Date()
}

private func waitForValidity(
    _ registry: AgentInstanceRegistry, instance: AgentInstanceID, timeout: TimeInterval
) throws -> Date {
    // Terminal state only: .revoking is a designed observable transient,
    // so returning on merely-non-active would race the final transition.
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if registry.validity(of: instance) == .inactive { return Date() }
        usleep(1_000)
    }
    Issue.record("validity never reached .inactive \(timeout)s after kernel death")
    return Date()
}

private func waitForResolveNil(
    _ authority: WorkspacePrincipalAuthority,
    reference: AgentPrincipalReference, timeout: TimeInterval
) throws -> Date {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if authority.resolve(reference) == nil { return Date() }
        usleep(1_000)
    }
    Issue.record("authority.resolve stayed non-nil \(timeout)s after kernel death")
    return Date()
}

private func ms(_ from: Date, _ to: Date) -> Int {
    Int(to.timeIntervalSince(from) * 1_000)
}

private func waitForJournalFinished(_ url: URL, timeout: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if AgentInstanceJournal.records(at: url).contains(where: { $0.kind == .finished }) {
            return
        }
        usleep(10_000)
    }
    Issue.record("journal at \(url.path) never recorded .finished")
}

private func makeDeathDefinition() -> AgentDefinition {
    AgentDefinition(
        id: AgentDefinitionID(rawValue: "death-fixture"),
        displayName: "Death fixture",
        blurb: "",
        executableRequirement: ExecutableRequirement(allowsUnsigned: true),
        hookHost: .claude,
        agentTag: "death-fixture",
        resourceProfile: RuntimeResourceProfile(id: "death-fixture", projects: []),
        credentialBindings: [],
        requiredAssurance: .launchObserved,
        authorityCeiling: AgentAuthority(scopes: ["fs.read"])
    )
}

private func makeDeathInstance(
    definition: AgentDefinition,
    workspace: WorkspaceSessionID,
    runtime: RuntimeSessionID,
    pid: Int32
) -> AgentInstance {
    AgentInstance(
        id: AgentInstanceID(),
        owner: OwnerPrincipal(uid: 501),
        definitionID: definition.id,
        definitionRevision: AgentDefinitionRevision.resolve(definition),
        workspaceSessionID: workspace,
        runtimeSessionID: runtime,
        executableEvidence: .none,
        assurance: .launchObserved,
        groupLeader: RuntimeChildIdentity(pid: pid),
        workloadProcess: nil,
        parent: nil,
        effectiveAuthority: definition.authorityCeiling,
        delegableAuthority: definition.authorityCeiling,
        mintedAt: Date(timeIntervalSince1970: 0)
    )
}

private func makeDeathSession(runtime: RuntimeSessionID, workspace: WorkspaceSessionID) -> RuntimeSession {
    let directory = WorkingDirectory(validating: FileManager.default.temporaryDirectory.path)!
    return RuntimeSession(
        id: runtime,
        workspaceSessionID: workspace,
        host: .opencode,
        workspace: directory,
        backend: .seatbelt,
        startedAt: Date(),
        child: nil
    )
}

private func openDeathWorkspace(_ tree: ContainmentTree) throws -> WorkspaceSessionSupervisor {
    try WorkspaceSessionSupervisor.open(
        try #require(WorkingDirectory(validating: tree.workspaceURL.path)),
        lifecycleLog: .file(tree.rootURL.appendingPathComponent("death-workspace.jsonl")),
        runtimeLog: tree.rootURL.appendingPathComponent("death-runtime.jsonl"),
        instanceJournal: .file(tree.rootURL.appendingPathComponent("death-instances.jsonl"))
    ).get()
}

private func deathOperatorSelection(_ tree: ContainmentTree, executable: String) throws -> ResolvedAgentLaunch {
    let policy = RuntimeResourcePolicy(profiles: [RuntimeResourceProfile(
        id: "death-fixture", projects: [tree.workspaceURL.path],
        executableLinks: [.init(name: "death-fixture", target: executable)]
    )])
    let definition: [String: Any] = [
        "id": "death-fixture", "displayName": "Death fixture", "blurb": "Test death fixture",
        "executable": ["allowsUnsigned": true], "resourceProfile": "death-fixture",
        "credentialBindings": [], "requiredAssurance": "launchObserved", "authorityCeiling": []
    ]
    let document = try JSONSerialization.data(withJSONObject: [
        "version": 1,
        "definitions": [definition]
    ])
    let definitions = try AgentDefinitionStore.decode(document, resourcePolicy: policy).get()
    return try AgentLaunchSelection.resolveNamed(
        id: AgentDefinitionID(rawValue: "death-fixture"), definitions: definitions,
        project: tree.workspaceURL.path
    ).get()
}
#endif
