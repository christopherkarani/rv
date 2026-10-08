import Dispatch
import Foundation
import RVDomain
import Synchronization
import Testing
@testable import RVIsolation

private func stressDefinition() -> AgentDefinition {
    AgentDefinition(
        id: AgentDefinitionID(rawValue: "claude"),
        displayName: "Test",
        blurb: "",
        executableRequirement: ExecutableRequirement(allowsUnsigned: true),
        hookHost: .claude,
        agentTag: "claude",
        resourceProfile: RuntimeResourceProfile(id: "test", projects: []),
        credentialBindings: [],
        requiredAssurance: .launchObserved,
        authorityCeiling: AgentAuthority(scopes: ["fs.read", "shell"])
    )
}

private func stressInstance(
    definition: AgentDefinition,
    workspace: WorkspaceSessionID,
    runtime: RuntimeSessionID,
    id: AgentInstanceID = AgentInstanceID()
) -> AgentInstance {
    AgentInstance(
        id: id,
        owner: OwnerPrincipal(uid: 501),
        definitionID: definition.id,
        definitionRevision: AgentDefinitionRevision.resolve(definition),
        workspaceSessionID: workspace,
        runtimeSessionID: runtime,
        executableEvidence: .none,
        assurance: .launchObserved,
        groupLeader: RuntimeChildIdentity(pid: 100),
        workloadProcess: nil,
        parent: nil,
        effectiveAuthority: definition.authorityCeiling,
        delegableAuthority: definition.authorityCeiling,
        mintedAt: Date(timeIntervalSince1970: 0)
    )
}

private func stressSession(
    runtime: RuntimeSessionID,
    workspace: WorkspaceSessionID
) -> RuntimeSession {
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

private func stressEstablished(
    session: RuntimeSession,
    instance: AgentInstance
) throws -> EstablishedRuntimeSession {
    try #require(EstablishedRuntimeSession(
        session: session, instance: instance, establishedAt: Date()
    ))
}

/// In-memory registry: no journal I/O under test, so the race is purely the
/// registry's own state coordination.
private func stressRegistry() -> AgentInstanceRegistry {
    AgentInstanceRegistry(journal: AgentInstanceJournalStore(
        append: { _ in .success(()) },
        file: nil
    ))
}

private final class StressTeardownCounter: Sendable {
    private let count = Mutex(0)

    func run() -> Bool {
        count.withLock { $0 += 1 }
        return true
    }

    var value: Int { count.withLock { $0 } }
}

/// Runs `parties` closures on concurrent threads with a rendezvous gate: no
/// party runs `work` until every party has arrived, so the racy calls overlap
/// deterministically without sleep-based timing. Returns results in party
/// index order.
private func race<T: Sendable>(
    parties: Int,
    work: @Sendable @escaping (Int) -> T
) -> [T] {
    precondition(parties > 0)
    let arrived = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let group = DispatchGroup()
    let results = Mutex<[T?]>(Array(repeating: nil, count: parties))
    for index in 0..<parties {
        group.enter()
        DispatchQueue.global().async {
            arrived.signal()
            release.wait()
            let value = work(index)
            results.withLock { $0[index] = value }
            group.leave()
        }
    }
    for _ in 0..<parties { arrived.wait() }
    for _ in 0..<parties { release.signal() }
    group.wait()
    return results.withLock { $0.map { $0! } }
}

private enum StressActivation: Sendable {
    case activated(AuthenticatedAgentContext)
    case refused
}

@Suite(
    "AgentInstanceRegistry concurrency",
    // Serialized: each race fans out to 16 GCD parties behind semaphore
    // rendezvous. Overlapping races oversubscribe small CI runners and
    // collapse throughput for the whole shard; one race at a time keeps
    // every iteration and party while bounding thread pressure.
    .serialized
)
struct AgentInstanceRegistryConcurrencyTests {
    @Test func concurrentRevokeRunsTeardownExactlyOnce() throws {
        for _ in 0..<50 {
            let registry = stressRegistry()
            let definition = stressDefinition()
            let workspace = WorkspaceSessionID()
            let runtime = RuntimeSessionID()
            let instance = stressInstance(
                definition: definition, workspace: workspace, runtime: runtime
            )
            #expect(registry.announce(instance))
            let teardowns = StressTeardownCounter()
            let outcomes = race(parties: 16) { _ in
                registry.revoke(instance.id, reason: .explicitRevoke) {
                    teardowns.run()
                }
            }
            // Exactly one winner ran teardown; every loser observed the
            // claim and ran nothing.
            #expect(teardowns.value == 1)
            #expect(outcomes.filter { $0 == .revoked }.count == 1)
            #expect(outcomes.allSatisfy { $0 == .revoked || $0 == .alreadyInactive })
            #expect(registry.validity(of: instance.id) == .inactive)
            // One successful revoke on an announced instance advances the
            // generation exactly once; a double teardown would show here.
            #expect(registry.generation(of: instance.id) == 1)
            // No reactivation after the race.
            let session = stressSession(runtime: runtime, workspace: workspace)
            let established = try stressEstablished(session: session, instance: instance)
            #expect(registry.activate(established) == nil)
            #expect(registry.validity(of: instance.id) == .inactive)
        }
    }

    @Test func activateVersusRevokeKeepsSingleAuthority() throws {
        for _ in 0..<100 {
            let registry = stressRegistry()
            let definition = stressDefinition()
            let workspace = WorkspaceSessionID()
            let runtime = RuntimeSessionID()
            let instance = stressInstance(
                definition: definition, workspace: workspace, runtime: runtime
            )
            let session = stressSession(runtime: runtime, workspace: workspace)
            let established = try stressEstablished(session: session, instance: instance)
            #expect(registry.announce(instance))
            let teardowns = StressTeardownCounter()
            // Party 0 activates, party 1 revokes; either order is legal.
            let activation = Mutex<StressActivation?>(nil)
            let revocation = Mutex<AgentRevokeOutcome?>(nil)
            _ = race(parties: 2) { index -> Void in
                if index == 0 {
                    let context = registry.activate(established)
                    activation.withLock {
                        $0 = context.map(StressActivation.activated) ?? .refused
                    }
                } else {
                    let outcome = registry.revoke(instance.id, reason: .explicitRevoke) {
                        teardowns.run()
                    }
                    revocation.withLock { $0 = outcome }
                }
            }
            let activationResult = try #require(activation.withLock { $0 })
            #expect(revocation.withLock { $0 } == .revoked)
            #expect(teardowns.value == 1)
            // No active state survives a successful revoke.
            #expect(registry.validity(of: instance.id) == .inactive)
            // No impossible state: the generation pins which order won.
            // Activate-then-revoke advances 0 → 1 → 2 → 3; revoke of an
            // announced instance advances 0 → 1. A refused activation
            // therefore ends at 1 (revoke claimed first) or 3 (activate's
            // CAS won but the revoke completed before activate's final
            // re-read, so it correctly returned nil for a dead instance).
            // Anything else is a lost or duplicated transition.
            switch activationResult {
            case .activated(let context):
                #expect(context.instance.id == instance.id)
                #expect(registry.generation(of: instance.id) == 3)
            case .refused:
                let generation = registry.generation(of: instance.id)
                #expect(generation == 1 || generation == 3)
            }
            // No authority resurrection after the race.
            #expect(registry.activate(established) == nil)
            #expect(registry.validity(of: instance.id) == .inactive)
        }
    }

    @Test func finishRuntimeVersusRevokeRetiresOnce() throws {
        // Both start states: announced-but-never-active, and active.
        for startActive in [false, true] {
            for _ in 0..<50 {
                let registry = stressRegistry()
                let definition = stressDefinition()
                let workspace = WorkspaceSessionID()
                let runtime = RuntimeSessionID()
                let instance = stressInstance(
                    definition: definition, workspace: workspace, runtime: runtime
                )
                let session = stressSession(runtime: runtime, workspace: workspace)
                let established = try stressEstablished(session: session, instance: instance)
                #expect(registry.announce(instance))
                if startActive {
                    _ = try #require(registry.activate(established))
                }
                let teardowns = StressTeardownCounter()
                // Party 0 ends via the runtime; party 1 revokes directly.
                // Exactly one owns teardown across both paths.
                let outcomes = race(parties: 2) { index in
                    if index == 0 {
                        registry.finishRuntime(runtime, reason: .runtimeEnded)
                    } else {
                        registry.revoke(instance.id, reason: .explicitRevoke) {
                            teardowns.run()
                        }
                    }
                }
                #expect(outcomes.filter { $0 == .revoked }.count == 1)
                #expect(outcomes.allSatisfy { $0 == .revoked || $0 == .alreadyInactive })
                // The winner's teardown ran once and the loser's never ran:
                // our counter fires only when our revoke won.
                #expect(teardowns.value == (outcomes[1] == .revoked ? 1 : 0))
                #expect(registry.validity(of: instance.id) == .inactive)
                #expect(registry.generation(of: instance.id) == (startActive ? 3 : 1))
                #expect(registry.activate(established) == nil)
                // The runtime stays bound to the historical instance and can
                // never rebind to a new one.
                #expect(registry.instance(forRuntime: runtime)?.id == instance.id)
                let reuse = stressInstance(
                    definition: definition, workspace: workspace, runtime: runtime
                )
                #expect(registry.announce(reuse) == false)
                #expect(registry.announce(instance) == false)
            }
        }
    }

    @Test func concurrentDuplicateRuntimeAnnounceWinsOnce() throws {
        for _ in 0..<50 {
            let registry = stressRegistry()
            let definition = stressDefinition()
            let workspace = WorkspaceSessionID()
            let runtime = RuntimeSessionID()
            let parties = 16
            let candidates = (0..<parties).map { _ in
                stressInstance(definition: definition, workspace: workspace, runtime: runtime)
            }
            let wins = race(parties: parties) { registry.announce(candidates[$0]) }
            #expect(wins.filter { $0 }.count == 1)
            let winner = try #require(
                candidates.enumerated().first { wins[$0.offset] }?.element
            )
            // No conflicting runtime ownership and no state clobber: the
            // live record is exactly the winner's content.
            #expect(registry.instance(forRuntime: runtime) == winner)
            #expect(registry.instance(for: winner.id) == winner)
            #expect(registry.validity(of: winner.id) == .inactive)
            for loser in candidates where loser.id != winner.id {
                #expect(registry.validity(of: loser.id) == .unknown)
            }
        }
    }

    @Test func concurrentDuplicateInstanceAnnounceWinsOnce() throws {
        for _ in 0..<50 {
            let registry = stressRegistry()
            let definition = stressDefinition()
            let workspace = WorkspaceSessionID()
            let sharedID = AgentInstanceID()
            let parties = 16
            let candidates = (0..<parties).map { _ in
                stressInstance(
                    definition: definition,
                    workspace: workspace,
                    runtime: RuntimeSessionID(),
                    id: sharedID
                )
            }
            let wins = race(parties: parties) { registry.announce(candidates[$0]) }
            #expect(wins.filter { $0 }.count == 1)
            let winner = try #require(
                candidates.enumerated().first { wins[$0.offset] }?.element
            )
            // One registration wins with its content intact; every losing
            // runtime stays unbound.
            #expect(registry.instance(for: sharedID) == winner)
            #expect(registry.instance(forRuntime: winner.runtimeSessionID) == winner)
            #expect(registry.validity(of: sharedID) == .inactive)
            for loser in candidates where loser.runtimeSessionID != winner.runtimeSessionID {
                #expect(registry.instance(forRuntime: loser.runtimeSessionID) == nil)
            }
        }
    }
}
