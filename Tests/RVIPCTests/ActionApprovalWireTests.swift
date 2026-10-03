import Foundation
import Testing
import RVDomain
import RVIPC

/// Step 6 wire DTOs and the action-bridge request vocabulary round-trip.
/// Pure Codable stability: no service, no XPC. Also pins cross-mode
/// confusion resistance: action bytes never decode as launch requests and
/// launch bytes never decode as action requests.
@Suite("Action approval wire round trips")
struct ActionApprovalWireRoundTripTests {
    private func reference() -> AgentPrincipalReference {
        AgentPrincipalReference(
            agentInstanceID: AgentInstanceID(),
            runtimeSessionID: RuntimeSessionID(),
            workspaceSessionID: WorkspaceSessionID(),
            workspaceHostID: WorkspaceHostID(),
            workspaceHostGeneration: WorkspaceHostGeneration())
    }

    private func action() -> ProposedAction {
        .shell(ShellAction(
            fingerprint: ActionFingerprint(rawValue: "wire:echo"),
            scope: ActionScope(workingDirectory: WorkingDirectory(rawValue: "/work")),
            supportingCommand: ShellCommand(rawValue: "echo hello")))
    }

    private func reviewItem(approvalID: UUID = UUID()) -> UIActionReviewItemDTO {
        UIActionReviewItemDTO(
            approvalID: approvalID, instanceID: UUID(), definitionID: "test-agent",
            definitionRevisionDigest: String(repeating: "c", count: 64),
            runtimeSessionID: UUID(), workspaceSessionID: UUID(), hostID: UUID(),
            actionKind: "shell", exactTarget: "/work", exactArguments: "echo hello",
            policyReason: "reviewAsk", scopeSummary: "Allow once: this exact action, single use.",
            actionDigestHex: String(repeating: "d", count: 64), status: "pending",
            advisoryExpiresWall: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func challenge(approvalID: UUID = UUID()) -> UIActionChallengeDTO {
        UIActionChallengeDTO(
            challengeID: UUID(), approvalID: approvalID,
            actionDigestHex: String(repeating: "d", count: 64), uiConnectionID: UUID(),
            issuedWall: Date(timeIntervalSince1970: 1_800_000_000),
            advisoryLifetimeSeconds: 300)
    }

    @Test func actionBridgeRequestsRoundTrip() throws {
        let id = UUID()
        let cases: [UIActionBridgeRequest] = [
            .actionList,
            .actionBind(approvalID: id),
            .actionComplete(UIActionCompletion(
                challengeID: UUID(), approvalID: id, outcome: .authenticated)),
            .actionDeny(UIActionDeny(challengeID: UUID(), approvalID: id)),
            .actionCancel(approvalID: id),
            .actionStatus(approvalID: id),
        ]
        for request in cases {
            let decoded = try IPCJSON.decode(
                UIActionBridgeRequest.self, from: IPCJSON.encode(request))
            #expect(decoded == request)
        }
    }

    @Test func hostDTOsRoundTrip() throws {
        let create = HostActionApprovalCreateDTO(
            reference: reference(), action: action(), reason: "reviewAsk",
            policyContext: "runtime:/work",
            definitionID: AgentDefinitionID(rawValue: "test-agent"),
            definitionRevision: AgentDefinitionRevision(
                digestHex: String(repeating: "c", count: 64)))
        #expect(try IPCJSON.decode(
            HostActionApprovalCreateDTO.self, from: IPCJSON.encode(create)) == create)
        let created = HostActionApprovalCreatedDTO(
            approvalID: UUID(), continuationID: UUID(), status: "pending")
        #expect(try IPCJSON.decode(
            HostActionApprovalCreatedDTO.self, from: IPCJSON.encode(created)) == created)
        let status = HostActionApprovalStatusDTO(approvalID: UUID(), reference: reference())
        #expect(try IPCJSON.decode(
            HostActionApprovalStatusDTO.self, from: IPCJSON.encode(status)) == status)
        let statusReply = HostActionApprovalStatusReplyDTO(status: "authorized")
        #expect(try IPCJSON.decode(
            HostActionApprovalStatusReplyDTO.self, from: IPCJSON.encode(statusReply)) == statusReply)
        let consume = HostActionApprovalConsumeDTO(
            approvalID: UUID(), reference: reference(),
            actionDigestHex: String(repeating: "d", count: 64), continuationID: UUID())
        #expect(try IPCJSON.decode(
            HostActionApprovalConsumeDTO.self, from: IPCJSON.encode(consume)) == consume)
        let decision = HostActionApprovalDecisionDTO(status: "consumed", mayExecute: true)
        #expect(try IPCJSON.decode(
            HostActionApprovalDecisionDTO.self, from: IPCJSON.encode(decision)) == decision)
        let cancel = HostActionApprovalCancelDTO(approvalID: UUID(), reference: reference())
        #expect(try IPCJSON.decode(
            HostActionApprovalCancelDTO.self, from: IPCJSON.encode(cancel)) == cancel)
    }

    @Test func uiDTOsRoundTrip() throws {
        let item = reviewItem()
        #expect(try IPCJSON.decode(
            UIActionReviewItemDTO.self, from: IPCJSON.encode(item)) == item)
        let list = UIActionReviewListDTO(items: [item])
        #expect(try IPCJSON.decode(
            UIActionReviewListDTO.self, from: IPCJSON.encode(list)) == list)
        let bundle = UIActionChallengeBundleDTO(challenge: challenge(), item: item)
        #expect(try IPCJSON.decode(
            UIActionChallengeBundleDTO.self, from: IPCJSON.encode(bundle)) == bundle)
        let status = UIActionStatusDTO(approvalID: UUID(), status: "authorized")
        #expect(try IPCJSON.decode(
            UIActionStatusDTO.self, from: IPCJSON.encode(status)) == status)
        let deny = UIActionDeny(challengeID: UUID(), approvalID: UUID())
        #expect(try IPCJSON.decode(
            UIActionDeny.self, from: IPCJSON.encode(deny)) == deny)
    }

    @Test func ipcResultsRoundTrip() throws {
        let results: [IPCResult] = [
            .uiActionReviewList(UIActionReviewListDTO(items: [reviewItem()])),
            .uiActionChallengeBundle(UIActionChallengeBundleDTO(
                challenge: challenge(), item: reviewItem())),
            .uiActionStatus(UIActionStatusDTO(approvalID: UUID(), status: "denied")),
            .hostActionApprovalCreated(HostActionApprovalCreatedDTO(
                approvalID: UUID(), continuationID: UUID(), status: "pending")),
            .hostActionApprovalStatus(HostActionApprovalStatusReplyDTO(status: "authorized")),
            .hostActionApprovalDecision(HostActionApprovalDecisionDTO(
                status: "unknown", mayExecute: false)),
        ]
        for result in results {
            let response = IPCResponse(id: UUID(), result: result)
            let decoded = try IPCJSON.decode(IPCResponse.self, from: IPCJSON.encode(response))
            #expect(decoded == response)
        }
    }

    @Test func actionAndLaunchRequestsDoNotConfuse() throws {
        // Action bytes must not decode as a launch request: distinct key
        // sets, and the launch decoder rejects unknown shapes.
        let actionBytes = try IPCJSON.encode(
            UIActionBridgeRequest.actionComplete(UIActionCompletion(
                challengeID: UUID(), approvalID: UUID(), outcome: .authenticated)))
        #expect(throws: (any Error).self) {
            try IPCJSON.decode(UIBridgeRequest.self, from: actionBytes)
        }
        // Launch bytes must not decode as an action request.
        let launchBytes = try IPCJSON.encode(UIBridgeRequest.complete(UIOperatorCompletion(
            challengeID: UUID(), operationID: UUID(), outcome: .authenticated)))
        #expect(throws: (any Error).self) {
            try IPCJSON.decode(UIActionBridgeRequest.self, from: launchBytes)
        }
        // A launch completion is not an action completion, structurally.
        let launchCompletion = UIOperatorCompletion(
            challengeID: UUID(), operationID: UUID(), outcome: .authenticated)
        #expect(throws: (any Error).self) {
            try IPCJSON.decode(
                UIActionCompletion.self, from: IPCJSON.encode(launchCompletion))
        }
    }

    @Test func unknownActionRequestFailsClosed() throws {
        let garbage = Data(#"{"nope":1}"#.utf8)
        #expect(throws: (any Error).self) {
            try IPCJSON.decode(UIActionBridgeRequest.self, from: garbage)
        }
    }
}
