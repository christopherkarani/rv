import Foundation
import RVDomain
import RVIPC
import Synchronization
import Testing
@testable import RVIsolation
@testable import RVService

/// Step 6 ceremony logic: creation from live-validated principals, trusted
/// UI completion binding, deny semantics, and consume-once resume. Validity
/// is driven by controllable fake RPCs; these tests do not prove platform
/// role assignment or transport authenticity.
@Suite("Action approval ceremony logic")
struct ActionApprovalCeremonyTests {
    private func peer(
        role: TrustedRVComponentRole? = .workspaceHost,
        connectionID: UUID = UUID(),
        uid: UInt32 = 501
    ) -> AuthenticatedPeer {
        let code = PeerCodeIdentity(identifier: "ceremony-fixture", teamIdentifier: nil,
            cdHash: Data([7]), executablePath: "/ceremony-fixture", isAdHoc: true,
            hardenedRuntime: true, injectionExceptions: [])
        return AuthenticatedPeer(evidence: PlatformPeerEvidence(processID: 1,
            effectiveUserID: uid, auditToken: Data([7]), codeIdentity: code,
            componentRole: role), connectionID: connectionID)
    }

    private func reference() -> AgentPrincipalReference {
        AgentPrincipalReference(agentInstanceID: AgentInstanceID(),
            runtimeSessionID: RuntimeSessionID(), workspaceSessionID: WorkspaceSessionID(),
            workspaceHostID: WorkspaceHostID(), workspaceHostGeneration: WorkspaceHostGeneration())
    }

    private func action(_ command: String = "echo hello") -> ProposedAction {
        .shell(ShellAction(
            fingerprint: ActionFingerprint(rawValue: "ceremony:\(command)"),
            scope: ActionScope(workingDirectory: WorkingDirectory(rawValue: "/work")),
            supportingCommand: ShellCommand(rawValue: command)))
    }

    private func createDTO(
        reference: AgentPrincipalReference,
        action: ProposedAction? = nil,
        reason: String = "reviewAsk",
        policyContext: String = "runtime:/work"
    ) -> HostActionApprovalCreateDTO {
        HostActionApprovalCreateDTO(
            reference: reference,
            action: action ?? self.action(),
            reason: reason,
            policyContext: policyContext,
            definitionID: AgentDefinitionID(rawValue: "test-agent"),
            definitionRevision: AgentDefinitionRevision(digestHex: String(repeating: "c", count: 64)))
    }

    /// Controllable validity: starts active, `revoke()` kills it.
    private final class ValidityState: Sendable {
        private let validity = Mutex<AgentInstanceValidity>(.active)
        func read() -> AgentInstanceValidity { validity.withLock { $0 } }
        func revoke() { validity.withLock { $0 = .inactive } }
    }

    private func world(
        audit: (@Sendable (ActionApprovalCeremonyAuditEvent) -> Void)? = nil
    ) -> (hosts: LiveWorkspaceHostRegistry, ceremonies: ActionApprovalCeremonyService) {
        let hosts = LiveWorkspaceHostRegistry()
        return (hosts, ActionApprovalCeremonyService(hosts: hosts, audit: audit))
    }

    private func register(
        _ hosts: LiveWorkspaceHostRegistry,
        _ ref: AgentPrincipalReference,
        _ peer: AuthenticatedPeer,
        state: ValidityState? = nil
    ) async throws {
        let box = state
        try await hosts.register(peer: peer, workspace: ref.workspaceSessionID,
            host: ref.workspaceHostID, generation: ref.workspaceHostGeneration,
            validate: { reference in
                AgentPrincipalValidity(reference: reference, validity: box?.read() ?? .active)
            })
    }

    private func requested(
        _ ceremonies: ActionApprovalCeremonyService,
        dto: HostActionApprovalCreateDTO,
        peer: AuthenticatedPeer
    ) async throws -> HostActionApprovalCreatedDTO {
        try await ceremonies.requestApproval(dto, hostPeer: peer)
    }

    // MARK: - Creation

    @Test func askCreatesPrincipalBoundPendingApproval() async throws {
        let (hosts, ceremonies) = world()
        let ref = reference()
        let host = peer()
        try await register(hosts, ref, host)
        let created = try await requested(ceremonies, dto: createDTO(reference: ref), peer: host)
        #expect(created.status == .pending)
        let list = await ceremonies.listActionReviews()
        #expect(list.items.count == 1)
        let item = try #require(list.items.first)
        #expect(item.approvalID == created.approvalID)
        #expect(item.instanceID == ref.agentInstanceID.rawValue)
        #expect(item.definitionID == "test-agent")
        #expect(item.runtimeSessionID == ref.runtimeSessionID.rawValue)
        #expect(item.workspaceSessionID == ref.workspaceSessionID.rawValue)
        #expect(item.hostID == ref.workspaceHostID.rawValue)
        #expect(item.actionKind == "shell")
        #expect(item.policyReason == "reviewAsk")
        #expect(item.status == .pending)
    }

    @Test func ownerDerivesFromAuthenticatedPeer() async throws {
        let seen = Mutex<[ActionApprovalCeremonyAuditEvent]>([])
        let (hosts, ceremonies) = world(audit: { event in seen.withLock { $0.append(event) } })
        let ref = reference()
        let host = peer(uid: 502)
        try await register(hosts, ref, host)
        _ = try await requested(ceremonies, dto: createDTO(reference: ref), peer: host)
        let snapshot = seen.withLock({ $0 })
        let created = try #require(snapshot.first(where: { $0.kind == .approvalCreated }))
        #expect(created.principal?.owner == OwnerPrincipal(uid: 502))
        #expect(created.principal?.definitionID.rawValue == "test-agent")
    }

    @Test func deadPrincipalCannotCreate() async throws {
        let (hosts, ceremonies) = world()
        let ref = reference()
        let host = peer()
        let state = ValidityState()
        try await register(hosts, ref, host, state: state)
        await state.revoke()
        await #expect(throws: ActionApprovalCeremonyError.unknownPrincipal) {
            try await ceremonies.requestApproval(createDTO(reference: ref), hostPeer: host)
        }
        #expect(await ceremonies.listActionReviews().items.isEmpty)
    }

    @Test func unregisteredHostCannotCreate() async throws {
        let (hosts, ceremonies) = world()
        await #expect(throws: ActionApprovalCeremonyError.unknownPrincipal) {
            try await ceremonies.requestApproval(createDTO(reference: reference()), hostPeer: peer())
        }
    }

    @Test func invalidReasonVocabularyFailsClosed() async throws {
        let (hosts, ceremonies) = world()
        let ref = reference()
        let host = peer()
        try await register(hosts, ref, host)
        await #expect(throws: ActionApprovalCeremonyError.invalidAsk) {
            try await ceremonies.requestApproval(
                createDTO(reference: ref, reason: "alwaysAllow"), hostPeer: host)
        }
        #expect(await ceremonies.listActionReviews().items.isEmpty)
    }

    @Test func oversizedPolicyContextFailsClosed() async throws {
        let (hosts, ceremonies) = world()
        let ref = reference()
        let host = peer()
        try await register(hosts, ref, host)
        await #expect(throws: ActionApprovalCeremonyError.invalidAsk) {
            try await ceremonies.requestApproval(
                createDTO(reference: ref, policyContext: String(repeating: "x", count: 513)),
                hostPeer: host)
        }
    }

    // MARK: - Allow-once flow

    private func allowOnceSetup() async throws -> (
        hosts: LiveWorkspaceHostRegistry,
        ceremonies: ActionApprovalCeremonyService,
        reference: AgentPrincipalReference,
        peer: AuthenticatedPeer,
        created: HostActionApprovalCreatedDTO,
        digest: String,
        ui: AuthenticatedOperatorUIConnectionID,
        challenge: UIActionChallengeDTO
    ) {
        let (hosts, ceremonies) = world()
        let ref = reference()
        let host = peer()
        try await register(hosts, ref, host)
        let act = action()
        let created = try await requested(
            ceremonies, dto: createDTO(reference: ref, action: act), peer: host)
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await ceremonies.bindActionReview(
            approvalID: created.approvalID, uiConnection: ui)
        return (
            hosts, ceremonies, ref, host, created,
            CanonicalActionDigest.sha256Hex(of: act), ui, challenge)
    }

    @Test func allowOnceConsumesExactlyOnce() async throws {
        let setup = try await allowOnceSetup()
        let status = try await setup.ceremonies.completeActionCeremony(
            UIActionCompletion(
                challengeID: setup.challenge.challengeID,
                approvalID: setup.created.approvalID,
                outcome: .authenticated),
            uiConnection: setup.ui)
        #expect(status == .authorized)
        let decision = await setup.ceremonies.consumeApproval(
            HostActionApprovalConsumeDTO(
                approvalID: setup.created.approvalID,
                reference: setup.reference,
                actionDigestHex: setup.digest,
                continuationID: setup.created.continuationID),
            hostPeer: setup.peer)
        #expect(decision.status == .consumed)
        #expect(decision.mayExecute == true)
        // Replay: the ceremony forgot the terminal approval; unknown and
        // must not execute.
        let replay = await setup.ceremonies.consumeApproval(
            HostActionApprovalConsumeDTO(
                approvalID: setup.created.approvalID,
                reference: setup.reference,
                actionDigestHex: setup.digest,
                continuationID: setup.created.continuationID),
            hostPeer: setup.peer)
        #expect(replay.status == .unknown)
        #expect(replay.mayExecute == false)
    }

    @Test func wrongInstanceCannotConsume() async throws {
        let setup = try await allowOnceSetup()
        _ = try await setup.ceremonies.completeActionCeremony(
            UIActionCompletion(
                challengeID: setup.challenge.challengeID,
                approvalID: setup.created.approvalID,
                outcome: .authenticated),
            uiConnection: setup.ui)
        // A second live instance under the SAME host registration (same
        // definition family, workspace, host, and generation — the fake
        // validity RPC attests it live too) attempts to consume.
        let other = AgentPrincipalReference(
            agentInstanceID: AgentInstanceID(),
            runtimeSessionID: RuntimeSessionID(),
            workspaceSessionID: setup.reference.workspaceSessionID,
            workspaceHostID: setup.reference.workspaceHostID,
            workspaceHostGeneration: setup.reference.workspaceHostGeneration)
        let decision = await setup.ceremonies.consumeApproval(
            HostActionApprovalConsumeDTO(
                approvalID: setup.created.approvalID,
                reference: other,
                actionDigestHex: setup.digest,
                continuationID: setup.created.continuationID),
            hostPeer: setup.peer)
        #expect(decision.mayExecute == false)
        // The failed theft did not burn the grant: exact wins after.
        let exact = await setup.ceremonies.consumeApproval(
            HostActionApprovalConsumeDTO(
                approvalID: setup.created.approvalID,
                reference: setup.reference,
                actionDigestHex: setup.digest,
                continuationID: setup.created.continuationID),
            hostPeer: setup.peer)
        #expect(exact.mayExecute == true)
    }

    @Test func actionSubstitutionCannotConsume() async throws {
        let setup = try await allowOnceSetup()
        _ = try await setup.ceremonies.completeActionCeremony(
            UIActionCompletion(
                challengeID: setup.challenge.challengeID,
                approvalID: setup.created.approvalID,
                outcome: .authenticated),
            uiConnection: setup.ui)
        let otherDigest = CanonicalActionDigest.sha256Hex(of: action("echo otherwise"))
        let decision = await setup.ceremonies.consumeApproval(
            HostActionApprovalConsumeDTO(
                approvalID: setup.created.approvalID,
                reference: setup.reference,
                actionDigestHex: otherDigest,
                continuationID: setup.created.continuationID),
            hostPeer: setup.peer)
        #expect(decision.mayExecute == false)
        // The failed substitution did not burn the grant: exact wins after.
        let exact = await setup.ceremonies.consumeApproval(
            HostActionApprovalConsumeDTO(
                approvalID: setup.created.approvalID,
                reference: setup.reference,
                actionDigestHex: setup.digest,
                continuationID: setup.created.continuationID),
            hostPeer: setup.peer)
        #expect(exact.mayExecute == true)
    }

    @Test func wrongContinuationCannotConsume() async throws {
        let setup = try await allowOnceSetup()
        _ = try await setup.ceremonies.completeActionCeremony(
            UIActionCompletion(
                challengeID: setup.challenge.challengeID,
                approvalID: setup.created.approvalID,
                outcome: .authenticated),
            uiConnection: setup.ui)
        let decision = await setup.ceremonies.consumeApproval(
            HostActionApprovalConsumeDTO(
                approvalID: setup.created.approvalID,
                reference: setup.reference,
                actionDigestHex: setup.digest,
                continuationID: UUID()),
            hostPeer: setup.peer)
        #expect(decision.mayExecute == false)
    }

    @Test func sameActionNewRequestNeedsFreshApproval() async throws {
        let (hosts, ceremonies) = world()
        let ref = reference()
        let host = peer()
        try await register(hosts, ref, host)
        let act = action()
        let digest = CanonicalActionDigest.sha256Hex(of: act)
        let first = try await requested(
            ceremonies, dto: createDTO(reference: ref, action: act), peer: host)
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await ceremonies.bindActionReview(
            approvalID: first.approvalID, uiConnection: ui)
        _ = try await ceremonies.completeActionCeremony(
            UIActionCompletion(
                challengeID: challenge.challengeID, approvalID: first.approvalID,
                outcome: .authenticated),
            uiConnection: ui)
        let consumed = await ceremonies.consumeApproval(
            HostActionApprovalConsumeDTO(
                approvalID: first.approvalID, reference: ref,
                actionDigestHex: digest, continuationID: first.continuationID),
            hostPeer: host)
        #expect(consumed.mayExecute == true)
        // Byte-identical action, new request: a NEW approval with a NEW
        // continuation. The old consumed grant cannot authorize it.
        let second = try await requested(
            ceremonies, dto: createDTO(reference: ref, action: act), peer: host)
        #expect(second.approvalID != first.approvalID)
        #expect(second.continuationID != first.continuationID)
        #expect(second.status == .pending)
        let stale = await ceremonies.consumeApproval(
            HostActionApprovalConsumeDTO(
                approvalID: first.approvalID, reference: ref,
                actionDigestHex: digest, continuationID: first.continuationID),
            hostPeer: host)
        #expect(stale.mayExecute == false)
    }

    // MARK: - Deny

    @Test func denyGrantsNothingAndFailsContinuation() async throws {
        let setup = try await allowOnceSetup()
        let status = try await setup.ceremonies.denyActionCeremony(
            UIActionDeny(
                challengeID: setup.challenge.challengeID,
                approvalID: setup.created.approvalID),
            uiConnection: setup.ui)
        #expect(status == .denied)
        let decision = await setup.ceremonies.consumeApproval(
            HostActionApprovalConsumeDTO(
                approvalID: setup.created.approvalID,
                reference: setup.reference,
                actionDigestHex: setup.digest,
                continuationID: setup.created.continuationID),
            hostPeer: setup.peer)
        #expect(decision.mayExecute == false)
        #expect(await setup.ceremonies.actionStatus(approvalID: setup.created.approvalID) == .denied)
    }

    @Test func denyBindsLiveChallengeAndConnection() async throws {
        let setup = try await allowOnceSetup()
        // Wrong connection cannot deny.
        await #expect(throws: ActionApprovalCeremonyError.notReviewable) {
            try await setup.ceremonies.denyActionCeremony(
                UIActionDeny(
                    challengeID: setup.challenge.challengeID,
                    approvalID: setup.created.approvalID),
                uiConnection: AuthenticatedOperatorUIConnectionID())
        }
        // Wrong challenge ID cannot deny.
        await #expect(throws: ActionApprovalCeremonyError.unknownApproval) {
            try await setup.ceremonies.denyActionCeremony(
                UIActionDeny(challengeID: UUID(), approvalID: setup.created.approvalID),
                uiConnection: setup.ui)
        }
    }

    // MARK: - Completion binding

    @Test func completionSubstitutionAcrossApprovalsRejects() async throws {
        let (hosts, ceremonies) = world()
        let ref = reference()
        let host = peer()
        try await register(hosts, ref, host)
        let first = try await requested(
            ceremonies, dto: createDTO(reference: ref, action: action("echo one")), peer: host)
        let second = try await requested(
            ceremonies, dto: createDTO(reference: ref, action: action("echo two")), peer: host)
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challengeA, _) = try await ceremonies.bindActionReview(
            approvalID: first.approvalID, uiConnection: ui)
        let (challengeB, _) = try await ceremonies.bindActionReview(
            approvalID: second.approvalID, uiConnection: ui)
        // Review A, LA succeeds, send completion for B with A's challenge.
        await #expect(throws: ActionApprovalCeremonyError.unknownApproval) {
            try await ceremonies.completeActionCeremony(
                UIActionCompletion(
                    challengeID: challengeA.challengeID, approvalID: second.approvalID,
                    outcome: .authenticated),
                uiConnection: ui)
        }
        // And B's challenge against A's approval.
        await #expect(throws: ActionApprovalCeremonyError.unknownApproval) {
            try await ceremonies.completeActionCeremony(
                UIActionCompletion(
                    challengeID: challengeB.challengeID, approvalID: first.approvalID,
                    outcome: .authenticated),
                uiConnection: ui)
        }
        // Honest completions still work.
        _ = try await ceremonies.completeActionCeremony(
            UIActionCompletion(
                challengeID: challengeA.challengeID, approvalID: first.approvalID,
                outcome: .authenticated),
            uiConnection: ui)
        _ = try await ceremonies.completeActionCeremony(
            UIActionCompletion(
                challengeID: challengeB.challengeID, approvalID: second.approvalID,
                outcome: .authenticated),
            uiConnection: ui)
    }

    @Test func completionFromWrongConnectionRejects() async throws {
        let setup = try await allowOnceSetup()
        await #expect(throws: ActionApprovalCeremonyError.notReviewable) {
            try await setup.ceremonies.completeActionCeremony(
                UIActionCompletion(
                    challengeID: setup.challenge.challengeID,
                    approvalID: setup.created.approvalID,
                    outcome: .authenticated),
                uiConnection: AuthenticatedOperatorUIConnectionID())
        }
    }

    @Test func nonSuccessOutcomesFailWithoutGrant() async throws {
        for outcome in [
            UIAuthenticationOutcome.cancelled, .unavailable,
            .timedOut, .invalidated, .failed,
        ] {
            let setup = try await allowOnceSetup()
            let status = try? await setup.ceremonies.completeActionCeremony(
                UIActionCompletion(
                    challengeID: setup.challenge.challengeID,
                    approvalID: setup.created.approvalID,
                    outcome: outcome),
                uiConnection: setup.ui)
            // Cancelled/unavailable surface as failed status; all are
            // terminal without a grant.
            if let status {
                #expect(status == .failed)
            }
            let decision = await setup.ceremonies.consumeApproval(
                HostActionApprovalConsumeDTO(
                    approvalID: setup.created.approvalID,
                    reference: setup.reference,
                    actionDigestHex: setup.digest,
                    continuationID: setup.created.continuationID),
                hostPeer: setup.peer)
            #expect(decision.mayExecute == false)
        }
    }

    @Test func bindResumesLiveChallengeForOwner() async throws {
        let setup = try await allowOnceSetup()
        let (second, _) = try await setup.ceremonies.bindActionReview(
            approvalID: setup.created.approvalID, uiConnection: setup.ui)
        #expect(second.challengeID == setup.challenge.challengeID)
    }

    // MARK: - Revocation and generations

    @Test func revokeBeforeResolutionInvalidates() async throws {
        let (hosts, ceremonies) = world()
        let ref = reference()
        let host = peer()
        let state = ValidityState()
        try await register(hosts, ref, host, state: state)
        let created = try await requested(
            ceremonies, dto: createDTO(reference: ref), peer: host)
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await ceremonies.bindActionReview(
            approvalID: created.approvalID, uiConnection: ui)
        await state.revoke()
        // Human tries AllowOnce: no grant, approval invalidated.
        await #expect(throws: ActionApprovalCeremonyError.unknownPrincipal) {
            try await ceremonies.completeActionCeremony(
                UIActionCompletion(
                    challengeID: challenge.challengeID, approvalID: created.approvalID,
                    outcome: .authenticated),
                uiConnection: ui)
        }
        #expect(await ceremonies.actionStatus(approvalID: created.approvalID) == .invalidated)
    }

    @Test func revokeAfterGrantRejectsConsume() async throws {
        let (hosts, ceremonies) = world()
        let ref = reference()
        let host = peer()
        let state = ValidityState()
        try await register(hosts, ref, host, state: state)
        let act = action()
        let created = try await requested(
            ceremonies, dto: createDTO(reference: ref, action: act), peer: host)
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await ceremonies.bindActionReview(
            approvalID: created.approvalID, uiConnection: ui)
        _ = try await ceremonies.completeActionCeremony(
            UIActionCompletion(
                challengeID: challenge.challengeID, approvalID: created.approvalID,
                outcome: .authenticated),
            uiConnection: ui)
        await state.revoke()
        let decision = await ceremonies.consumeApproval(
            HostActionApprovalConsumeDTO(
                approvalID: created.approvalID, reference: ref,
                actionDigestHex: CanonicalActionDigest.sha256Hex(of: act),
                continuationID: created.continuationID),
            hostPeer: host)
        #expect(decision.mayExecute == false)
        #expect(await ceremonies.actionStatus(approvalID: created.approvalID) == .invalidated)
    }

    @Test func revokeBetweenConsumeAndTrailingCheckBurnsGrant() async throws {
        // Deterministic consume × revoke race: validity dies exactly at the
        // post-consume liveness check. The grant is spent (authorizer state
        // consumed) but the resume is refused: mayExecute false.
        let hosts = LiveWorkspaceHostRegistry()
        let ref = reference()
        let host = peer()
        let calls = Mutex(0)
        // Resolves before the trailing check: create(1), bind(2),
        // complete-pre(3), complete-trailing(4), consume-pre(5). The
        // consume trailing check is call 6.
        try await hosts.register(
            peer: host, workspace: ref.workspaceSessionID,
            host: ref.workspaceHostID, generation: ref.workspaceHostGeneration,
            validate: { reference in
                let n = calls.withLock { $0 += 1; return $0 }
                return AgentPrincipalValidity(
                    reference: reference, validity: n <= 5 ? .active : .inactive)
            })
        let ceremonies = ActionApprovalCeremonyService(hosts: hosts)
        let act = action()
        let created = try await requested(
            ceremonies, dto: createDTO(reference: ref, action: act), peer: host)
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await ceremonies.bindActionReview(
            approvalID: created.approvalID, uiConnection: ui)
        _ = try await ceremonies.completeActionCeremony(
            UIActionCompletion(
                challengeID: challenge.challengeID, approvalID: created.approvalID,
                outcome: .authenticated),
            uiConnection: ui)
        let decision = await ceremonies.consumeApproval(
            HostActionApprovalConsumeDTO(
                approvalID: created.approvalID, reference: ref,
                actionDigestHex: CanonicalActionDigest.sha256Hex(of: act),
                continuationID: created.continuationID),
            hostPeer: host)
        #expect(decision.mayExecute == false)
        // Pin the kill to the consume trailing checkpoint: exactly 6
        // resolves (create, bind, complete-pre, complete-trailing,
        // consume-pre, consume-trailing).
        #expect(calls.withLock { $0 } == 6)
        // The grant was spent by the atomic gate before the trailing check
        // failed; a retry finds nothing to consume.
        let retry = await ceremonies.consumeApproval(
            HostActionApprovalConsumeDTO(
                approvalID: created.approvalID, reference: ref,
                actionDigestHex: CanonicalActionDigest.sha256Hex(of: act),
                continuationID: created.continuationID),
            hostPeer: host)
        #expect(retry.mayExecute == false)
    }

    @Test func revokeBetweenCompleteAndTrailingCheckKillsGrant() async throws {
        // Deterministic complete × revoke race: validity dies exactly at
        // the post-grant trailing check. No grant survives: the completion
        // reports unknown-principal, the approval is invalidated, and no
        // consume can follow.
        let hosts = LiveWorkspaceHostRegistry()
        let ref = reference()
        let host = peer()
        let calls = Mutex(0)
        // Resolves: create(1), bind(2), complete-pre(3). The complete
        // trailing check is call 4 and sees a dead principal.
        try await hosts.register(
            peer: host, workspace: ref.workspaceSessionID,
            host: ref.workspaceHostID, generation: ref.workspaceHostGeneration,
            validate: { reference in
                let n = calls.withLock { $0 += 1; return $0 }
                return AgentPrincipalValidity(
                    reference: reference, validity: n <= 3 ? .active : .inactive)
            })
        let ceremonies = ActionApprovalCeremonyService(hosts: hosts)
        let act = action()
        let created = try await requested(
            ceremonies, dto: createDTO(reference: ref, action: act), peer: host)
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await ceremonies.bindActionReview(
            approvalID: created.approvalID, uiConnection: ui)
        await #expect(throws: ActionApprovalCeremonyError.unknownPrincipal) {
            try await ceremonies.completeActionCeremony(
                UIActionCompletion(
                    challengeID: challenge.challengeID, approvalID: created.approvalID,
                    outcome: .authenticated),
                uiConnection: ui)
        }
        #expect(calls.withLock { $0 } == 4)
        #expect(await ceremonies.actionStatus(approvalID: created.approvalID) == .invalidated)
        let decision = await ceremonies.consumeApproval(
            HostActionApprovalConsumeDTO(
                approvalID: created.approvalID, reference: ref,
                actionDigestHex: CanonicalActionDigest.sha256Hex(of: act),
                continuationID: created.continuationID),
            hostPeer: host)
        #expect(decision.mayExecute == false)
    }

    @Test func hostGenerationReplacementInvalidates() async throws {
        let (hosts, ceremonies) = world()
        let ref = reference()
        let host = peer()
        try await register(hosts, ref, host)
        let act = action()
        let created = try await requested(
            ceremonies, dto: createDTO(reference: ref, action: act), peer: host)
        // Host restarts as a new generation; teardown invalidates.
        await hosts.disconnect(connectionID: host.connectionID)
        await ceremonies.hostConnectionLost(connectionID: host.connectionID)
        let replacement = peer()
        let ref2 = AgentPrincipalReference(
            agentInstanceID: AgentInstanceID(),
            runtimeSessionID: RuntimeSessionID(),
            workspaceSessionID: ref.workspaceSessionID,
            workspaceHostID: ref.workspaceHostID,
            workspaceHostGeneration: WorkspaceHostGeneration())
        try await register(hosts, ref2, replacement)
        // Old approval bound to G1: invalid, and the old reference no
        // longer resolves.
        #expect(await ceremonies.actionStatus(approvalID: created.approvalID) == .invalidated)
        let decision = await ceremonies.consumeApproval(
            HostActionApprovalConsumeDTO(
                approvalID: created.approvalID, reference: ref,
                actionDigestHex: CanonicalActionDigest.sha256Hex(of: act),
                continuationID: created.continuationID),
            hostPeer: host)
        #expect(decision.mayExecute == false)
    }

    // MARK: - Disconnects and cancellation

    @Test func uiDisconnectInvalidatesBoundChallenge() async throws {
        let setup = try await allowOnceSetup()
        await setup.ceremonies.uiConnectionLost(setup.ui)
        #expect(
            await setup.ceremonies.actionStatus(approvalID: setup.created.approvalID)
                == .invalidated)
        await #expect(throws: ActionApprovalCeremonyError.self) {
            try await setup.ceremonies.completeActionCeremony(
                UIActionCompletion(
                    challengeID: setup.challenge.challengeID,
                    approvalID: setup.created.approvalID,
                    outcome: .authenticated),
                uiConnection: setup.ui)
        }
    }

    @Test func rebindAfterUIDisconnectReportsUnknown() async throws {
        let setup = try await allowOnceSetup()
        // A second approval exists but is never bound: it has no UI
        // binding yet when the disconnect lands.
        let second = try await requested(
            setup.ceremonies,
            dto: createDTO(reference: setup.reference, action: action("echo second")),
            peer: setup.peer)
        await setup.ceremonies.uiConnectionLost(setup.ui)
        // The disconnected review is dead: a live connection's bind reports
        // unknown rather than resurrecting it.
        await #expect(throws: ActionApprovalCeremonyError.unknownApproval) {
            try await setup.ceremonies.bindActionReview(
                approvalID: setup.created.approvalID,
                uiConnection: AuthenticatedOperatorUIConnectionID())
        }
        // The pre-existing unbound pending survived the disconnect and
        // still binds from a live connection.
        let (_, item) = try await setup.ceremonies.bindActionReview(
            approvalID: second.approvalID,
            uiConnection: AuthenticatedOperatorUIConnectionID())
        #expect(item.approvalID == second.approvalID)
    }

    @Test func uiDisconnectAfterGrantBurnsGrant() async throws {
        // Post-grant disconnect: the issued-but-unconsumed grant dies with
        // its ceremony. Consume refuses and the approval reads invalidated.
        let setup = try await allowOnceSetup()
        _ = try await setup.ceremonies.completeActionCeremony(
            UIActionCompletion(
                challengeID: setup.challenge.challengeID,
                approvalID: setup.created.approvalID,
                outcome: .authenticated),
            uiConnection: setup.ui)
        await setup.ceremonies.uiConnectionLost(setup.ui)
        #expect(
            await setup.ceremonies.actionStatus(approvalID: setup.created.approvalID)
                == .invalidated)
        let decision = await setup.ceremonies.consumeApproval(
            HostActionApprovalConsumeDTO(
                approvalID: setup.created.approvalID,
                reference: setup.reference,
                actionDigestHex: setup.digest,
                continuationID: setup.created.continuationID),
            hostPeer: setup.peer)
        #expect(decision.mayExecute == false)
    }

    @Test func hostCancelEndsParkedApproval() async throws {
        let setup = try await allowOnceSetup()
        let reply = await setup.ceremonies.cancelApproval(
            HostActionApprovalCancelDTO(
                approvalID: setup.created.approvalID, reference: setup.reference),
            hostPeer: setup.peer)
        #expect(reply.status == .cancelled)
        let decision = await setup.ceremonies.consumeApproval(
            HostActionApprovalConsumeDTO(
                approvalID: setup.created.approvalID,
                reference: setup.reference,
                actionDigestHex: setup.digest,
                continuationID: setup.created.continuationID),
            hostPeer: setup.peer)
        #expect(decision.mayExecute == false)
    }

    @Test func cancelReviewRequiresBoundConnection() async throws {
        let setup = try await allowOnceSetup()
        await #expect(throws: ActionApprovalCeremonyError.notReviewable) {
            try await setup.ceremonies.cancelActionReview(
                approvalID: setup.created.approvalID,
                uiConnection: AuthenticatedOperatorUIConnectionID())
        }
        let status = try await setup.ceremonies.cancelActionReview(
            approvalID: setup.created.approvalID, uiConnection: setup.ui)
        #expect(status == .cancelled)
    }

    // MARK: - Status

    @Test func statusProgressionNeverConsumes() async throws {
        let setup = try await allowOnceSetup()
        let pending = await setup.ceremonies.approvalStatus(
            HostActionApprovalStatusDTO(
                approvalID: setup.created.approvalID, reference: setup.reference),
            hostPeer: setup.peer)
        #expect(pending.status == .awaitingAuthentication)
        _ = try await setup.ceremonies.completeActionCeremony(
            UIActionCompletion(
                challengeID: setup.challenge.challengeID,
                approvalID: setup.created.approvalID,
                outcome: .authenticated),
            uiConnection: setup.ui)
        let authorized = await setup.ceremonies.approvalStatus(
            HostActionApprovalStatusDTO(
                approvalID: setup.created.approvalID, reference: setup.reference),
            hostPeer: setup.peer)
        #expect(authorized.status == .authorized)
        // Status polls never consume: exact consume still wins after.
        let decision = await setup.ceremonies.consumeApproval(
            HostActionApprovalConsumeDTO(
                approvalID: setup.created.approvalID,
                reference: setup.reference,
                actionDigestHex: setup.digest,
                continuationID: setup.created.continuationID),
            hostPeer: setup.peer)
        #expect(decision.mayExecute == true)
    }

    @Test func statusUnknownOnMismatch() async throws {
        let setup = try await allowOnceSetup()
        let missing = await setup.ceremonies.approvalStatus(
            HostActionApprovalStatusDTO(
                approvalID: UUID(), reference: setup.reference),
            hostPeer: setup.peer)
        #expect(missing.status == .unknown)
        var other = setup.reference
        other = AgentPrincipalReference(
            agentInstanceID: AgentInstanceID(),
            runtimeSessionID: other.runtimeSessionID,
            workspaceSessionID: other.workspaceSessionID,
            workspaceHostID: other.workspaceHostID,
            workspaceHostGeneration: other.workspaceHostGeneration)
        let mismatched = await setup.ceremonies.approvalStatus(
            HostActionApprovalStatusDTO(
                approvalID: setup.created.approvalID, reference: other),
            hostPeer: setup.peer)
        #expect(mismatched.status == .unknown)
    }

    @Test func denySurfacesDeniedThroughHostStatusRPC() async throws {
        // Live-oracle regression: the parked waiter polls approvalStatus,
        // and retention is pruned at deny time. The RPC must still report
        // the authorizer's terminal word ("denied"), not "unknown", so the
        // continuation completes with the human's decision.
        let setup = try await allowOnceSetup()
        let outcome = try await setup.ceremonies.denyActionCeremony(
            UIActionDeny(
                challengeID: setup.challenge.challengeID,
                approvalID: setup.created.approvalID),
            uiConnection: setup.ui)
        #expect(outcome == .denied)
        let status = await setup.ceremonies.approvalStatus(
            HostActionApprovalStatusDTO(
                approvalID: setup.created.approvalID, reference: setup.reference),
            hostPeer: setup.peer)
        #expect(status.status == .denied)
        // ... and a denied approval still consumes nothing.
        let decision = await setup.ceremonies.consumeApproval(
            HostActionApprovalConsumeDTO(
                approvalID: setup.created.approvalID,
                reference: setup.reference,
                actionDigestHex: setup.digest,
                continuationID: setup.created.continuationID),
            hostPeer: setup.peer)
        #expect(decision.mayExecute == false)
    }

    @Test func cancelSurfacesCancelledThroughHostStatusRPC() async throws {
        let setup = try await allowOnceSetup()
        let cancel = await setup.ceremonies.cancelApproval(
            HostActionApprovalCancelDTO(
                approvalID: setup.created.approvalID, reference: setup.reference),
            hostPeer: setup.peer)
        #expect(cancel.status == .cancelled)
        let status = await setup.ceremonies.approvalStatus(
            HostActionApprovalStatusDTO(
                approvalID: setup.created.approvalID, reference: setup.reference),
            hostPeer: setup.peer)
        #expect(status.status == .cancelled)
    }

    @Test func consumedSurfacesConsumedThroughHostStatusRPC() async throws {
        let setup = try await allowOnceSetup()
        _ = try await setup.ceremonies.completeActionCeremony(
            UIActionCompletion(
                challengeID: setup.challenge.challengeID,
                approvalID: setup.created.approvalID,
                outcome: .authenticated),
            uiConnection: setup.ui)
        let decision = await setup.ceremonies.consumeApproval(
            HostActionApprovalConsumeDTO(
                approvalID: setup.created.approvalID,
                reference: setup.reference,
                actionDigestHex: setup.digest,
                continuationID: setup.created.continuationID),
            hostPeer: setup.peer)
        #expect(decision.mayExecute == true)
        let status = await setup.ceremonies.approvalStatus(
            HostActionApprovalStatusDTO(
                approvalID: setup.created.approvalID, reference: setup.reference),
            hostPeer: setup.peer)
        #expect(status.status == .consumed)
    }

    @Test func reviewListShowsOnlyActionable() async throws {
        let setup = try await allowOnceSetup()
        #expect(await setup.ceremonies.listActionReviews().items.count == 1)
        _ = try await setup.ceremonies.completeActionCeremony(
            UIActionCompletion(
                challengeID: setup.challenge.challengeID,
                approvalID: setup.created.approvalID,
                outcome: .authenticated),
            uiConnection: setup.ui)
        // Authorized: the human's job is done; no longer listed.
        #expect(await setup.ceremonies.listActionReviews().items.isEmpty)
    }

    // MARK: - Concurrency

    @Test func concurrentCeremonyConsumeYieldsOneExecution() async throws {
        let setup = try await allowOnceSetup()
        _ = try await setup.ceremonies.completeActionCeremony(
            UIActionCompletion(
                challengeID: setup.challenge.challengeID,
                approvalID: setup.created.approvalID,
                outcome: .authenticated),
            uiConnection: setup.ui)
        let dto = HostActionApprovalConsumeDTO(
            approvalID: setup.created.approvalID,
            reference: setup.reference,
            actionDigestHex: setup.digest,
            continuationID: setup.created.continuationID)
        let gate = Mutex(0)
        let executions = Mutex(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    gate.withLock { $0 += 1 }
                    while gate.withLock({ $0 }) < 16 { await Task.yield() }
                    let decision = await setup.ceremonies.consumeApproval(dto, hostPeer: setup.peer)
                    if decision.mayExecute {
                        executions.withLock { $0 += 1 }
                    }
                }
            }
        }
        #expect(executions.withLock { $0 } == 1)
    }

    // MARK: - Audit

    @Test func ceremonyAuditCoversFlow() async throws {
        let seen = Mutex<[ActionApprovalCeremonyAuditEvent]>([])
        let (hosts, ceremonies) = world(audit: { event in seen.withLock { $0.append(event) } })
        let ref = reference()
        let host = peer()
        try await register(hosts, ref, host)
        let act = action()
        let created = try await requested(
            ceremonies, dto: createDTO(reference: ref, action: act), peer: host)
        let ui = AuthenticatedOperatorUIConnectionID()
        let (challenge, _) = try await ceremonies.bindActionReview(
            approvalID: created.approvalID, uiConnection: ui)
        _ = try await ceremonies.completeActionCeremony(
            UIActionCompletion(
                challengeID: challenge.challengeID, approvalID: created.approvalID,
                outcome: .authenticated),
            uiConnection: ui)
        _ = await ceremonies.consumeApproval(
            HostActionApprovalConsumeDTO(
                approvalID: created.approvalID, reference: ref,
                actionDigestHex: CanonicalActionDigest.sha256Hex(of: act),
                continuationID: created.continuationID),
            hostPeer: host)
        let kinds = seen.withLock { $0.map(\.kind) }
        #expect(kinds == [
            .askReceived, .approvalCreated, .reviewBound, .completionReceived,
            .consumeRequested, .consumeCompleted,
        ])
    }
}
