import Foundation
import RVDomain
import RVIPC
import RVIsolation

// MARK: - Action-approval ceremony service (Step 6)
//
// Production orchestration from an authenticated ASK to an authorized resume:
//
// validated host ASK → live principal proof → ONE principal-bound approval
// → UI review → challenge → trusted completion → server-held grant → atomic
// consume for the exact parked continuation → host resumes exactly once.
//
// Step 3's launch authorizer is frozen and untouched: this actor owns a
// separate `ActionApprovalAuthorizer` plus service-side review state
// (retained actions for trusted display, issued challenges). Neither the
// agent, nor the CLI, nor the UI can consume: consumption runs here (via
// the authorizer's atomic gate) only for a live-validated principal
// presenting the exact action digest and continuation over the
// authenticated host bridge, and is never retried.

/// Ceremony-level audit event. Server-side review/ingestion facts only —
/// never credentials, capabilities, secrets, raw commands, or raw action
/// arguments. The action digest is descriptive; possessing it grants nothing.
struct ActionApprovalCeremonyAuditEvent: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case askReceived
        case approvalCreated
        case reviewBound
        case completionReceived
        case denyReceived
        case ceremonyCancelled
        case uiSessionAuthenticated
        case uiSessionInvalidated
        case consumeRequested
        case consumeCompleted
        case consumeRejected
    }

    let kind: Kind
    let approvalID: UUID?
    let principal: ActionApprovalPrincipal?
    let actionDigestHex: String?
    let continuationID: UUID?
    let wall: Date
    let outcome: String
}

enum ActionApprovalCeremonyError: Error, Sendable, Equatable {
    /// No live registered host matches, or the reference is not live now.
    case unknownPrincipal
    /// Malformed creation payload (shape, bounds, or reason vocabulary).
    case invalidAsk
    /// No such pending approval (never existed or pruned).
    case unknownApproval
    /// Approval not in a reviewable state for this UI connection.
    case notReviewable
    /// Presented bindings do not name this approval (wrong instance,
    /// action, or continuation). Which one is not disclosed.
    case bindingMismatch
    /// Step 6 store is full.
    case storeFull
    /// Authorizer rejected the transition (expired, terminal, mismatch).
    case authorizationRejected(String)
}

actor ActionApprovalCeremonyService {
    private struct RetainedReview: Sendable {
        let principal: ActionApprovalPrincipal
        /// Creation-time live host channel. Consume requires the current
        /// live binding to still be this exact channel.
        let hostConnectionID: UUID
        /// Trusted action under review (host-normalized, service-bound).
        /// Dropped the moment the approval turns terminal.
        let action: ProposedAction
        let actionDigestHex: String
        let continuationID: ActionApprovalContinuationID
        let reason: RuntimeAskReason
        let policyContext: String
        let createdWall: Date
        var challenge: ActionApprovalChallenge?
    }

    /// Descriptive policy-context bound. The context is display-only; this
    /// caps retained memory, not authority.
    private static let maxPolicyContextChars = 512

    private let authorizer: ActionApprovalAuthorizer
    private let hosts: LiveWorkspaceHostRegistry
    private let audit: (@Sendable (ActionApprovalCeremonyAuditEvent) -> Void)?
    private var reviews: [ActionApprovalID: RetainedReview] = [:]

    init(
        hosts: LiveWorkspaceHostRegistry = LiveWorkspaceHostRegistry(),
        authorizer: ActionApprovalAuthorizer = ActionApprovalAuthorizer(),
        audit: (@Sendable (ActionApprovalCeremonyAuditEvent) -> Void)? = nil
    ) {
        self.hosts = hosts
        self.authorizer = authorizer
        self.audit = audit
    }

    // MARK: - ASK ingestion (host → approval)

    /// Records one trusted-host ASK as a principal-bound approval.
    ///
    /// The host normalized `action` itself and evaluated its own policy to
    /// ASK; the host is trusted for both (it owns normalization and the
    /// gate decision). The service proves the presented reference live
    /// through the authoritative registry, derives the owner from the
    /// authenticated peer (never from host bytes), binds the exact action
    /// via its own digest, and mints the approval + continuation IDs. The
    /// definition facts are host-attested — definitions live host-side, as
    /// with named launch intents — while instance discrimination (the
    /// security property) comes from the live-validated instance ID.
    func requestApproval(
        _ dto: HostActionApprovalCreateDTO,
        hostPeer: AuthenticatedPeer
    ) async throws -> HostActionApprovalCreatedDTO {
        emit(.askReceived, approvalID: nil, principal: nil,
            digest: nil, continuation: nil, outcome: "received")
        guard let reason = Self.askReason(dto.reason),
            Self.validatedPolicyContext(dto.policyContext) != nil
        else {
            throw ActionApprovalCeremonyError.invalidAsk
        }
        let definitionID = dto.definitionID
        let revision = dto.definitionRevision
        guard !definitionID.rawValue.isEmpty, !revision.digestHex.isEmpty else {
            throw ActionApprovalCeremonyError.invalidAsk
        }
        let validated: ServiceValidatedAgentContext
        do {
            validated = try await hosts.resolve(dto.reference, hostPeer: hostPeer)
        } catch {
            throw ActionApprovalCeremonyError.unknownPrincipal
        }
        let principal = ActionApprovalPrincipal(
            instanceID: dto.reference.agentInstanceID,
            definitionID: definitionID,
            definitionRevision: revision,
            runtimeSessionID: dto.reference.runtimeSessionID,
            workspaceSessionID: dto.reference.workspaceSessionID,
            hostID: dto.reference.workspaceHostID,
            hostGeneration: dto.reference.workspaceHostGeneration,
            owner: OwnerPrincipal(uid: hostPeer.evidence.effectiveUserID))
        // The registry just proved every ID field live; the definition and
        // owner facts above come from the trusted host attestation and the
        // authenticated peer respectively. Re-check the channel binding the
        // resolution returned: a mid-RPC replacement must not create an
        // approval for a dead channel.
        guard let current = await hosts.liveBinding(host: principal.hostID),
            current.connectionID == validated.hostConnectionID
        else {
            throw ActionApprovalCeremonyError.unknownPrincipal
        }
        let created: (reference: ActionApprovalReference, continuationID: ActionApprovalContinuationID)
        do {
            created = try await authorizer.createApproval(
                principal: principal,
                hostConnectionID: validated.hostConnectionID,
                action: dto.action)
        } catch let error as ActionApprovalError {
            throw mapAuthorizerError(error)
        }
        let digest = CanonicalActionDigest.sha256Hex(of: dto.action)
        reviews[created.reference.approvalID] = RetainedReview(
            principal: principal,
            hostConnectionID: validated.hostConnectionID,
            action: dto.action,
            actionDigestHex: digest,
            continuationID: created.continuationID,
            reason: reason,
            policyContext: Self.validatedPolicyContext(dto.policyContext) ?? "",
            createdWall: Date(),
            challenge: nil)
        emit(.approvalCreated, approvalID: created.reference.approvalID.rawValue,
            principal: principal, digest: digest,
            continuation: created.continuationID.rawValue, outcome: "pendingReview")
        await prune()
        return HostActionApprovalCreatedDTO(
            approvalID: created.reference.approvalID.rawValue,
            continuationID: created.continuationID.rawValue,
            status: .pending)
    }

    // MARK: - Host status/consume/cancel

    /// Safe status for the host's parked continuation. Never consumes,
    /// never a grant, never authority. Unknown on any mismatch or doubt.
    func approvalStatus(
        _ dto: HostActionApprovalStatusDTO,
        hostPeer: AuthenticatedPeer
    ) async -> HostActionApprovalStatusReplyDTO {
        let id = ActionApprovalID(rawValue: dto.approvalID)
        guard let retained = reviews[id] else {
            // Retention is pruned the moment an approval turns terminal
            // (deny, cancel, completion cleanup), but the parked waiter
            // still needs the terminal word — "denied", not "unknown" —
            // to complete the continuation with the human's decision.
            // Consult the authorizer's truth, mirroring actionStatus.
            // Terminal strings grant nothing, and consume still requires
            // retention plus live bindings, so this projection cannot
            // authorize anything.
            if let status = try? await authorizer.status(of: id) {
                return HostActionApprovalStatusReplyDTO(status: Self.status(status))
            }
            return HostActionApprovalStatusReplyDTO(status: .unknown)
        }
        guard (try? await resolveAndMatch(retained, reference: dto.reference, hostPeer: hostPeer)) != nil
        else {
            return HostActionApprovalStatusReplyDTO(status: .unknown)
        }
        do {
            let status = try await authorizer.status(of: id)
            await pruneIfTerminal(id: id, status: status)
            return HostActionApprovalStatusReplyDTO(status: Self.status(status))
        } catch {
            reviews.removeValue(forKey: id)
            return HostActionApprovalStatusReplyDTO(status: .unknown)
        }
    }

    /// Consumes one grant for the host's exact parked continuation.
    ///
    /// `mayExecute` is true if and only if this call atomically consumed the
    /// grant for the exact presented bindings with the principal live
    /// before AND after the consumption. Any other answer means do not run.
    /// Once the approval turns terminal the ceremony forgets it, so replays
    /// answer `unknown` — fail-closed, with no oracle beyond the bit.
    func consumeApproval(
        _ dto: HostActionApprovalConsumeDTO,
        hostPeer: AuthenticatedPeer
    ) async -> HostActionApprovalDecisionDTO {
        let id = ActionApprovalID(rawValue: dto.approvalID)
        emit(.consumeRequested, approvalID: id.rawValue, principal: nil,
            digest: nil, continuation: nil, outcome: "requested")
        guard let retained = reviews[id] else {
            emit(.consumeRejected, approvalID: id.rawValue, principal: nil,
                digest: nil, continuation: nil, outcome: "unknown approval")
            return HostActionApprovalDecisionDTO(status: .unknown, mayExecute: false)
        }
        // Pre-consume liveness: the principal must be live right now.
        guard (try? await resolveAndMatch(retained, reference: dto.reference, hostPeer: hostPeer)) != nil
        else {
            emit(.consumeRejected, approvalID: id.rawValue, principal: retained.principal,
                digest: retained.actionDigestHex,
                continuation: retained.continuationID.rawValue, outcome: "principal not live")
            return HostActionApprovalDecisionDTO(status: .unknown, mayExecute: false)
        }
        // Presented-vs-retained binding check. The reference IDs were just
        // proved live AND equal to the retained principal; the digest and
        // continuation are compared again inside the atomic gate below, so
        // no interleaving can substitute them between here and consume.
        guard dto.actionDigestHex == retained.actionDigestHex,
            dto.continuationID == retained.continuationID.rawValue
        else {
            emit(.consumeRejected, approvalID: id.rawValue, principal: retained.principal,
                digest: retained.actionDigestHex,
                continuation: retained.continuationID.rawValue, outcome: "binding mismatch")
            return HostActionApprovalDecisionDTO(status: .unknown, mayExecute: false)
        }
        let reference = ActionApprovalReference(
            approvalID: id, epoch: authorizer.epoch)
        let expectation = ActionApprovalConsumeExpectation(
            principal: retained.principal,
            actionDigestHex: dto.actionDigestHex,
            continuationID: ActionApprovalContinuationID(rawValue: dto.continuationID))
        do {
            _ = try await authorizer.consumeGrant(reference, expectation: expectation)
        } catch {
            let liveStatus = try? await authorizer.status(of: id)
            let status = liveStatus.map(Self.status) ?? .unknown
            await pruneIfTerminal(id: id, status: liveStatus)
            emit(.consumeRejected, approvalID: id.rawValue, principal: retained.principal,
                digest: retained.actionDigestHex,
                continuation: retained.continuationID.rawValue, outcome: status.rawValue)
            return HostActionApprovalDecisionDTO(status: status, mayExecute: false)
        }
        // Post-consume liveness: revocation racing the atomic gate is
        // caught here. The grant stays spent; the action does not run.
        guard (try? await hosts.resolve(dto.reference, hostPeer: hostPeer)) != nil else {
            await authorizer.principalInvalidated(retained.principal.instanceID)
            reviews.removeValue(forKey: id)
            emit(.consumeRejected, approvalID: id.rawValue, principal: retained.principal,
                digest: retained.actionDigestHex,
                continuation: retained.continuationID.rawValue,
                outcome: "principal died after consume; grant spent, no execution")
            return HostActionApprovalDecisionDTO(status: .unknown, mayExecute: false)
        }
        reviews.removeValue(forKey: id)
        emit(.consumeCompleted, approvalID: id.rawValue, principal: retained.principal,
            digest: retained.actionDigestHex,
            continuation: retained.continuationID.rawValue, outcome: "consumed")
        return HostActionApprovalDecisionDTO(status: .consumed, mayExecute: true)
    }

    /// Host-driven cancel: its parked continuation went away. Idempotent;
    /// terminal approvals report their status, unknown stay unknown.
    func cancelApproval(
        _ dto: HostActionApprovalCancelDTO,
        hostPeer: AuthenticatedPeer
    ) async -> HostActionApprovalStatusReplyDTO {
        let id = ActionApprovalID(rawValue: dto.approvalID)
        guard let retained = reviews[id] else {
            // Same terminal projection as approvalStatus: a torn-down
            // park asks about an already-terminal approval; answer with
            // the authorizer's truth instead of unknown.
            if let status = try? await authorizer.status(of: id) {
                return HostActionApprovalStatusReplyDTO(status: Self.status(status))
            }
            return HostActionApprovalStatusReplyDTO(status: .unknown)
        }
        guard (try? await resolveAndMatch(retained, reference: dto.reference, hostPeer: hostPeer)) != nil
        else {
            return HostActionApprovalStatusReplyDTO(status: .unknown)
        }
        do {
            try await authorizer.cancel(approvalID: id)
        } catch {
            // Terminal already (or raced completion): report the truth below.
        }
        do {
            let status = try await authorizer.status(of: id)
            await pruneIfTerminal(id: id, status: status)
            emit(.ceremonyCancelled, approvalID: id.rawValue, principal: retained.principal,
                digest: retained.actionDigestHex,
                continuation: retained.continuationID.rawValue, outcome: Self.status(status).rawValue)
            return HostActionApprovalStatusReplyDTO(status: Self.status(status))
        } catch {
            reviews.removeValue(forKey: id)
            return HostActionApprovalStatusReplyDTO(status: .unknown)
        }
    }

    // MARK: - UI review surface

    /// Reviewable approvals (pending or awaiting authentication) with their
    /// trusted display projections. Prunes stale retentions first.
    func listActionReviews() async -> UIActionReviewListDTO {
        await prune()
        var items: [UIActionReviewItemDTO] = []
        // Snapshot: pruning below mutates the table during the walk.
        for (id, retained) in Array(reviews) {
            guard let status = try? await authorizer.status(of: id) else {
                reviews.removeValue(forKey: id)
                continue
            }
            switch status {
            case .pending, .awaitingAuthentication:
                items.append(Self.reviewItem(id: id, status: status, retained: retained))
            case .authorized, .consumed, .denied, .cancelled, .expired, .invalidated, .failed:
                continue
            }
        }
        items.sort { $0.approvalID.uuidString < $1.approvalID.uuidString }
        return UIActionReviewListDTO(items: items)
    }

    /// Binds one review to one authenticated UI connection: issues the
    /// challenge and returns it with the review item. Re-binding from the
    /// owning connection resumes the live retained challenge instead of
    /// issuing (mirroring the launch ceremony): without resumption,
    /// navigating away from a bound review would brick it. Resumption is
    /// sound for the same reason: the retained challenge is the
    /// authorizer's own issuance to this connection, the authorizer still
    /// reports it live, and every expiry, revocation, or completion race
    /// still fails closed at completion time.
    func bindActionReview(
        approvalID: UUID,
        uiConnection: AuthenticatedOperatorUIConnectionID
    ) async throws -> (UIActionChallengeDTO, UIActionReviewItemDTO) {
        let id = ActionApprovalID(rawValue: approvalID)
        guard var retained = reviews[id] else {
            throw ActionApprovalCeremonyError.unknownApproval
        }
        // The principal must still be live to open a review: no human
        // ceremony for a dead instance.
        guard (try? await hosts.resolve(Self.reference(of: retained.principal))) != nil else {
            await authorizer.principalInvalidated(retained.principal.instanceID)
            reviews.removeValue(forKey: id)
            throw ActionApprovalCeremonyError.unknownPrincipal
        }
        if let live = retained.challenge,
            live.uiConnection == uiConnection,
            (try? await authorizer.status(of: id)) == .awaitingAuthentication {
            emit(.reviewBound, approvalID: approvalID, principal: retained.principal,
                digest: retained.actionDigestHex,
                continuation: retained.continuationID.rawValue, outcome: "challenge resumed")
            return (Self.challengeDTO(live), Self.reviewItem(
                id: id, status: .awaitingAuthentication, retained: retained))
        }
        let challenge: ActionApprovalChallenge
        do {
            challenge = try await authorizer.issueChallenge(
                approvalID: id, uiConnection: uiConnection)
        } catch ActionApprovalError.unknownApproval {
            reviews.removeValue(forKey: id)
            throw ActionApprovalCeremonyError.unknownApproval
        } catch {
            throw ActionApprovalCeremonyError.notReviewable
        }
        retained.challenge = challenge
        reviews[id] = retained
        emit(.reviewBound, approvalID: approvalID, principal: retained.principal,
            digest: retained.actionDigestHex,
            continuation: retained.continuationID.rawValue, outcome: "challenge issued")
        return (Self.challengeDTO(challenge), Self.reviewItem(
            id: id, status: .awaitingAuthentication, retained: retained))
    }

    /// Applies one UI-reported allow-once outcome to the retained challenge.
    /// The presented IDs must name the retained ceremony; the retained
    /// challenge (service state, never wire bytes) enters the authorizer.
    /// The principal is re-proved live before the grant may issue.
    func completeActionCeremony(
        _ completion: UIActionCompletion,
        uiConnection: AuthenticatedOperatorUIConnectionID
    ) async throws -> HostActionApprovalStatus {
        let id = ActionApprovalID(rawValue: completion.approvalID)
        guard let retained = reviews[id],
            let challenge = retained.challenge,
            challenge.id.rawValue == completion.challengeID,
            challenge.approvalID == id
        else {
            throw ActionApprovalCeremonyError.unknownApproval
        }
        guard challenge.uiConnection == uiConnection else {
            throw ActionApprovalCeremonyError.notReviewable
        }
        emit(.completionReceived, approvalID: completion.approvalID,
            principal: retained.principal, digest: retained.actionDigestHex,
            continuation: retained.continuationID.rawValue,
            outcome: String(describing: completion.outcome))
        guard (try? await hosts.resolve(Self.reference(of: retained.principal))) != nil else {
            await authorizer.principalInvalidated(retained.principal.instanceID)
            reviews.removeValue(forKey: id)
            throw ActionApprovalCeremonyError.unknownPrincipal
        }
        let result = Self.trustedResult(completion.outcome)
        do {
            _ = try await authorizer.completeChallenge(
                challenge, uiConnection: uiConnection, result: result)
        } catch ActionApprovalError.authenticationFailed {
            reviews.removeValue(forKey: id)
            return Self.status(.failed)
        } catch {
            throw mapAuthorizerError(error)
        }
        // Trailing liveness: revocation racing the pre-check above must not
        // leave a fresh grant behind. The grant is invalidated here and the
        // review forgotten, so no consume can follow; the human sees an
        // unknown-principal failure, never a phantom approval.
        guard (try? await hosts.resolve(Self.reference(of: retained.principal))) != nil else {
            await authorizer.principalInvalidated(retained.principal.instanceID)
            reviews.removeValue(forKey: id)
            await prune()
            throw ActionApprovalCeremonyError.unknownPrincipal
        }
        // Grant issued: the retained challenge has no further use, but the
        // retained bindings must survive for the host's consume call. Only
        // terminal states drop retention, via prune.
        await prune()
        if let status = try? await authorizer.status(of: id) {
            await pruneIfTerminal(id: id, status: status)
            return Self.status(status)
        }
        return .unknown
    }

    /// Records an explicit human deny for the exact bound review. Terminal:
    /// no grant, and the original continuation fails. A later new action
    /// request is a new approval, unaffected.
    func denyActionCeremony(
        _ deny: UIActionDeny,
        uiConnection: AuthenticatedOperatorUIConnectionID
    ) async throws -> HostActionApprovalStatus {
        let id = ActionApprovalID(rawValue: deny.approvalID)
        guard let retained = reviews[id],
            let challenge = retained.challenge,
            challenge.id.rawValue == deny.challengeID,
            challenge.approvalID == id
        else {
            throw ActionApprovalCeremonyError.unknownApproval
        }
        guard challenge.uiConnection == uiConnection else {
            throw ActionApprovalCeremonyError.notReviewable
        }
        emit(.denyReceived, approvalID: deny.approvalID,
            principal: retained.principal, digest: retained.actionDigestHex,
            continuation: retained.continuationID.rawValue, outcome: "deny")
        do {
            try await authorizer.deny(challenge, uiConnection: uiConnection)
            reviews.removeValue(forKey: id)
            return Self.status(.denied)
        } catch {
            throw mapAuthorizerError(error)
        }
    }

    /// Releases the caller's own bound review without deciding it. Only the
    /// connection holding the live challenge may release it; anything else
    /// is not reviewable here. Terminal either way: no grant survives.
    func cancelActionReview(
        approvalID: UUID,
        uiConnection: AuthenticatedOperatorUIConnectionID
    ) async throws -> HostActionApprovalStatus {
        let id = ActionApprovalID(rawValue: approvalID)
        guard let retained = reviews[id] else {
            throw ActionApprovalCeremonyError.unknownApproval
        }
        if let challenge = retained.challenge {
            guard challenge.uiConnection == uiConnection else {
                throw ActionApprovalCeremonyError.notReviewable
            }
        } else {
            // No review is bound yet: nothing of this connection's to
            // release, and another connection's future bind must not be
            // preemptively killed from here.
            throw ActionApprovalCeremonyError.notReviewable
        }
        do {
            try await authorizer.cancel(approvalID: id)
        } catch ActionApprovalError.unknownApproval {
            reviews.removeValue(forKey: id)
            throw ActionApprovalCeremonyError.unknownApproval
        } catch {
            throw mapAuthorizerError(error)
        }
        reviews.removeValue(forKey: id)
        emit(.ceremonyCancelled, approvalID: approvalID, principal: retained.principal,
            digest: retained.actionDigestHex,
            continuation: retained.continuationID.rawValue, outcome: "cancelled by UI")
        return Self.status(.cancelled)
    }

    /// UI-facing status with retention pruning.
    func actionStatus(approvalID: UUID) async -> HostActionApprovalStatus {
        let id = ActionApprovalID(rawValue: approvalID)
        do {
            let status = try await authorizer.status(of: id)
            await pruneIfTerminal(id: id, status: status)
            return Self.status(status)
        } catch {
            reviews.removeValue(forKey: id)
            return .unknown
        }
    }

    // MARK: - Disconnect plumbing

    func uiConnectionLost(_ uiConnection: AuthenticatedOperatorUIConnectionID) async {
        await authorizer.uiDisconnected(uiConnection)
        // Every ceremony bound to the dead connection is now
        // terminal-invalidated; its retention (challenge, action, bindings)
        // is dropped. A later bind from a live connection correctly reports
        // unknown: the disconnected review is dead, and a new approval is a
        // new action request. Unbound pending approvals have no UI binding
        // yet and are untouched.
        await prune()
        emit(.uiSessionInvalidated, approvalID: nil, principal: nil,
            digest: nil, continuation: nil, outcome: "ui \(uiConnection.rawValue)")
    }

    func hostConnectionLost(connectionID: UUID) async {
        await authorizer.hostDisconnected(connectionID: connectionID)
        await prune()
    }

    func principalLost(_ instanceID: AgentInstanceID) async {
        await authorizer.principalInvalidated(instanceID)
        await prune()
    }

    func uiSessionAuthenticated() {
        emit(.uiSessionAuthenticated, approvalID: nil, principal: nil,
            digest: nil, continuation: nil, outcome: "registered")
    }

    // MARK: - Private

    /// Resolves the presented reference live and proves it names the
    /// retained approval's exact principal on the exact creation channel.
    /// On confident principal death, kills the approval's live records.
    private func resolveAndMatch(
        _ retained: RetainedReview,
        reference: AgentPrincipalReference,
        hostPeer: AuthenticatedPeer
    ) async throws -> ServiceValidatedAgentContext {
        let validated: ServiceValidatedAgentContext
        do {
            validated = try await hosts.resolve(reference, hostPeer: hostPeer)
        } catch let error as LiveWorkspaceHostError {
            if error == .inactivePrincipal, Self.idsMatch(retained.principal, reference: reference) {
                await authorizer.principalInvalidated(retained.principal.instanceID)
            }
            throw error
        }
        guard Self.idsMatch(retained.principal, reference: reference),
            validated.hostConnectionID == retained.hostConnectionID
        else {
            throw ActionApprovalCeremonyError.bindingMismatch
        }
        return validated
    }

    private static func idsMatch(
        _ principal: ActionApprovalPrincipal,
        reference: AgentPrincipalReference
    ) -> Bool {
        principal.instanceID == reference.agentInstanceID
            && principal.runtimeSessionID == reference.runtimeSessionID
            && principal.workspaceSessionID == reference.workspaceSessionID
            && principal.hostID == reference.workspaceHostID
            && principal.hostGeneration == reference.workspaceHostGeneration
    }

    private static func reference(of principal: ActionApprovalPrincipal) -> AgentPrincipalReference {
        AgentPrincipalReference(
            agentInstanceID: principal.instanceID,
            runtimeSessionID: principal.runtimeSessionID,
            workspaceSessionID: principal.workspaceSessionID,
            workspaceHostID: principal.hostID,
            workspaceHostGeneration: principal.hostGeneration)
    }

    private static func askReason(_ raw: String) -> RuntimeAskReason? {
        switch raw {
        case "mandatoryHuman": return .mandatoryHuman
        case "reviewAsk": return .reviewAsk
        default: return nil
        }
    }

    private static func validatedPolicyContext(_ raw: String) -> String? {
        guard raw.count <= maxPolicyContextChars else { return nil }
        return raw
    }

    private static func trustedResult(
        _ outcome: UIAuthenticationOutcome
    ) -> OperatorAuthenticationResult {
        switch outcome {
        case .authenticated: return .authenticated
        case .cancelled: return .cancelled
        case .unavailable: return .unavailable
        case .timedOut, .invalidated, .failed: return .failed
        }
    }

    private static func status(_ status: ActionApprovalStatus) -> HostActionApprovalStatus {
        switch status {
        case .pending: return .pending
        case .awaitingAuthentication: return .awaitingAuthentication
        case .authorized: return .authorized
        case .consumed: return .consumed
        case .denied: return .denied
        case .cancelled: return .cancelled
        case .expired: return .expired
        case .invalidated: return .invalidated
        case .failed: return .failed
        }
    }

    private func mapAuthorizerError(_ error: Error) -> ActionApprovalCeremonyError {
        if let error = error as? ActionApprovalError {
            switch error {
            case .storeFull: return .storeFull
            case .unknownApproval: return .unknownApproval
            case .invalidRequest: return .invalidAsk
            case .wrongEpoch, .stateMismatch, .bindingMismatch, .expired,
                .consumed, .authenticationFailed, .principalInvalid:
                return .authorizationRejected(String(describing: error))
            }
        }
        return .authorizationRejected("unknown")
    }

    private func pruneIfTerminal(id: ActionApprovalID, status: ActionApprovalStatus?) async {
        guard let status else {
            reviews.removeValue(forKey: id)
            return
        }
        switch status {
        case .pending, .awaitingAuthentication, .authorized:
            break
        case .consumed, .denied, .cancelled, .expired, .invalidated, .failed:
            reviews.removeValue(forKey: id)
        }
    }

    /// Drops retained reviews the authorizer reports terminal or missing.
    /// Security never depends on this running: the authorizer enforces its
    /// own deadlines on every entry, and a stale retention only ever
    /// projects display or routes to the authorizer, which re-checks.
    private func prune() async {
        for (id, _) in Array(reviews) {
            guard let status = try? await authorizer.status(of: id) else {
                reviews.removeValue(forKey: id)
                continue
            }
            await pruneIfTerminal(id: id, status: status)
        }
    }

    // MARK: - Trusted display projection

    private static func challengeDTO(_ challenge: ActionApprovalChallenge) -> UIActionChallengeDTO {
        UIActionChallengeDTO(
            challengeID: challenge.id.rawValue,
            approvalID: challenge.approvalID.rawValue,
            actionDigestHex: challenge.actionDigestHex,
            uiConnectionID: challenge.uiConnection.rawValue,
            issuedWall: challenge.issuedWall,
            advisoryLifetimeSeconds: ActionApprovalLimits.challengeLifetime)
    }

    private static func reviewItem(
        id: ActionApprovalID,
        status: ActionApprovalStatus,
        retained: RetainedReview
    ) -> UIActionReviewItemDTO {
        let projected = Self.project(retained.action)
        let reason: String = switch retained.reason {
        case .mandatoryHuman: "mandatoryHuman"
        case .reviewAsk: "reviewAsk"
        }
        return UIActionReviewItemDTO(
            approvalID: id.rawValue,
            instanceID: retained.principal.instanceID.rawValue,
            definitionID: retained.principal.definitionID.rawValue,
            definitionRevisionDigest: retained.principal.definitionRevision.digestHex,
            runtimeSessionID: retained.principal.runtimeSessionID.rawValue,
            workspaceSessionID: retained.principal.workspaceSessionID.rawValue,
            hostID: retained.principal.hostID.rawValue,
            actionKind: projected.kind,
            exactTarget: projected.target,
            exactArguments: projected.arguments,
            policyReason: reason,
            scopeSummary: "Allow once: this exact action, single use.",
            actionDigestHex: retained.actionDigestHex,
            status: Self.status(status),
            advisoryExpiresWall: retained.createdWall.addingTimeInterval(
                ActionApprovalLimits.approvalLifetime))
    }

    /// Projects the bound action onto trusted display fields. The action is
    /// sanitized for display (secret-shaped values redacted); the
    /// authorization itself binds the unredacted digest, shown alongside so
    /// the exact authority stays inspectable. Nothing is truncated: the UI
    /// renders full values (scrolling) and escapes control/bidi content.
    private static func project(_ action: ProposedAction) -> (kind: String, target: String, arguments: String) {
        let sanitized = ReviewSanitizer.sanitize(action)
        switch sanitized {
        case .shell(let shell):
            let effects = shell.effects.kinds.map(effectLabel).joined(separator: ", ")
            let kind = effects.isEmpty ? "shell" : "shell: \(effects)"
            let target = shell.scope.workingDirectory?.rawValue ?? "."
            let command = shell.supportingCommand?.rawValue ?? shell.fingerprint.rawValue
            return (kind, target, command)
        case .file(let file):
            let kind = "file \(file.file.kind.ledgerName.lowercased())"
            let target = file.file.path.rawValue
            let scope = file.scope.workingDirectory?.rawValue ?? "."
            return (kind, target, "\(file.file.kind.ledgerName) in \(scope)")
        case .http(let http):
            let kind = "https get"
            let target = http.destination.auditedResource
            let address = http.destination.address.map { "\($0)" } ?? "unresolved"
            return (kind, target, "\(http.method.rawValue) \(http.destination.host):\(http.destination.port)\(http.destination.path) → \(address)")
        }
    }

    private static func effectLabel(_ kind: ActionEffectKind) -> String {
        switch kind {
        case .remoteSharedBranchMutation: return "shared branch mutation"
        case .remoteBranchMutation: return "remote branch mutation"
        case .localBranchCreate: return "create local branch"
        case .workingTreeDiscard: return "discard working tree"
        case .filesystemDelete: return "delete file"
        case .filesystemMove: return "move file"
        case .filesystemOverwrite: return "overwrite file"
        case .filesystemModeChange: return "change file mode"
        case .filesystemCreate: return "create file"
        case .filesystemRead: return "read file"
        case .protectedPathMutation: return "protected path mutation"
        case .outsideRepositoryMutation: return "outside repository mutation"
        case .unresolvedFilesystem: return "unresolved filesystem path"
        }
    }

    private func emit(
        _ kind: ActionApprovalCeremonyAuditEvent.Kind,
        approvalID: UUID?,
        principal: ActionApprovalPrincipal?,
        digest: String?,
        continuation: UUID?,
        outcome: String
    ) {
        guard let audit else { return }
        audit(ActionApprovalCeremonyAuditEvent(
            kind: kind,
            approvalID: approvalID,
            principal: principal,
            actionDigestHex: digest,
            continuationID: continuation,
            wall: Date(),
            outcome: outcome))
    }
}
