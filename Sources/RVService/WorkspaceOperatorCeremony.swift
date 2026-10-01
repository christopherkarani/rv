import Foundation
import RVDomain
import RVIPC
import RVIsolation
import RVPolicy

// MARK: - Operator ceremony service (Step 4)
//
// Production orchestration from untrusted proposal to server-held permit:
//
// CLI proposal → registered-host prepare RPC → ONE authenticated description
// → self-consistency verification → Step 3 pending → UI review → challenge →
// trusted completion → server-held permit. No redemption, no dispatch.
//
// Step 3 (WorkspaceOperatorAuthorizer) is frozen: this actor only calls its
// public API and retains service-side review state (descriptions, issued
// challenges) alongside it.

/// Ceremony-level audit event. Server-side review/ingestion facts only —
//    never credentials, capabilities, secrets, or argv.
struct WorkspaceOperatorCeremonyAuditEvent: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case proposalReceived
        case hostPrepareRequested
        case pendingCreated
        case reviewBound
        case completionReceived
        case ceremonyCancelled
        case uiSessionAuthenticated
        case uiSessionInvalidated
    }

    let kind: Kind
    let operationID: UUID?
    let workspaceSessionID: UUID?
    let hostID: UUID?
    let generation: UUID?
    let preparedID: UUID?
    let intentDigestHex: String?
    let operationKind: String?
    let wall: Date
    let outcome: String
}

enum WorkspaceOperatorCeremonyError: Error, Sendable, Equatable {
    /// No live registered host matches the proposal routing hints.
    case unknownHost
    /// The description disagrees with the live registration or itself.
    case descriptionMismatch
    /// The host refused or the prepare RPC failed (coarse reason).
    case prepareFailed(String)
    /// Malformed proposal (shape, bounds, or kind).
    case invalidProposal
    /// No such pending operation (never existed or pruned).
    case unknownOperation
    /// Operation not in a reviewable state for this UI connection.
    case notReviewable
    /// Step 3 store is full.
    case storeFull
    /// Step 3 rejected the transition (expired, terminal, mismatch).
    case authorizationRejected(String)
}

actor WorkspaceOperatorCeremonyService {
    private struct RetainedReview: Sendable {
        let description: HostPreparedDescriptionDTO
        let createdWall: Date
        var challenge: OperatorAuthorizationChallenge?
    }

    private let authorizer: WorkspaceOperatorAuthorizer
    private let hosts: LiveWorkspaceHostRegistry
    private let audit: (@Sendable (WorkspaceOperatorCeremonyAuditEvent) -> Void)?
    private var reviews: [WorkspaceOperationAuthorizationID: RetainedReview] = [:]

    init(
        hosts: LiveWorkspaceHostRegistry = LiveWorkspaceHostRegistry(),
        authorizer: WorkspaceOperatorAuthorizer = WorkspaceOperatorAuthorizer(),
        audit: (@Sendable (WorkspaceOperatorCeremonyAuditEvent) -> Void)? = nil
    ) {
        self.hosts = hosts
        self.authorizer = authorizer
        self.audit = audit
    }

    // MARK: - Proposal ingestion (CLI → host → Step 3)

    /// Ingests one untrusted proposal. Routes by hints, prepares over the
    /// authenticated host bridge, verifies the single returned description,
    /// and creates Step 3 state from that description alone. Proposal fields
    /// never enter pending state directly.
    func propose(
        _ params: ProposeLaunchParams,
        requester: WorkspaceAuthorizationRequester,
        clientRequestID: UUID?
    ) async throws -> ProposeLaunchReply {
        emit(.proposalReceived, operationID: nil, description: nil, outcome: "received")
        guard validProposalShape(params) else {
            throw WorkspaceOperatorCeremonyError.invalidProposal
        }
        guard let hostHint = params.hostID,
            let workspaceHint = params.workspaceSessionID,
            let binding = await hosts.liveBinding(host: WorkspaceHostID(rawValue: hostHint)),
            binding.workspace == WorkspaceSessionID(rawValue: workspaceHint)
        else {
            throw WorkspaceOperatorCeremonyError.unknownHost
        }
        let request = HostPrepareRequestDTO(
            requestID: UUID(),
            kind: params.kind,
            definitionID: params.definitionID,
            executable: params.executable,
            expectedDigest: params.expectedDigest,
            arguments: params.arguments,
            io: params.io)
        emit(.hostPrepareRequested, operationID: nil, description: nil,
            outcome: "host \(binding.host.rawValue)")
        let prepared: HostPreparedLaunch
        do {
            prepared = try await hosts.prepareProposal(host: binding.host, request: request)
        } catch let error as LiveWorkspaceHostError {
            throw mapHostError(error)
        }
        // Re-fetch the live binding after the RPC: a mid-flight host
        // replacement must not validate a description from the old incarnation.
        guard let current = await hosts.liveBinding(host: binding.host) else {
            throw WorkspaceOperatorCeremonyError.unknownHost
        }
        let verified: VerifiedDescriptionBindings
        do {
            verified = try Self.verifiedBindings(
                prepared.description, requestID: request.requestID, binding: current)
        } catch {
            throw WorkspaceOperatorCeremonyError.descriptionMismatch
        }
        let reference: WorkspaceOperationAuthorizationReference
        do {
            reference = try await authorizer.createOperation(
                requester: requester,
                clientRequestID: clientRequestID,
                workspace: verified.workspace,
                host: verified.host,
                generation: verified.generation,
                registration: WorkspaceHostRegistrationBinding(
                    host: verified.host,
                    generation: verified.generation,
                    connectionID: prepared.hostConnectionID),
                preparedLaunch: PreparedLaunchID(rawValue: verified.preparedID),
                intentDigest: WorkspaceLaunchIntentDigest(sha256Hex: verified.intentDigestHex),
                kind: verified.kind,
                definition: verified.definition)
        } catch let error as WorkspaceOperatorAuthorizationError {
            throw mapAuthorizerError(error)
        }
        reviews[reference.authorizationID] = RetainedReview(
            description: prepared.description, createdWall: Date(), challenge: nil)
        emit(.pendingCreated, operationID: reference.authorizationID.rawValue,
            description: prepared.description, outcome: "pendingReview")
        await prune()
        return ProposeLaunchReply(
            operationID: reference.authorizationID.rawValue, status: Self.statusString(.pending))
    }

    /// Pollable status for CLI. Safe strings only; never permit contents.
    func proposalStatus(_ params: ProposalStatusParams) async -> ProposalStatusReply {
        let id = WorkspaceOperationAuthorizationID(rawValue: params.operationID)
        do {
            let status = try await authorizer.status(of: id)
            return ProposalStatusReply(
                operationID: params.operationID, status: Self.statusString(status))
        } catch {
            reviews.removeValue(forKey: id)
            return ProposalStatusReply(operationID: params.operationID, status: "unknown")
        }
    }

    // MARK: - UI review surface

    /// Reviewable operations (pending or awaiting authentication) with their
    /// retained descriptions. Prunes stale retentions first.
    func listReviewItems() async -> UIReviewListDTO {
        await prune()
        var items: [UIReviewItemDTO] = []
        for (id, retained) in reviews {
            guard let status = try? await authorizer.status(of: id) else {
                reviews.removeValue(forKey: id)
                continue
            }
            switch status {
            case .pending, .awaitingAuthentication:
                items.append(reviewItem(id: id, status: status, retained: retained))
            case .authorized, .consumed, .cancelled, .expired, .invalidated, .failed:
                continue
            }
        }
        items.sort { $0.operationID.uuidString < $1.operationID.uuidString }
        return UIReviewListDTO(items: items)
    }

    /// Binds one review to one authenticated UI connection: issues the Step 3
    /// challenge and returns it with the review item. The issued challenge is
    /// retained for completion validation.
    func bindReview(
        operationID: UUID,
        uiConnection: AuthenticatedOperatorUIConnectionID
    ) async throws -> (UIChallengeDTO, UIReviewItemDTO) {
        let id = WorkspaceOperationAuthorizationID(rawValue: operationID)
        guard var retained = reviews[id] else {
            throw WorkspaceOperatorCeremonyError.unknownOperation
        }
        let challenge: OperatorAuthorizationChallenge
        do {
            challenge = try await authorizer.issueChallenge(
                operationID: id, uiConnection: uiConnection)
        } catch {
            throw WorkspaceOperatorCeremonyError.notReviewable
        }
        retained.challenge = challenge
        reviews[id] = retained
        emit(.reviewBound, operationID: operationID,
            description: retained.description, outcome: "challenge issued")
        return (challengeDTO(challenge), reviewItem(
            id: id, status: .awaitingAuthentication, retained: retained))
    }

    /// Applies one UI-reported outcome to the retained challenge. The presented
    /// IDs must name the retained ceremony; the retained challenge (service
    /// state, never wire bytes) enters Step 3. Returns the terminal status.
    func completeCeremony(
        _ completion: UIOperatorCompletion,
        uiConnection: AuthenticatedOperatorUIConnectionID
    ) async throws -> String {
        let id = WorkspaceOperationAuthorizationID(rawValue: completion.operationID)
        guard let retained = reviews[id],
            let challenge = retained.challenge,
            challenge.id.rawValue == completion.challengeID,
            challenge.operationID == id
        else {
            throw WorkspaceOperatorCeremonyError.unknownOperation
        }
        guard challenge.uiConnection == uiConnection else {
            throw WorkspaceOperatorCeremonyError.notReviewable
        }
        let result = Self.trustedResult(completion.outcome)
        emit(.completionReceived, operationID: completion.operationID,
            description: retained.description, outcome: String(describing: completion.outcome))
        do {
            _ = try await authorizer.completeChallenge(
                challenge, uiConnection: uiConnection, result: result)
            return Self.statusString(.authorized)
        } catch WorkspaceOperatorAuthorizationError.authenticationFailed {
            return Self.statusString(.failed)
        } catch {
            throw mapAuthorizerError(error)
        }
    }

    /// Cancels a review. Pending operations (no challenge yet) may be cancelled
    /// by any authenticated UI; bound ceremonies only by their owning connection.
    func cancelReview(
        operationID: UUID,
        uiConnection: AuthenticatedOperatorUIConnectionID
    ) async throws -> String {
        let id = WorkspaceOperationAuthorizationID(rawValue: operationID)
        guard reviews[id] != nil else {
            throw WorkspaceOperatorCeremonyError.unknownOperation
        }
        if let challenge = reviews[id]?.challenge,
            challenge.uiConnection != uiConnection {
            throw WorkspaceOperatorCeremonyError.notReviewable
        }
        do {
            try await authorizer.cancel(operationID: id)
        } catch {
            throw mapAuthorizerError(error)
        }
        let status = (try? await authorizer.status(of: id)) ?? .cancelled
        emit(.ceremonyCancelled, operationID: operationID,
            description: reviews[id]?.description, outcome: Self.statusString(status))
        return Self.statusString(status)
    }

    /// UI-facing status with retention pruning.
    func ceremonyStatus(operationID: UUID) async -> String {
        let id = WorkspaceOperationAuthorizationID(rawValue: operationID)
        do {
            return Self.statusString(try await authorizer.status(of: id))
        } catch {
            reviews.removeValue(forKey: id)
            return "unknown"
        }
    }

    // MARK: - Disconnect plumbing

    func uiConnectionLost(_ uiConnection: AuthenticatedOperatorUIConnectionID) async {
        await authorizer.uiDisconnected(uiConnection)
        emit(.uiSessionInvalidated, operationID: nil, description: nil,
            outcome: "ui \(uiConnection.rawValue)")
    }

    func hostConnectionLost(connectionID: UUID) async {
        await authorizer.hostDisconnected(connectionID: connectionID)
        await prune()
    }

    func uiSessionAuthenticated() {
        emit(.uiSessionAuthenticated, operationID: nil, description: nil, outcome: "registered")
    }

    // MARK: - Description verification (pure, testable)

    struct VerifiedDescriptionBindings: Sendable, Equatable {
        let workspace: WorkspaceSessionID
        let host: WorkspaceHostID
        let generation: WorkspaceHostGeneration
        let preparedID: UUID
        let intentDigestHex: String
        let kind: WorkspaceOperationKind
        let definition: WorkspaceOperationDefinitionBinding?
    }

    /// Verifies ONE authenticated description is self-consistent and bound to
    /// the live registration: binding triple, request echo, target/kind/
    /// definition shape, digest formats, and — for custom — a full intent
    /// rebuild with digest recomparison. Named intents cannot be rebuilt
    /// service-side (definitions live host-side); their shape and digest
    /// format are verified, and the authenticated host is trusted for the rest.
    static func verifiedBindings(
        _ description: HostPreparedDescriptionDTO,
        requestID: UUID,
        binding: LiveHostBinding
    ) throws -> VerifiedDescriptionBindings {
        guard description.requestID == requestID,
            description.workspaceSessionID == binding.workspace.rawValue,
            description.hostID == binding.host.rawValue,
            description.generation == binding.generation.rawValue,
            isLowerHex64(description.intentDigestHex),
            isLowerHex64(description.environmentDigestHex),
            !description.executable.isEmpty,
            description.executable.hasPrefix("/"),
            description.expiresAt > description.preparedAt,
            description.arguments.count <= WorkspaceControlLimits.maxArguments,
            description.arguments.allSatisfy({
                $0.utf8.count <= WorkspaceControlLimits.maxArgumentBytes
            })
        else {
            throw WorkspaceOperatorCeremonyError.descriptionMismatch
        }
        switch description.target {
        case "named":
            guard let rawID = description.definitionID,
                AgentDefinitionID(validating: rawID) != nil,
                let revisionHex = description.revisionDigest,
                isLowerHex64(revisionHex),
                description.expectedDigest == nil
            else {
                throw WorkspaceOperatorCeremonyError.descriptionMismatch
            }
            return VerifiedDescriptionBindings(
                workspace: binding.workspace,
                host: binding.host,
                generation: binding.generation,
                preparedID: description.preparedID,
                intentDigestHex: description.intentDigestHex,
                kind: .launchAgent,
                definition: WorkspaceOperationDefinitionBinding(
                    definitionID: AgentDefinitionID(rawValue: rawID),
                    revision: AgentDefinitionRevision(digestHex: revisionHex)))
        case "custom":
            guard description.definitionID == nil,
                description.revisionDigest == nil,
                let expected = description.expectedDigest,
                AdHocAgentSnapshot.make(expectedContentDigestSHA256: expected) != nil
            else {
                throw WorkspaceOperatorCeremonyError.descriptionMismatch
            }
            // Full self-consistency: rebuild the custom intent from DTO fields
            // and require the recomputed digest to match the description.
            let rebuiltIO: WorkspaceLaunchIO
            switch description.io {
            case .discard:
                rebuiltIO = .discard
            case .pseudoTerminal(let rows, let columns):
                guard rows >= TerminalStreamLimits.minimumDimension,
                    rows <= TerminalStreamLimits.maximumRows,
                    columns >= TerminalStreamLimits.minimumDimension,
                    columns <= TerminalStreamLimits.maximumColumns
                else {
                    throw WorkspaceOperatorCeremonyError.descriptionMismatch
                }
                rebuiltIO = .pseudoTerminal(rows: rows, columns: columns)
            }
            guard case .success(let rebuilt) = WorkspaceLaunchIntent.makeCustom(
                executable: description.executable,
                expectedContentDigestSHA256: expected,
                workspaceSessionID: binding.workspace,
                workingDirectory: description.workingDirectory,
                arguments: description.arguments,
                io: rebuiltIO
            ),
                rebuilt.canonicalDigest.sha256Hex == description.intentDigestHex
            else {
                throw WorkspaceOperatorCeremonyError.descriptionMismatch
            }
            return VerifiedDescriptionBindings(
                workspace: binding.workspace,
                host: binding.host,
                generation: binding.generation,
                preparedID: description.preparedID,
                intentDigestHex: description.intentDigestHex,
                kind: .launchCustom,
                definition: nil)
        default:
            throw WorkspaceOperatorCeremonyError.descriptionMismatch
        }
    }

    static func isLowerHex64(_ value: String) -> Bool {
        value.count == 64
            && value.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    // MARK: - Private

    private func prune() async {
        for id in Array(reviews.keys) {
            if (try? await authorizer.status(of: id)) == nil {
                reviews.removeValue(forKey: id)
            }
        }
    }

    private func validProposalShape(_ params: ProposeLaunchParams) -> Bool {
        guard params.arguments.count <= WorkspaceControlLimits.maxArguments,
            params.arguments.allSatisfy({
                $0.utf8.count <= WorkspaceControlLimits.maxArgumentBytes
            }),
            !params.workspace.isEmpty,
            params.workspace.count <= WorkspaceControlLimits.maxProjectBytes
        else {
            return false
        }
        switch params.io {
        case .discard:
            break
        case .pseudoTerminal(let rows, let columns):
            guard rows >= TerminalStreamLimits.minimumDimension,
                rows <= TerminalStreamLimits.maximumRows,
                columns >= TerminalStreamLimits.minimumDimension,
                columns <= TerminalStreamLimits.maximumColumns
            else {
                return false
            }
        }
        switch params.kind {
        case "named":
            return params.definitionID != nil
                && params.executable == nil
                && params.expectedDigest == nil
        case "custom":
            return params.definitionID == nil
                && params.executable != nil
                && params.expectedDigest != nil
        default:
            return false
        }
    }

    private func mapHostError(_ error: LiveWorkspaceHostError) -> WorkspaceOperatorCeremonyError {
        switch error {
        case .unknownHost, .disconnected, .peerMismatch, .retiredIncarnation,
            .referenceMismatch, .inactivePrincipal, .validityRPCFailed:
            return .unknownHost
        case .wrongComponentRole, .duplicateRegistration:
            return .unknownHost
        case .prepareUnsupported, .prepareRPCFailed:
            return .prepareFailed("unavailable")
        case .prepareRefused(let reason):
            return .prepareFailed(reason)
        }
    }

    private func mapAuthorizerError(_ error: any Error) -> WorkspaceOperatorCeremonyError {
        guard let error = error as? WorkspaceOperatorAuthorizationError else {
            return .authorizationRejected("rejected")
        }
        switch error {
        case .storeFull:
            return .storeFull
        case .unknownOperation:
            return .unknownOperation
        case .expired, .consumed, .stateMismatch, .bindingMismatch, .wrongEpoch,
            .invalidRequest, .authenticationFailed:
            return .authorizationRejected("rejected")
        }
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

    static func statusString(_ status: WorkspaceOperationAuthorizationStatus) -> String {
        switch status {
        case .pending: return "pendingReview"
        case .awaitingAuthentication: return "awaitingAuthentication"
        case .authorized: return "authorized"
        case .consumed: return "consumed"
        case .cancelled: return "cancelled"
        case .expired: return "expired"
        case .invalidated: return "invalidated"
        case .failed: return "failed"
        }
    }

    private func reviewItem(
        id: WorkspaceOperationAuthorizationID,
        status: WorkspaceOperationAuthorizationStatus,
        retained: RetainedReview
    ) -> UIReviewItemDTO {
        let description = retained.description
        return UIReviewItemDTO(
            operationID: id.rawValue,
            kind: description.target == "named" ? "launchAgent" : "launchCustom",
            definitionID: description.definitionID,
            definitionRevisionDigest: description.revisionDigest,
            executable: description.executable,
            expectedContentDigest: description.expectedDigest,
            workspaceSessionID: description.workspaceSessionID,
            workingDirectory: description.workingDirectory,
            arguments: description.arguments,
            io: description.io,
            environmentPolicy: description.environmentPolicy,
            intentDigestHex: description.intentDigestHex,
            status: Self.statusString(status),
            advisoryExpiresWall: retained.createdWall
                .addingTimeInterval(WorkspaceOperatorAuthorizationLimits.operationLifetime))
    }

    private func challengeDTO(_ challenge: OperatorAuthorizationChallenge) -> UIChallengeDTO {
        UIChallengeDTO(
            challengeID: challenge.id.rawValue,
            operationID: challenge.operationID.rawValue,
            intentDigestHex: challenge.intentDigest.sha256Hex,
            kind: challenge.kind == .launchAgent ? "launchAgent" : "launchCustom",
            uiConnectionID: challenge.uiConnection.rawValue,
            issuedWall: challenge.issuedWall,
            advisoryLifetimeSeconds: WorkspaceOperatorAuthorizationLimits.challengeLifetime)
    }

    private func emit(
        _ kind: WorkspaceOperatorCeremonyAuditEvent.Kind,
        operationID: UUID?,
        description: HostPreparedDescriptionDTO?,
        outcome: String
    ) {
        guard let audit else { return }
        audit(WorkspaceOperatorCeremonyAuditEvent(
            kind: kind,
            operationID: operationID,
            workspaceSessionID: description?.workspaceSessionID,
            hostID: description?.hostID,
            generation: description?.generation,
            preparedID: description?.preparedID,
            intentDigestHex: description?.intentDigestHex,
            operationKind: description?.target,
            wall: Date(),
            outcome: outcome))
    }
}
