import Foundation
import RVDomain
import RVIPC
import RVIsolation

/// A validated component is not a human and is not an Agent Instance.
public typealias TrustedRVComponentRole = RVIsolation.TrustedRVComponentRole

/// Non-wire state captured by the transport before crossing an actor boundary.
/// There is deliberately no Codable conformance or public memberwise initializer.
public struct AuthenticatedRequestContext: Sendable {
    public let connectionID: UUID
    public let peer: AuthenticatedPeer?
    public let componentRole: TrustedRVComponentRole?

    // Generic IPC never creates a principal from names. The dedicated host bridge
    // uses its service-local validated context and live RPC checks instead.
    // External hook/client principal dispatch remains unavailable in Phase 2A.
    public let agent: AuthenticatedAgentContext?

    public static var unauthenticated: Self {
        Self(connectionID: UUID(), peer: nil, componentRole: nil, agent: nil)
    }

    private init(
        connectionID: UUID,
        peer: AuthenticatedPeer?,
        componentRole: TrustedRVComponentRole?,
        agent: AuthenticatedAgentContext?
    ) {
        self.connectionID = connectionID
        self.peer = peer
        self.componentRole = componentRole
        self.agent = agent
    }

    internal static func captured(peer: AuthenticatedPeer, connectionID: UUID) -> Self {
        Self(
            connectionID: connectionID,
            peer: peer,
            componentRole: peer.componentRole,
            agent: nil
        )
    }
}

/// Exhaustive method matrix. No payload field contributes a role or principal.
public enum ServiceMethodAuthorization {
    public enum Requirement: Sendable, Equatable {
        case diagnostic
        case agent
        case controlRead
        case ownerMutation
    }

    public static func requirement(for method: IPCMethod) -> Requirement {
        switch method {
        case .explain, .classify, .listPacks, .doctorSnapshot:
            return .diagnostic
        case .evaluate, .hookEvaluate:
            return .agent
        case .pendingList, .pendingWatch, .rulePreview:
            return .controlRead
        case .pendingResolve, .ruleSave, .setPackEnabled:
            return .ownerMutation
        }
    }

    public static func permits(_ method: IPCMethod, context: AuthenticatedRequestContext) -> Bool {
        switch requirement(for: method) {
        case .diagnostic:
            return true
        case .agent:
            // Generic external IPC has no authenticated runtime channel binding.
            // Instance-bound shell evaluation uses the dedicated authenticated
            // host bridge, with live principal validation around evaluation.
            return false
        case .controlRead:
            switch context.componentRole {
            case .service, .workspaceHost:
                return context.peer != nil
            case .cli, nil:
                return false
            }
        case .ownerMutation:
            // Fresh operation-bound owner authorization must be consumed in the
            // mutation path. A signed CLI cannot create that authorization.
            return false
        }
    }
}
