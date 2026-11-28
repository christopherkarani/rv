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
        /// Owner-action confirmation. Any authenticated local peer may ask;
        /// authority comes only from the presence proof rvd verifies in the
        /// handler (`OwnerPresence`), never from the caller's identity alone.
        case ownerConfirm
        /// Live events (`events`): read-only and redacted, but every
        /// agent's decisions pass through it, so only a kernel-attested
        /// peer running as rvd's own user (the owner) may read it: an XPC
        /// peer here, a socket peer through
        /// `ServiceRuntime.socketSessionReadsEvents`. No
        /// component role is needed for decisions (rv term reads them);
        /// asks, resolutions and session ids follow `pendingList`'s gate
        /// per caller (`LiveEventView`).
        case ownerEvents
        /// Loosen proposals (F2): file, list and decline. Any
        /// kernel-attested peer, agents included: none of these loosens
        /// anything. Approving is `decideProposal` too, but its authority
        /// comes only from the owner check rvd runs in the handler, on a
        /// prompt rvd builds from the stored row.
        case proposals
    }

    public static func requirement(for method: IPCMethod) -> Requirement {
        switch method {
        case .explain, .classify, .listPacks, .doctorSnapshot, .policyStatus:
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
        case .attestTTYRedemption, .mintAllowOnce:
            return .ttyAttestation
        case .events:
            return .ownerEvents
        case .confirmOwnerAction:
            return .ownerConfirm
        case .proposeLoosen, .listProposals, .decideProposal:
            return .proposals
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
            // Kernel-attested local peer (XPC audit token on macOS,
            // SO_PEERCRED same-user socket peer on Linux). No component
            // role is required: consult confers no authority, and one-click
            // installs have no admin trust manifest, so role-gating would
            // brick them. Capture failure stays fail-closed (peer nil).
            return context.peer != nil
        case .controlRead:
            switch context.componentRole {
            case .service, .workspaceHost:
                return context.peer != nil
            case .cli, .operatorUI, .mcpCustodian, .judge, nil:
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
            case .service, .workspaceHost, .operatorUI, .mcpCustodian, .judge, nil:
                return false
            }
        case .ttyAttestation:
            // Allow-once redeem and pre-arm. The matrix only admits the
            // caller; the owner approves in the handler
            // (`attestTTYRedemption`, `mintAllowOnce`), so no role here is
            // authority. Admitted: the pinned CLI and role-less
            // peers. Other pinned components have no business redeeming and
            // unauthenticated peers never get in.
            guard context.peer != nil else { return false }
            switch context.componentRole {
            case .cli:
                return true
            case .service, .workspaceHost, .operatorUI, .mcpCustodian, .judge:
                return false
            case nil:
                // A kernel-attested XPC peer (macOS one-click install, no
                // peer-trust manifest), where rvd shows its own owner
                // prompt, or a bare socket peer (Linux), which first asks
                // without a password to get rvd's description and then
                // sends the owner's password for the handler to verify.
                return true
            }
        case .ownerConfirm, .proposals:
            return context.peer != nil
        case .ownerEvents:
            // The same peer credential the transports capture (XPC audit
            // token euid, SO_PEERCRED uid), compared with rvd's own.
            guard let peer = context.peer else { return false }
            return peer.evidence.effectiveUserID == ownerUserID
        }
    }

    /// rvd's effective uid: the owner whose agents it guards.
    static var ownerUserID: UInt32 { UInt32(geteuid()) }
}
