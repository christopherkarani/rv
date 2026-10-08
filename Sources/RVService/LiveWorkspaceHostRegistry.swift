import Foundation
import RVDomain
import RVIPC
import RVIsolation

/// A service-local result of one live host validation, never a cached permission.
/// It does not authenticate an agent caller or enable service dispatch.
struct ServiceValidatedAgentContext: Sendable {
    let reference: AgentPrincipalReference
    let hostConnectionID: UUID

    fileprivate init(reference: AgentPrincipalReference, hostConnectionID: UUID) {
        self.reference = reference
        self.hostConnectionID = hostConnectionID
    }
}

/// One authenticated host-prepared description plus the live transport identity
/// it arrived over. The description's own bindings are authoritative; the
/// connection ID binds Step 3 registration for disconnect invalidation.
struct HostPreparedLaunch: Sendable {
    let description: HostPreparedDescriptionDTO
    let hostConnectionID: UUID
}

/// Live registration triple for routing verification. Authoritative for which
/// incarnation a host ID names; descriptions must match it exactly.
struct LiveHostBinding: Sendable, Equatable {
    let workspace: WorkspaceSessionID
    let host: WorkspaceHostID
    let generation: WorkspaceHostGeneration
    let connectionID: UUID
}

enum LiveWorkspaceHostError: Error, Sendable, Equatable {
    case wrongComponentRole
    case duplicateRegistration
    case retiredIncarnation
    case unknownHost
    case peerMismatch
    case referenceMismatch
    case inactivePrincipal
    case validityRPCFailed
    case disconnected
    /// The registered host never offered preparation (predates the RPC).
    case prepareUnsupported
    /// The prepare reverse-RPC failed (transport, timeout, or peer change).
    case prepareRPCFailed
    /// The host refused preparation; the reason is a coarse machine-readable code.
    case prepareRefused(String)
    /// The registered host never offered redemption (predates the RPC).
    case redeemUnsupported
    /// The redeem reverse-RPC failed (transport, timeout, or peer change).
    /// The permit is already consumed and the host may or may not have
    /// launched: callers must record an unknown outcome, never retry.
    case redeemRPCFailed
    /// The live registration is no longer the exact channel the caller
    /// validated: a replacement landed between validation and commit.
    /// The commit is not delivered. Callers must record a terminal outcome
    /// (the permit stays consumed) and never retry.
    case staleRegistration
}

/// Ephemeral connection state only. The transport must capture authentic peer
/// evidence on each message and call disconnect before dropping a connection.
/// No registration is loaded from disk, and no positive validity is cached.
actor LiveWorkspaceHostRegistry {
    typealias Validate = @Sendable (AgentPrincipalReference) async throws -> AgentPrincipalValidity?
    typealias PrepareLaunch = @Sendable (HostPrepareRequestDTO) async throws -> HostPrepareResponseDTO
    typealias RedeemLaunch = @Sendable (HostRedeemCommitDTO) async throws -> HostRedeemResponseDTO

    private struct Registration: Sendable {
        let workspace: WorkspaceSessionID
        let host: WorkspaceHostID
        let generation: WorkspaceHostGeneration
        let peer: AuthenticatedPeer
        let epoch: UUID
        let validate: Validate
        let prepare: PrepareLaunch?
        let redeem: RedeemLaunch?
        let isConnected: @Sendable () -> Bool
    }

    private var hosts: [WorkspaceHostID: Registration] = [:]
    private var usedGenerations: Set<WorkspaceHostGeneration> = []
    private var usedConnections: Set<UUID> = []
    private var usedConnectionOrder: [UUID] = []
    /// Retired-connection memory bound. Connection entries outlive their
    /// usefulness once their session can no longer register (the race they
    /// win spans milliseconds); generations stay poisoned forever because
    /// incarnation identity must never recycle. The bound exceeds any
    /// plausible in-flight connection count by orders of magnitude.
    private static let maxRetiredConnections = 4_096

    /// Internal-only: a caller-supplied role, PID or owner token cannot enter.
    func register(
        peer: AuthenticatedPeer,
        workspace: WorkspaceSessionID,
        host: WorkspaceHostID,
        generation: WorkspaceHostGeneration,
        isConnected: @escaping @Sendable () -> Bool = { true },
        validate: @escaping Validate,
        prepare: PrepareLaunch? = nil,
        redeem: RedeemLaunch? = nil
    ) throws {
        guard peer.componentRole == .workspaceHost else {
            throw LiveWorkspaceHostError.wrongComponentRole
        }
        guard hosts[host] == nil,
              !hosts.values.contains(where: { $0.workspace == workspace }) else {
            throw LiveWorkspaceHostError.duplicateRegistration
        }
        guard !usedGenerations.contains(generation),
              !usedConnections.contains(peer.connectionID) else {
            throw LiveWorkspaceHostError.retiredIncarnation
        }
        guard isConnected() else { throw LiveWorkspaceHostError.disconnected }
        usedGenerations.insert(generation)
        retireConnection(peer.connectionID)
        hosts[host] = Registration(workspace: workspace, host: host,
            generation: generation, peer: peer, epoch: UUID(), validate: validate,
            prepare: prepare, redeem: redeem, isConnected: isConnected)
    }

    /// Transport teardown, keyed by its own connection identity, invalidates all
    /// in-flight validation before a replacement generation can register.
    func disconnect(connectionID: UUID) {
        hosts = hosts.filter { $0.value.peer.connectionID != connectionID }
        // Even a disconnect arriving ahead of registration prevents resurrection.
        retireConnection(connectionID)
    }

    /// Retires one connection ID with FIFO eviction past the bound. Oldest
    /// entries belong to long-dead sessions that can no longer register.
    private func retireConnection(_ connectionID: UUID) {
        guard usedConnections.insert(connectionID).inserted else { return }
        usedConnectionOrder.append(connectionID)
        while usedConnectionOrder.count > Self.maxRetiredConnections {
            usedConnections.remove(usedConnectionOrder.removeFirst())
        }
    }

    /// Retired-connection count. For tests.
    var retiredConnectionCount: Int {
        usedConnections.count
    }

    func resolve(_ reference: AgentPrincipalReference) async throws -> ServiceValidatedAgentContext {
        guard let registration = hosts[reference.workspaceHostID] else {
            throw LiveWorkspaceHostError.unknownHost
        }
        return try await resolve(reference, hostPeer: registration.peer)
    }

    /// `hostPeer` must come from fresh per-message authentication of the host
    /// response/channel. The callback is supplied only by trusted service code.
    func resolve(
        _ reference: AgentPrincipalReference,
        hostPeer: AuthenticatedPeer
    ) async throws -> ServiceValidatedAgentContext {
        guard let registration = hosts[reference.workspaceHostID] else {
            throw LiveWorkspaceHostError.unknownHost
        }
        guard hostPeer.componentRole == .workspaceHost,
              hostPeer == registration.peer else {
            throw LiveWorkspaceHostError.peerMismatch
        }
        guard reference.workspaceSessionID == registration.workspace,
              reference.workspaceHostGeneration == registration.generation else {
            throw LiveWorkspaceHostError.referenceMismatch
        }
        guard registration.isConnected() else { throw LiveWorkspaceHostError.disconnected }
        let response: AgentPrincipalValidity?
        do {
            response = try await registration.validate(reference)
        } catch {
            throw LiveWorkspaceHostError.validityRPCFailed
        }
        guard !Task.isCancelled, registration.isConnected(),
              hosts[registration.host]?.epoch == registration.epoch else {
            throw LiveWorkspaceHostError.disconnected
        }
        guard let response else { throw LiveWorkspaceHostError.inactivePrincipal }
        guard response.reference == reference else {
            throw LiveWorkspaceHostError.referenceMismatch
        }
        guard response.validity == .active else {
            throw LiveWorkspaceHostError.inactivePrincipal
        }
        return ServiceValidatedAgentContext(reference: reference,
            hostConnectionID: registration.peer.connectionID)
    }

    /// Authoritative live binding for routing verification, or nil when no
    /// live registration names this host. A snapshot, not permission: callers
    /// must still use `prepareProposal`, which re-checks at RPC time.
    func liveBinding(host: WorkspaceHostID) -> LiveHostBinding? {
        guard let registration = hosts[host], registration.isConnected() else {
            return nil
        }
        return LiveHostBinding(
            workspace: registration.workspace,
            host: registration.host,
            generation: registration.generation,
            connectionID: registration.peer.connectionID)
    }

    /// Asks the live registered host to prepare exactly one launch. The
    /// registered peer (never a caller-supplied identity) anchors the
    /// reverse-RPC; mid-RPC replacement fails via the epoch check, mirroring
    /// `resolve`. Returns the authenticated description plus the transport
    /// identity it arrived over. No redemption, no dispatch.
    func prepareProposal(
        host: WorkspaceHostID,
        request: HostPrepareRequestDTO
    ) async throws -> HostPreparedLaunch {
        guard let registration = hosts[host] else {
            throw LiveWorkspaceHostError.unknownHost
        }
        guard registration.isConnected() else { throw LiveWorkspaceHostError.disconnected }
        guard let prepare = registration.prepare else {
            throw LiveWorkspaceHostError.prepareUnsupported
        }
        let response: HostPrepareResponseDTO
        do {
            response = try await prepare(request)
        } catch {
            throw LiveWorkspaceHostError.prepareRPCFailed
        }
        guard !Task.isCancelled, registration.isConnected(),
              hosts[registration.host]?.epoch == registration.epoch else {
            throw LiveWorkspaceHostError.disconnected
        }
        guard let description = response.description else {
            throw LiveWorkspaceHostError.prepareRefused(response.error ?? "refused")
        }
        return HostPreparedLaunch(
            description: description,
            hostConnectionID: registration.peer.connectionID)
    }

    /// Commits one consumed permit's redemption to the live registered host.
    ///
    /// The caller must have atomically consumed the server-held permit first:
    /// this RPC carries the consumption assertion, not the authority to
    /// consume. `expectedConnection` must be the exact channel the caller
    /// validated: the resolved registration's channel is compared before
    /// the closure runs, so a replacement that lands between the caller's
    /// validation and this lookup fails instead of receiving a commit meant
    /// for the prior incarnation. Mid-RPC replacement fails via the epoch
    /// check, mirroring `prepareProposal`. Host refusals arrive as data;
    /// transport/peer failures throw. Either way the caller must not retry:
    /// the permit is spent and the host fence makes any duplicate safe, but
    /// no duplicate is ever sent.
    func redeemLaunch(
        host: WorkspaceHostID,
        expectedConnection: UUID,
        request: HostRedeemCommitDTO
    ) async throws -> HostRedeemResponseDTO {
        guard let registration = hosts[host] else {
            throw LiveWorkspaceHostError.unknownHost
        }
        guard registration.peer.connectionID == expectedConnection else {
            throw LiveWorkspaceHostError.staleRegistration
        }
        guard registration.isConnected() else { throw LiveWorkspaceHostError.disconnected }
        guard let redeem = registration.redeem else {
            throw LiveWorkspaceHostError.redeemUnsupported
        }
        let response: HostRedeemResponseDTO
        do {
            response = try await redeem(request)
        } catch {
            throw LiveWorkspaceHostError.redeemRPCFailed
        }
        guard !Task.isCancelled, registration.isConnected(),
              hosts[registration.host]?.epoch == registration.epoch else {
            throw LiveWorkspaceHostError.disconnected
        }
        return response
    }
}
