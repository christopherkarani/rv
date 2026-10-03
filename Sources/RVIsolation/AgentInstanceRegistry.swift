import Foundation
import RVDomain
import Synchronization

/// Why an instance lost authority. Fixed vocabulary; journaled verbatim.
enum AgentRevokeReason: String, Sendable {
    case runtimeEnded
    case cancelled
    case lostOwnership
    case explicitRevoke
    case spawnFailed
    case establishmentFailed
}

enum AgentRevokeOutcome: Sendable, Equatable {
    /// Authority is dead and the historical outcome was journaled. Teardown
    /// ran exactly once; its failure is recorded, never resurrected.
    case revoked
    /// The registry never announced this instance. Nothing happened.
    case unknown
    /// Already dead and already journaled. Nothing happened.
    case alreadyInactive
}

/// Host-owned live registry of Agent Instances.
///
/// One workspace host owns its active instances. Lookup by instance, runtime,
/// workspace, or channel binding returns state; it does NOT authenticate.
/// Only `validity(of:)` is authoritative, and only a freshly resolved value
/// counts: a cached `AuthenticatedAgentContext` is a description that never
/// equals live validity.
///
/// Lifecycle: launch attempt (announced, unusable) → established (active) →
/// revoking (new privileged use refused) → inactive (dead, journaled).
/// Disk describes and never resurrects: a fresh registry starts empty no
/// matter what the journal contains, and historical records can never be
/// reloaded into live authority.
final class AgentInstanceRegistry: Sendable {
    private struct LiveRecord: Sendable {
        var instance: AgentInstance
        var validity: AgentInstanceValidity
        var generation: UInt64
        var finished: Bool
        /// Teardown ownership. Claimed atomically under the lock by the one
        /// revoke that runs teardown; concurrent revokes observe the claim
        /// and run nothing. Set before teardown starts, never cleared.
        var teardownClaimed: Bool
    }

    private struct State: Sendable {
        var byInstance: [AgentInstanceID: LiveRecord] = [:]
        var byRuntime: [RuntimeSessionID: AgentInstanceID] = [:]
    }

    private let state = Mutex(State())
    private let journal: AgentInstanceJournalStore

    init(journal: AgentInstanceJournalStore = .production) {
        self.journal = journal
    }

    /// Records a launch attempt. The instance is known but NOT usable:
    /// validity stays inactive until the runtime establishes.
    ///
    /// Refuses (false, nothing registered) when the instance id is already
    /// known, when the runtime is already bound — one runtime binds exactly
    /// one instance — or when the journal append fails.
    func announce(_ instance: AgentInstance) -> Bool {
        let duplicate = state.withLock { state in
            state.byInstance[instance.id] != nil
                || state.byRuntime[instance.runtimeSessionID] != nil
        }
        guard duplicate == false else { return false }
        let record = journalRecord(instance, kind: .attempted, detail: nil)
        guard case .success = journal.append(record) else { return false }
        // A concurrent announce for the same runtime or instance id loses
        // here; its journal line describes an attempt that never became
        // live. The loser reports false like a sequential duplicate: the
        // live record holds the winner's content, not this caller's.
        let inserted = state.withLock { state -> Bool in
            guard state.byInstance[instance.id] == nil,
                state.byRuntime[instance.runtimeSessionID] == nil
            else {
                return false
            }
            state.byInstance[instance.id] = LiveRecord(
                instance: instance,
                validity: .inactive,
                generation: 0,
                finished: false,
                teardownClaimed: false
            )
            state.byRuntime[instance.runtimeSessionID] = instance.id
            return true
        }
        return inserted
    }

    /// Marks the instance active once its runtime established.
    ///
    /// The pairing proof is structural: `EstablishedRuntimeSession` exists
    /// only when the instance names this session and workspace. Returns nil —
    /// without touching live state — for an unannounced, revoked, or
    /// already-finished instance, or when the journal append fails.
    func activate(_ established: EstablishedRuntimeSession) -> AuthenticatedAgentContext? {
        let current = state.withLock { $0.byInstance[established.agentInstanceID] }
        guard let current,
            current.finished == false,
            current.teardownClaimed == false,
            current.instance.runtimeSessionID == established.session.id,
            current.instance.workspaceSessionID == established.session.workspaceSessionID
        else {
            return nil
        }
        if current.validity == .active {
            return AuthenticatedAgentContext(instance: current.instance, validity: .active)
        }
        guard current.validity == .inactive else { return nil }
        let record = journalRecord(current.instance, kind: .established, detail: nil)
        guard case .success = journal.append(record) else { return nil }
        state.withLock { state in
            guard var live = state.byInstance[established.agentInstanceID],
                live.finished == false, live.teardownClaimed == false,
                live.validity == .inactive
            else {
                return
            }
            live.validity = .active
            live.generation += 1
            state.byInstance[established.agentInstanceID] = live
        }
        guard let live = state.withLock({ $0.byInstance[established.agentInstanceID] }),
            live.validity == .active
        else {
            return nil
        }
        return AuthenticatedAgentContext(instance: live.instance, validity: .active)
    }

    /// Authoritative live validity. `.unknown` was never announced.
    func validity(of id: AgentInstanceID) -> AgentInstanceValidity {
        state.withLock { $0.byInstance[id]?.validity ?? .unknown }
    }

    func validity(ofRuntime runtime: RuntimeSessionID) -> AgentInstanceValidity {
        state.withLock { state in
            guard let id = state.byRuntime[runtime] else { return .unknown }
            return state.byInstance[id]?.validity ?? .unknown
        }
    }

    /// Validity generation. Advances on every transition; nil when unknown.
    /// A stale generation never equals the live one after revocation.
    func generation(of id: AgentInstanceID) -> UInt64? {
        state.withLock { $0.byInstance[id]?.generation }
    }

    /// Live record lookup. Returns state; it does NOT authenticate.
    func instance(for id: AgentInstanceID) -> AgentInstance? {
        state.withLock { $0.byInstance[id]?.instance }
    }

    func instance(forRuntime runtime: RuntimeSessionID) -> AgentInstance? {
        state.withLock { state in
            guard let id = state.byRuntime[runtime] else { return nil }
            return state.byInstance[id]?.instance
        }
    }

    func instances(inWorkspace workspace: WorkspaceSessionID) -> [AgentInstance] {
        state.withLock { state in
            state.byInstance.values
                .map(\.instance)
                .filter { $0.workspaceSessionID == workspace }
        }
    }

    /// State lookup by RV-held channel binding. The binding names the
    /// instance; this returns whatever the registry holds for it — including
    /// an inactive record — and never grants anything.
    func instance(forBinding binding: RuntimeChannelBinding) -> AgentInstance? {
        guard let id = binding.agentInstanceID else { return nil }
        return instance(for: id)
    }

    /// Trusted principal context for admission: the instance plus its live
    /// validity at this instant. Resolve fresh for every privileged use; a
    /// cached context is a description that never equals live validity.
    func context(for id: AgentInstanceID) -> AuthenticatedAgentContext? {
        state.withLock { state in
            guard let live = state.byInstance[id] else { return nil }
            return AuthenticatedAgentContext(instance: live.instance, validity: live.validity)
        }
    }

    func context(forBinding binding: RuntimeChannelBinding) -> AuthenticatedAgentContext? {
        guard let id = binding.agentInstanceID else { return nil }
        return context(for: id)
    }

    /// Ends an instance: revoking → teardown → inactive → journaled.
    ///
    /// `teardown` releases instance-held resources (process group, admission
    /// work). It runs outside the registry lock, exactly once per instance:
    /// the one revoke that atomically claims teardown ownership under the
    /// lock runs it, and every concurrent revoke observes the claim and runs
    /// nothing. Its failure is recorded in the journal detail; authority
    /// stays dead either way. Cleanup failure MUST NOT reactivate authority.
    func revoke(
        _ id: AgentInstanceID,
        reason: AgentRevokeReason,
        teardown: @Sendable () -> Bool
    ) -> AgentRevokeOutcome {
        let snapshot = state.withLock { state -> LiveRecord? in
            guard var live = state.byInstance[id], live.teardownClaimed == false else {
                // Unknown instance, or teardown already claimed — in flight
                // or finished. Authority is already dead: an active record
                // leaves `.active` in the same critical section that claims.
                return nil
            }
            if live.validity == .active {
                guard let revoking = live.validity.transition(.beginRevoking) else {
                    return nil
                }
                live.validity = revoking
                live.generation += 1
            }
            live.teardownClaimed = true
            state.byInstance[id] = live
            return live
        }
        guard let snapshot else {
            if state.withLock({ $0.byInstance[id] == nil }) {
                return .unknown
            }
            return .alreadyInactive
        }
        if snapshot.validity == .revoking {
            let revoking = journalRecord(snapshot.instance, kind: .revoking, detail: nil)
            _ = journal.append(revoking)
        }
        let clean = teardown()
        state.withLock { state in
            guard var live = state.byInstance[id], live.finished == false else { return }
            if let inactive = live.validity.transition(.didDeactivate) {
                live.validity = inactive
            } else {
                live.validity = .inactive
            }
            live.generation += 1
            live.finished = true
            state.byInstance[id] = live
        }
        var detail = "revoked:" + reason.rawValue
        if clean == false {
            detail += ";teardownFailed"
        }
        let finished = journalRecord(snapshot.instance, kind: .finished, detail: detail)
        _ = journal.append(finished)
        return .revoked
    }

    /// Ends whatever instance a runtime bound. Unknown runtimes are a no-op:
    /// there is no authority to end. The supervisor calls this the moment it
    /// observes definitive death — authority dies before the reap completes,
    /// mirroring cancel(); nothing here resurrects the process.
    func finishRuntime(
        _ runtime: RuntimeSessionID,
        reason: AgentRevokeReason
    ) -> AgentRevokeOutcome {
        let id = state.withLock { $0.byRuntime[runtime] }
        guard let id else { return .unknown }
        return revoke(id, reason: reason) { true }
    }

    /// Creates a delegated child of a live parent through the registry.
    ///
    /// The parent must be active right now: dead parents delegate nothing.
    /// Authority only narrows — a widened request returns nil. The child gets
    /// a distinct fresh instance id, its own runtime binding, an explicit
    /// parent reference with its authority snapshot, and no parent
    /// credential material (instances carry none). The child is announced,
    /// not active: its own runtime establishment activates it.
    func delegateChild(
        from parent: AgentInstanceID,
        authority: AgentAuthority,
        runtimeSessionID: RuntimeSessionID,
        executableEvidence: ExecutableEvidence,
        assurance: ExecutableAssurance,
        groupLeader: RuntimeChildIdentity,
        workloadProcess: RuntimeChildIdentity?,
        mintedAt: Date = Date()
    ) -> AgentInstance? {
        let parentInstance = state.withLock { state -> AgentInstance? in
            guard let live = state.byInstance[parent], live.validity == .active else {
                return nil
            }
            guard state.byRuntime[runtimeSessionID] == nil else { return nil }
            return live.instance
        }
        guard let parentInstance,
            let child = parentInstance.makeDelegatedChild(
                authority: authority,
                runtimeSessionID: runtimeSessionID,
                executableEvidence: executableEvidence,
                assurance: assurance,
                groupLeader: groupLeader,
                workloadProcess: workloadProcess,
                mintedAt: mintedAt
            )
        else {
            return nil
        }
        guard announce(child) else { return nil }
        // The announce above performs journal I/O outside the lock. Re-check
        // liveness after it: a parent that died mid-delegation delegates
        // nothing, so the just-announced child is revoked and refused.
        let parentAlive = state.withLock { $0.byInstance[parent]?.validity == .active }
        guard parentAlive else {
            _ = finishRuntime(runtimeSessionID, reason: .cancelled)
            return nil
        }
        return child
    }

    private func journalRecord(
        _ instance: AgentInstance,
        kind: AgentInstanceJournalRecord.Kind,
        detail: String?
    ) -> AgentInstanceJournalRecord {
        AgentInstanceJournalRecord(
            kind: kind,
            instance: instance.id.rawValue,
            workspace: instance.workspaceSessionID.rawValue,
            runtime: instance.runtimeSessionID.rawValue,
            definition: instance.definitionID.rawValue,
            revision: instance.definitionRevision.digestHex,
            ownerUID: instance.owner.uid,
            assurance: instance.assurance.rawValue,
            recordedAt: Date(),
            parent: instance.parent?.parentInstanceID.rawValue,
            detail: detail
        )
    }
}
