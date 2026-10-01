import Foundation
import RVDomain
import Synchronization

/// Host-owned, point-in-time principal lookup. Its replies are descriptive
/// data: the receiver must authenticate the host and validate its live channel.
/// A successful return cannot authorize later use after revocation or close.
public final class WorkspacePrincipalAuthority: Sendable {
    public let workspace: WorkspaceSessionID
    public let host: WorkspaceHostID
    public let generation: WorkspaceHostGeneration
    private let registry: AgentInstanceRegistry
    private let closed = Mutex(false)

    init(
        registry: AgentInstanceRegistry,
        workspace: WorkspaceSessionID,
        host: WorkspaceHostID,
        generation: WorkspaceHostGeneration = WorkspaceHostGeneration()
    ) {
        self.registry = registry
        self.workspace = workspace
        self.host = host
        self.generation = generation
    }

    /// Only an active, registry-owned runtime can receive a reference.
    public func reference(forRuntime runtime: RuntimeSessionID) -> AgentPrincipalReference? {
        guard closed.withLock({ !$0 }),
            let instance = registry.instance(forRuntime: runtime)
        else { return nil }
        let reference = AgentPrincipalReference(
            agentInstanceID: instance.id,
            runtimeSessionID: runtime,
            workspaceSessionID: workspace,
            workspaceHostID: host,
            workspaceHostGeneration: generation
        )
        return resolve(reference)?.reference
    }

    /// Rechecks the live registry on every call. Close and lookup serialize;
    /// a close that wins the final check makes this lookup fail. Registry
    /// revocation linearizes at its own snapshot, never at a cached response.
    public func resolve(_ reference: AgentPrincipalReference) -> AgentPrincipalValidity? {
        guard reference.workspaceSessionID == workspace,
            reference.workspaceHostID == host,
            reference.workspaceHostGeneration == generation,
            closed.withLock({ !$0 })
        else { return nil }
        return closed.withLock { isClosed in
            guard !isClosed,
                let context = registry.context(for: reference.agentInstanceID),
                context.validity == .active,
                context.instance.runtimeSessionID == reference.runtimeSessionID,
                context.instance.workspaceSessionID == reference.workspaceSessionID
            else { return nil }
            return AgentPrincipalValidity(reference: reference, validity: .active)
        }
    }

    /// Irreversible invalidation for this host incarnation.
    public func close() {
        closed.withLock { $0 = true }
    }
}
