import Foundation
import RVDomain
import RVIPC
import RVIsolation
import RVPolicy

// MARK: - Operator ceremony service (Step 5)
//
// Production orchestration from untrusted proposal to authorized dispatch:
//
// CLI proposal → registered-host prepare RPC → ONE authenticated description
// → self-consistency verification → Step 3 pending → UI review → challenge →
// trusted completion → server-held permit → atomic consume → exactly one
// redemption commit to the live registered host → host accept → dispatch.
//
// Step 3 (WorkspaceOperatorAuthorizer) is frozen: this actor only calls its
// public API and retains service-side review state (descriptions, issued
// challenges, redemption outcomes) alongside it. Neither CLI nor UI can
// redeem: redemption runs here, synchronously inside trusted completion,
// exactly once per issued permit, and is never retried.

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
        case redemptionRequested
        case redemptionCompleted
        case redemptionFailed
    }

    let kind: Kind
    let operationID: UUID?
    let workspaceSessionID: UUID?
    let hostID: UUID?
    let generation: UUID?
    let preparedID: UUID?
    let intentDigestHex: String?
    let operationKind: String?
    /// Fresh runtime/instance IDs for a launched redemption. Identifiers for
    /// audit attribution only.
    let runtimeSessionID: UUID?
    let agentInstanceID: UUID?
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
        /// Propose-time live host channel. Redemption requires the current
        /// live binding to still be this exact channel.
        let hostConnectionID: UUID
        let createdWall: Date
        var challenge: OperatorAuthorizationChallenge?
    }

    private struct RedemptionRecord: Sendable {
        let outcome: LaunchResult
        let runtimeSessionID: UUID?
        let agentInstanceID: UUID?
        let recordedWall: Date
    }

    /// Bounded terminal outcomes for consumed permits. Same order as the
    /// Step 3 operation bound; oldest entries are evicted first.
    private static let maxRedemptionRecords = 64

    private let authorizer: WorkspaceOperatorAuthorizer
    private let hosts: LiveWorkspaceHostRegistry
    private let audit: (@Sendable (WorkspaceOperatorCeremonyAuditEvent) -> Void)?
    private let clock: @Sendable () -> Date
    private var reviews: [WorkspaceOperationAuthorizationID: RetainedReview] = [:]
    private var redemptions: [WorkspaceOperationAuthorizationID: RedemptionRecord] = [:]

    init(
        hosts: LiveWorkspaceHostRegistry = LiveWorkspaceHostRegistry(),
        authorizer: WorkspaceOperatorAuthorizer = WorkspaceOperatorAuthorizer(),
        audit: (@Sendable (WorkspaceOperatorCeremonyAuditEvent) -> Void)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.hosts = hosts
        self.authorizer = authorizer
        self.audit = audit
        self.clock = clock
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
            description: prepared.description,
            hostConnectionID: prepared.hostConnectionID,
            createdWall: clock(), challenge: nil)
        emit(.pendingCreated, operationID: reference.authorizationID.rawValue,
            description: prepared.description, outcome: "pendingReview")
        await prune()
        return ProposeLaunchReply(
            operationID: reference.authorizationID.rawValue, status: Self.status(.pending))
    }

    /// Pollable status for CLI. Safe status projection; never permit contents.
    /// Consumed operations additionally report their terminal launch outcome
    /// (and fresh runtime/instance IDs when launched) from the bounded
    /// redemption record. Polling never recreates authority.
    func proposalStatus(_ params: ProposalStatusParams) async -> ProposalStatusReply {
        let id = WorkspaceOperationAuthorizationID(rawValue: params.operationID)
        do {
            let status = try await authorizer.status(of: id)
            let record = redemptions[id]
            return ProposalStatusReply(
                operationID: params.operationID,
                status: Self.status(status),
                launchResult: record?.outcome,
                runtimeSessionID: record?.runtimeSessionID,
                agentInstanceID: record?.agentInstanceID)
        } catch {
            reviews.removeValue(forKey: id)
            redemptions.removeValue(forKey: id)
            return ProposalStatusReply(operationID: params.operationID, status: .unknown)
        }
    }

    // MARK: - UI review surface

    /// Reviewable operations (pending or awaiting authentication) with their
    /// retained descriptions. Prunes stale retentions first.
    func listReviewItems() async -> UIReviewListDTO {
        await prune()
        var items: [UIReviewItemDTO] = []
        // Snapshot: pruning below mutates the table during the walk.
        for (id, retained) in Array(reviews) {
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
    /// retained for completion validation. Re-binding from the owning
    /// connection resumes the live retained challenge instead of issuing:
    /// Step 3 issues only from pending, so without resumption navigating away
    /// from a bound review would brick it. Resumption is sound: the retained
    /// challenge is Step 3's own issuance to this connection, Step 3 still
    /// reports it live, and no Step 3 path re-issues over a live challenge —
    /// while any expiry, revocation, or completion race still fails closed at
    /// completion time.
    func bindReview(
        operationID: UUID,
        uiConnection: AuthenticatedOperatorUIConnectionID
    ) async throws -> (UIChallengeDTO, UIReviewItemDTO) {
        let id = WorkspaceOperationAuthorizationID(rawValue: operationID)
        guard var retained = reviews[id] else {
            throw WorkspaceOperatorCeremonyError.unknownOperation
        }
        if let live = retained.challenge,
            live.uiConnection == uiConnection,
            (try? await authorizer.status(of: id)) == .awaitingAuthentication {
            emit(.reviewBound, operationID: operationID,
                description: retained.description, outcome: "challenge resumed")
            return (challengeDTO(live), reviewItem(
                id: id, status: .awaitingAuthentication, retained: retained))
        }
        let challenge: OperatorAuthorizationChallenge
        do {
            challenge = try await authorizer.issueChallenge(
                operationID: id, uiConnection: uiConnection)
        } catch WorkspaceOperatorAuthorizationError.unknownOperation {
            reviews.removeValue(forKey: id)
            throw WorkspaceOperatorCeremonyError.unknownOperation
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
    ///
    /// On trusted authentication this synchronously redeems the issued
    /// permit exactly once (consume, then one commit RPC to the live
    /// registered host) before returning. The UI reply therefore reports
    /// the post-redemption status — usually `consumed` with a launch
    /// outcome readable via status polling — never a reusable authority.
    func completeCeremony(
        _ completion: UIOperatorCompletion,
        uiConnection: AuthenticatedOperatorUIConnectionID
    ) async throws -> WorkspaceOperationStatus {
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
            let reference = try await authorizer.completeChallenge(
                challenge, uiConnection: uiConnection, result: result)
            // Terminal: the retained challenge and description (argv included)
            // have no further use. Status stays readable via the authorizer.
            reviews.removeValue(forKey: id)
            await redeem(
                reference: reference,
                description: retained.description,
                hostConnectionID: retained.hostConnectionID)
            await prune()
            if let status = try? await authorizer.status(of: id) {
                return Self.status(status)
            }
            return .unknown
        } catch WorkspaceOperatorAuthorizationError.authenticationFailed {
            reviews.removeValue(forKey: id)
            return Self.status(.failed)
        } catch {
            throw mapAuthorizerError(error)
        }
    }

    // MARK: - Redemption (consume once, commit once, never retry)

    /// Consumes one issued permit and commits it to the exact live
    /// registered host, at most once per operation.
    ///
    /// Ordering and failure directions:
    ///
    /// 1. The current live host binding must still be the exact propose-time
    ///    incarnation and channel. Otherwise the permit is cancelled
    ///    (burned unconsumed) and no commit is sent.
    /// 2. The permit is atomically consumed for the exact expected bindings
    ///    (workspace, host, generation, registration, prepared ID, intent
    ///    digest, kind). Any mismatch burns the permit without a commit.
    /// 3. Exactly one commit RPC goes to the current registration. A host
    ///    refusal or failure is recorded as terminal. A transport failure
    ///    after consume is recorded as unknown: the host may or may not
    ///    have launched, and there is deliberately no retry and no second
    ///    commit — at-most-once beats recovery.
    private func redeem(
        reference: WorkspaceOperationAuthorizationReference,
        description: HostPreparedDescriptionDTO,
        hostConnectionID: UUID
    ) async {
        let id = reference.authorizationID
        let host = WorkspaceHostID(rawValue: description.hostID)
        guard let current = await hosts.liveBinding(host: host),
            current.workspace.rawValue == description.workspaceSessionID,
            current.host.rawValue == description.hostID,
            current.generation.rawValue == description.generation,
            current.connectionID == hostConnectionID,
            let kind = Self.operationKind(forTarget: description.target)
        else {
            // Stale registration or channel: burn the issued permit without
            // consuming it. Best-effort; the operation may already be
            // terminal (disconnect invalidation won the race).
            try? await authorizer.cancel(operationID: id)
            recordRedemption(id: id, outcome: .failed, runtime: nil, instance: nil)
            emit(.redemptionFailed, operationID: id.rawValue,
                description: description, outcome: "stale host registration")
            return
        }
        guard let definition = Self.definitionBinding(
            kind: kind,
            definitionID: description.definitionID,
            revisionDigest: description.revisionDigest)
        else {
            // The retained description passed verification at propose time,
            // so this is unreachable without memory corruption; burn closed.
            try? await authorizer.cancel(operationID: id)
            recordRedemption(id: id, outcome: .failed, runtime: nil, instance: nil)
            emit(.redemptionFailed, operationID: id.rawValue,
                description: description, outcome: "definition binding malformed")
            return
        }
        let expectation = WorkspaceOperationRedemptionExpectation(
            workspace: current.workspace,
            host: current.host,
            generation: current.generation,
            registration: WorkspaceHostRegistrationBinding(
                host: current.host,
                generation: current.generation,
                connectionID: current.connectionID),
            preparedLaunch: PreparedLaunchID(rawValue: description.preparedID),
            intentDigest: WorkspaceLaunchIntentDigest(sha256Hex: description.intentDigestHex),
            kind: kind,
            definition: definition)
        do {
            _ = try await authorizer.consumePermit(reference, expectation: expectation)
        } catch {
            // Consume failed: burn any still-authorized permit so a stale
            // authorization can never redeem later. Best-effort.
            try? await authorizer.cancel(operationID: id)
            recordRedemption(id: id, outcome: .failed, runtime: nil, instance: nil)
            emit(.redemptionFailed, operationID: id.rawValue,
                description: description, outcome: "permit not consumed")
            return
        }
        let commit = HostRedeemCommitDTO(
            authorizationID: id.rawValue,
            workspaceSessionID: current.workspace.rawValue,
            hostID: current.host.rawValue,
            generation: current.generation.rawValue,
            preparedID: description.preparedID,
            intentDigestHex: description.intentDigestHex,
            kind: kind == .launchAgent ? "launchAgent" : "launchCustom",
            definitionID: description.definitionID,
            revisionDigest: description.revisionDigest)
        emit(.redemptionRequested, operationID: id.rawValue,
            description: description, outcome: "commit sent")
        do {
            let response = try await hosts.redeemLaunch(
                host: current.host,
                expectedConnection: current.connectionID,
                request: commit)
            if response.accepted,
                let runtime = response.runtimeSessionID,
                let instance = response.agentInstanceID {
                recordRedemption(
                    id: id, outcome: .launched, runtime: runtime, instance: instance)
                emit(.redemptionCompleted, operationID: id.rawValue,
                    description: description, outcome: "launched",
                    runtime: runtime, instance: instance)
            } else if response.accepted {
                // Spent without a launch (host-side failure or an
                // in-flight duplicate's acceptance): terminal, no retry.
                recordRedemption(id: id, outcome: .failed, runtime: nil, instance: nil)
                emit(.redemptionFailed, operationID: id.rawValue,
                    description: description,
                    outcome: "host: \(Self.knownHostOutcome(response.error))")
            } else {
                recordRedemption(id: id, outcome: .failed, runtime: nil, instance: nil)
                emit(.redemptionFailed, operationID: id.rawValue,
                    description: description, outcome: "host refused")
            }
        } catch {
            recordRedemption(id: id, outcome: .unknown, runtime: nil, instance: nil)
            emit(.redemptionFailed, operationID: id.rawValue,
                description: description, outcome: "transport lost after consume")
        }
    }

    private func recordRedemption(
        id: WorkspaceOperationAuthorizationID,
        outcome: LaunchResult,
        runtime: UUID?,
        instance: UUID?
    ) {
        redemptions[id] = RedemptionRecord(
            outcome: outcome, runtimeSessionID: runtime,
            agentInstanceID: instance, recordedWall: clock())
        while redemptions.count > Self.maxRedemptionRecords {
            guard let oldest = redemptions.min(by: {
                $0.value.recordedWall < $1.value.recordedWall
            })?.key else { return }
            redemptions.removeValue(forKey: oldest)
        }
    }

    /// Maps the host's closed target vocabulary to the Step 3 operation
    /// kind. Nil rejects; anything outside the closed pair fails closed.
    static func operationKind(forTarget target: String) -> WorkspaceOperationKind? {
        switch target {
        case "named": .launchAgent
        case "custom": .launchCustom
        default: nil
        }
    }

    /// Rebuilds the definition binding for the consume expectation from the
    /// verified retained description: required (valid id plus 64-hex
    /// revision) for named launches, forbidden for custom. Nil fails
    /// closed. The outer Optional is the validation outcome; the inner is
    /// the kind-appropriate binding (nil for custom).
    static func definitionBinding(
        kind: WorkspaceOperationKind,
        definitionID: String?,
        revisionDigest: String?
    ) -> WorkspaceOperationDefinitionBinding?? {
        switch kind {
        case .launchAgent:
            guard let rawID = definitionID,
                let id = AgentDefinitionID(validating: rawID),
                let revisionHex = revisionDigest,
                Self.isLowerHex64(revisionHex)
            else {
                return nil
            }
            return .some(WorkspaceOperationDefinitionBinding(
                definitionID: id,
                revision: AgentDefinitionRevision(digestHex: revisionHex)))
        case .launchCustom:
            guard definitionID == nil, revisionDigest == nil else {
                return nil
            }
            return .some(nil)
        }
    }

    /// Collapses the host outcome code to the closed vocabulary before it
    /// reaches audit or API surfaces.
    static func knownHostOutcome(_ error: String?) -> String {
        guard let error, Self.knownRedeemOutcomes.contains(error) else {
            return "unknown"
        }
        return error
    }

    /// Exact outcome codes emitted by `WorkspaceHostRedeemHandler`. Closed:
    /// unknown codes collapse to "unknown".
    static let knownRedeemOutcomes: Set<String> = [
        "unknown", "alreadyAccepted", "launchFailed",
    ]

    /// Cancels a review. Pending operations (no challenge yet) may be cancelled
    /// by any authenticated UI; bound ceremonies only by their owning connection.
    func cancelReview(
        operationID: UUID,
        uiConnection: AuthenticatedOperatorUIConnectionID
    ) async throws -> WorkspaceOperationStatus {
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
            description: reviews[id]?.description, outcome: Self.status(status).rawValue)
        // Terminal: drop retention (challenge + argv). Status stays readable
        // via the authorizer; rebind of a cancelled op reports unknown.
        reviews.removeValue(forKey: id)
        return Self.status(status)
    }

    /// UI-facing status with retention pruning.
    func ceremonyStatus(operationID: UUID) async -> WorkspaceOperationStatus {
        let id = WorkspaceOperationAuthorizationID(rawValue: operationID)
        do {
            return Self.status(try await authorizer.status(of: id))
        } catch {
            reviews.removeValue(forKey: id)
            return .unknown
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
            !description.workingDirectory.isEmpty,
            description.workingDirectory.hasPrefix("/"),
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
        for id in Array(redemptions.keys) {
            if (try? await authorizer.status(of: id)) == nil {
                redemptions.removeValue(forKey: id)
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
            guard let definitionID = params.definitionID,
                !definitionID.isEmpty,
                definitionID.count <= WorkspaceControlLimits.maxProjectBytes,
                params.executable == nil,
                params.expectedDigest == nil
            else {
                return false
            }
            return true
        case "custom":
            guard params.definitionID == nil,
                let executable = params.executable,
                !executable.isEmpty,
                executable.utf8.count <= WorkspaceControlLimits.maxExecutableBytes,
                let expectedDigest = params.expectedDigest,
                Self.isLowerHex64(expectedDigest)
            else {
                return false
            }
            return true
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
        case .redeemUnsupported, .redeemRPCFailed, .staleRegistration:
            // Unreachable: the redeem path handles transport failures
            // directly (recording an unknown outcome, never an error).
            return .prepareFailed("unavailable")
        case .prepareRefused(let reason):
            // The host speaks a closed refusal vocabulary; anything else is
            // not forwarded verbatim to API/CLI surfaces.
            return .prepareFailed(
                Self.knownRefusalReasons.contains(reason) ? reason : "refused")
        }
    }

    /// Exact refusal codes emitted by `WorkspaceHostPrepareHandler` (plus the
    /// bridge's own `invalidRequest`). Closed: unknown reasons collapse.
    static let knownRefusalReasons: Set<String> = [
        "notAccepting", "invalidRequest", "preparationFailed",
        "unknownDefinition", "invalidDefinition", "projectNotEligible",
        "executableUnavailable", "invalidExecutable", "unsupportedExecutable",
        "credentialDeferred", "invalidDigest",
    ]

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

    static func status(_ status: WorkspaceOperationAuthorizationStatus) -> WorkspaceOperationStatus {
        switch status {
        case .pending: return .pendingReview
        case .awaitingAuthentication: return .awaitingAuthentication
        case .authorized: return .authorized
        case .consumed: return .consumed
        case .cancelled: return .cancelled
        case .expired: return .expired
        case .invalidated: return .invalidated
        case .failed: return .failed
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
            status: Self.status(status),
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
        outcome: String,
        runtime: UUID? = nil,
        instance: UUID? = nil
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
            runtimeSessionID: runtime,
            agentInstanceID: instance,
            wall: clock(),
            outcome: outcome))
    }
}
