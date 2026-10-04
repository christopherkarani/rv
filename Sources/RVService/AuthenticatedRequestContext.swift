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
        /// Hook consult: a pure policy question over a host envelope. The
        /// wire answer carries no execution authority (hooks gate a
        /// cooperating agent; same-user code can already exec directly),
        /// and Step 8B removed the spend path, so consult can never mint
        /// ALLOW from host input. Grant consumption on retry is
        /// availability-only: burning another row's grant forces re-ask,
        /// never execution.
        case hookConsult
        case controlRead
        case ownerMutation
        /// Untrusted launch proposals and proposal status. CLI-only; the
        /// proposal creates nothing authoritative until an authenticated
        /// host-prepared description arrives over the host bridge.
        case launchProposal
        /// Step 8B.1 genuine-CLI TTY attestation. The ONLY generic-IPC path
        /// that plants authority, and only because the trust anchor is the
        /// pinned CLI binary itself: manifest code identity + hardened
        /// runtime + in-binary ceremony order (peek-display → LA → attest).
        /// Same-user code cannot mint the identity; driving the genuine
        /// binary forces the human through LocalAuthentication. The daemon
        /// still re-validates every field and enforces per-epoch code
        /// single-use, so a buggy caller cannot plant garbage or doubles.
        case ttyAttestation
    }

    public static func requirement(for method: IPCMethod) -> Requirement {
        switch method {
        case .explain, .classify, .listPacks, .doctorSnapshot:
            return .diagnostic
        case .evaluate:
            return .agent
        case .hookEvaluate:
            return .hookConsult
        case .pendingList, .pendingWatch, .rulePreview:
            return .controlRead
        case .pendingResolve, .ruleSave, .setPackEnabled:
            return .ownerMutation
        case .proposeWorkspaceLaunch, .launchProposalStatus:
            return .launchProposal
        case .attestTTYRedemption:
            return .ttyAttestation
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
        case .hookConsult:
            // Kernel-attested local peer (XPC audit token). No component
            // role is required: consult confers no authority, and one-click
            // installs have no admin trust manifest, so role-gating would
            // brick them. Capture failure stays fail-closed (peer nil).
            return context.peer != nil
        case .controlRead:
            switch context.componentRole {
            case .service, .workspaceHost:
                return context.peer != nil
            case .cli, .operatorUI, nil:
                return false
            }
        case .ownerMutation:
            // Fresh operation-bound owner authorization must be consumed in the
            // mutation path. A signed CLI cannot create that authorization.
            return false
        case .launchProposal:
            // Authenticated CLI may propose and poll status. The proposal is
            // untrusted input; authority arrives only via the host bridge.
            switch context.componentRole {
            case .cli:
                return context.peer != nil
            case .service, .workspaceHost, .operatorUI, nil:
                return false
            }
        case .ttyAttestation:
            // Pinned genuine CLI only (manifest identity + hardened
            // runtime, assigned by the peer authenticator). The role proves
            // WHICH code attests; the in-binary ceremony (display → LA →
            // attest) proves a human reviewed and authenticated. Every
            // other role — including unauthenticated same-user peers —
            // fails closed here.
            switch context.componentRole {
            case .cli:
                return context.peer != nil
            case .service, .workspaceHost, .operatorUI, nil:
                return false
            }
        }
    }
}
