import Foundation
import RVDomain

public enum IPCMethod: Sendable, Equatable {
    case evaluate(EvaluateParams)
    case hookEvaluate(HookEvaluateParams)
    case explain(ExplainParams)
    case classify(ClassifyParams)
    case listPacks
    case setPackEnabled(SetPackEnabledParams)
    case doctorSnapshot
    case pendingList
    case pendingWatch(PendingWatchParams)
    case pendingResolve(PendingResolveParams)
    case rulePreview(RulePreviewParams)
    case ruleSave(RuleSaveParams)
    case proposeWorkspaceLaunch(ProposeLaunchParams)
    case launchProposalStatus(ProposalStatusParams)
    case attestTTYRedemption(AttestTTYRedemptionParams)
}

public enum IPCResult: Sendable, Equatable {
    case evaluate(EvaluateReply)
    case hookEvaluate(HookEvaluateReply)
    case explain(ExplainReply)
    case classify(ClassifyReply)
    case listPacks(ListPacksReply)
    case setPackEnabled(SetPackEnabledReply)
    case doctorSnapshot(DoctorSnapshotReply)
    case pendingList(PendingListReply)
    case pendingWatch(PendingWatchReply)
    case pendingResolve(PendingResolveReply)
    case rulePreview(RulePreviewReply)
    case ruleSave(RuleSaveReply)
    case proposeWorkspaceLaunch(ProposeLaunchReply)
    case launchProposalStatus(ProposalStatusReply)
    case attestTTYRedemption(AttestTTYRedemptionReply)
    case uiRegistered(UIRegisteredDTO)
    case uiReviewList(UIReviewListDTO)
    case uiChallengeBundle(UIChallengeBundleDTO)
    case uiOperationStatus(UIOperationStatusDTO)
    case uiActionReviewList(UIActionReviewListDTO)
    case uiActionChallengeBundle(UIActionChallengeBundleDTO)
    case uiActionStatus(UIActionStatusDTO)
    case uiHookReviewList(UIHookReviewListDTO)
    case uiHookChallengeBundle(UIHookChallengeBundleDTO)
    case uiHookStatus(UIHookStatusDTO)
    case hostActionApprovalCreated(HostActionApprovalCreatedDTO)
    case hostActionApprovalStatus(HostActionApprovalStatusReplyDTO)
    case hostActionApprovalDecision(HostActionApprovalDecisionDTO)
    case error(IPCError)
}

extension IPCMethod: Codable {
    private enum CodingKeys: String, CodingKey {
        case evaluate
        case hookEvaluate
        case explain
        case classify
        case listPacks
        case setPackEnabled
        case doctorSnapshot
        case pendingList
        case pendingWatch
        case pendingResolve
        case rulePreview
        case ruleSave
        case proposeWorkspaceLaunch
        case launchProposalStatus
        case attestTTYRedemption
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .evaluate(let params):
            try container.encode(params, forKey: .evaluate)
        case .hookEvaluate(let params):
            try container.encode(params, forKey: .hookEvaluate)
        case .explain(let params):
            try container.encode(params, forKey: .explain)
        case .classify(let params):
            try container.encode(params, forKey: .classify)
        case .listPacks:
            try container.encode(EmptyPayload(), forKey: .listPacks)
        case .setPackEnabled(let params):
            try container.encode(params, forKey: .setPackEnabled)
        case .doctorSnapshot:
            try container.encode(EmptyPayload(), forKey: .doctorSnapshot)
        case .pendingList:
            try container.encode(EmptyPayload(), forKey: .pendingList)
        case .pendingWatch(let params):
            try container.encode(params, forKey: .pendingWatch)
        case .pendingResolve(let params):
            try container.encode(params, forKey: .pendingResolve)
        case .rulePreview(let params):
            try container.encode(params, forKey: .rulePreview)
        case .ruleSave(let params):
            try container.encode(params, forKey: .ruleSave)
        case .proposeWorkspaceLaunch(let params):
            try container.encode(params, forKey: .proposeWorkspaceLaunch)
        case .launchProposalStatus(let params):
            try container.encode(params, forKey: .launchProposalStatus)
        case .attestTTYRedemption(let params):
            try container.encode(params, forKey: .attestTTYRedemption)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let params = try container.decodeIfPresent(EvaluateParams.self, forKey: .evaluate) {
            self = .evaluate(params)
        } else if let params = try container.decodeIfPresent(HookEvaluateParams.self, forKey: .hookEvaluate) {
            self = .hookEvaluate(params)
        } else if let params = try container.decodeIfPresent(ExplainParams.self, forKey: .explain) {
            self = .explain(params)
        } else if let params = try container.decodeIfPresent(ClassifyParams.self, forKey: .classify) {
            self = .classify(params)
        } else if container.contains(.listPacks) {
            self = .listPacks
        } else if let params = try container.decodeIfPresent(SetPackEnabledParams.self, forKey: .setPackEnabled) {
            self = .setPackEnabled(params)
        } else if container.contains(.doctorSnapshot) {
            self = .doctorSnapshot
        } else if container.contains(.pendingList) {
            self = .pendingList
        } else if let params = try container.decodeIfPresent(PendingWatchParams.self, forKey: .pendingWatch) {
            self = .pendingWatch(params)
        } else if let params = try container.decodeIfPresent(PendingResolveParams.self, forKey: .pendingResolve) {
            self = .pendingResolve(params)
        } else if let params = try container.decodeIfPresent(RulePreviewParams.self, forKey: .rulePreview) {
            self = .rulePreview(params)
        } else if let params = try container.decodeIfPresent(RuleSaveParams.self, forKey: .ruleSave) {
            self = .ruleSave(params)
        } else if let params = try container.decodeIfPresent(
            ProposeLaunchParams.self, forKey: .proposeWorkspaceLaunch) {
            self = .proposeWorkspaceLaunch(params)
        } else if let params = try container.decodeIfPresent(
            ProposalStatusParams.self, forKey: .launchProposalStatus) {
            self = .launchProposalStatus(params)
        } else if let params = try container.decodeIfPresent(
            AttestTTYRedemptionParams.self, forKey: .attestTTYRedemption) {
            self = .attestTTYRedemption(params)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unknown IPCMethod")
            )
        }
    }
}

extension IPCResult: Codable {
    private enum CodingKeys: String, CodingKey {
        case evaluate
        case hookEvaluate
        case explain
        case classify
        case listPacks
        case setPackEnabled
        case doctorSnapshot
        case pendingList
        case pendingWatch
        case pendingResolve
        case rulePreview
        case ruleSave
        case proposeWorkspaceLaunch
        case launchProposalStatus
        case attestTTYRedemption
        case uiRegistered
        case uiReviewList
        case uiChallengeBundle
        case uiOperationStatus
        case uiActionReviewList
        case uiActionChallengeBundle
        case uiActionStatus
        case uiHookReviewList
        case uiHookChallengeBundle
        case uiHookStatus
        case hostActionApprovalCreated
        case hostActionApprovalStatus
        case hostActionApprovalDecision
        case error
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .evaluate(let reply):
            try container.encode(reply, forKey: .evaluate)
        case .hookEvaluate(let reply):
            try container.encode(reply, forKey: .hookEvaluate)
        case .explain(let reply):
            try container.encode(reply, forKey: .explain)
        case .classify(let reply):
            try container.encode(reply, forKey: .classify)
        case .listPacks(let reply):
            try container.encode(reply, forKey: .listPacks)
        case .setPackEnabled(let reply):
            try container.encode(reply, forKey: .setPackEnabled)
        case .doctorSnapshot(let reply):
            try container.encode(reply, forKey: .doctorSnapshot)
        case .pendingList(let reply):
            try container.encode(reply, forKey: .pendingList)
        case .pendingWatch(let reply):
            try container.encode(reply, forKey: .pendingWatch)
        case .pendingResolve(let reply):
            try container.encode(reply, forKey: .pendingResolve)
        case .rulePreview(let reply):
            try container.encode(reply, forKey: .rulePreview)
        case .ruleSave(let reply):
            try container.encode(reply, forKey: .ruleSave)
        case .proposeWorkspaceLaunch(let reply):
            try container.encode(reply, forKey: .proposeWorkspaceLaunch)
        case .launchProposalStatus(let reply):
            try container.encode(reply, forKey: .launchProposalStatus)
        case .attestTTYRedemption(let reply):
            try container.encode(reply, forKey: .attestTTYRedemption)
        case .uiRegistered(let reply):
            try container.encode(reply, forKey: .uiRegistered)
        case .uiReviewList(let reply):
            try container.encode(reply, forKey: .uiReviewList)
        case .uiChallengeBundle(let reply):
            try container.encode(reply, forKey: .uiChallengeBundle)
        case .uiOperationStatus(let reply):
            try container.encode(reply, forKey: .uiOperationStatus)
        case .uiActionReviewList(let reply):
            try container.encode(reply, forKey: .uiActionReviewList)
        case .uiActionChallengeBundle(let reply):
            try container.encode(reply, forKey: .uiActionChallengeBundle)
        case .uiActionStatus(let reply):
            try container.encode(reply, forKey: .uiActionStatus)
        case .uiHookReviewList(let reply):
            try container.encode(reply, forKey: .uiHookReviewList)
        case .uiHookChallengeBundle(let reply):
            try container.encode(reply, forKey: .uiHookChallengeBundle)
        case .uiHookStatus(let reply):
            try container.encode(reply, forKey: .uiHookStatus)
        case .hostActionApprovalCreated(let reply):
            try container.encode(reply, forKey: .hostActionApprovalCreated)
        case .hostActionApprovalStatus(let reply):
            try container.encode(reply, forKey: .hostActionApprovalStatus)
        case .hostActionApprovalDecision(let reply):
            try container.encode(reply, forKey: .hostActionApprovalDecision)
        case .error(let error):
            try container.encode(error, forKey: .error)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let reply = try container.decodeIfPresent(EvaluateReply.self, forKey: .evaluate) {
            self = .evaluate(reply)
        } else if let reply = try container.decodeIfPresent(HookEvaluateReply.self, forKey: .hookEvaluate) {
            self = .hookEvaluate(reply)
        } else if let reply = try container.decodeIfPresent(ExplainReply.self, forKey: .explain) {
            self = .explain(reply)
        } else if let reply = try container.decodeIfPresent(ClassifyReply.self, forKey: .classify) {
            self = .classify(reply)
        } else if let reply = try container.decodeIfPresent(ListPacksReply.self, forKey: .listPacks) {
            self = .listPacks(reply)
        } else if let reply = try container.decodeIfPresent(SetPackEnabledReply.self, forKey: .setPackEnabled) {
            self = .setPackEnabled(reply)
        } else if let reply = try container.decodeIfPresent(DoctorSnapshotReply.self, forKey: .doctorSnapshot) {
            self = .doctorSnapshot(reply)
        } else if let reply = try container.decodeIfPresent(PendingListReply.self, forKey: .pendingList) {
            self = .pendingList(reply)
        } else if let reply = try container.decodeIfPresent(PendingWatchReply.self, forKey: .pendingWatch) {
            self = .pendingWatch(reply)
        } else if let reply = try container.decodeIfPresent(PendingResolveReply.self, forKey: .pendingResolve) {
            self = .pendingResolve(reply)
        } else if let reply = try container.decodeIfPresent(RulePreviewReply.self, forKey: .rulePreview) {
            self = .rulePreview(reply)
        } else if let reply = try container.decodeIfPresent(RuleSaveReply.self, forKey: .ruleSave) {
            self = .ruleSave(reply)
        } else if let reply = try container.decodeIfPresent(
            ProposeLaunchReply.self, forKey: .proposeWorkspaceLaunch) {
            self = .proposeWorkspaceLaunch(reply)
        } else if let reply = try container.decodeIfPresent(
            ProposalStatusReply.self, forKey: .launchProposalStatus) {
            self = .launchProposalStatus(reply)
        } else if let reply = try container.decodeIfPresent(
            AttestTTYRedemptionReply.self, forKey: .attestTTYRedemption) {
            self = .attestTTYRedemption(reply)
        } else if let reply = try container.decodeIfPresent(
            UIRegisteredDTO.self, forKey: .uiRegistered) {
            self = .uiRegistered(reply)
        } else if let reply = try container.decodeIfPresent(
            UIReviewListDTO.self, forKey: .uiReviewList) {
            self = .uiReviewList(reply)
        } else if let reply = try container.decodeIfPresent(
            UIChallengeBundleDTO.self, forKey: .uiChallengeBundle) {
            self = .uiChallengeBundle(reply)
        } else if let reply = try container.decodeIfPresent(
            UIOperationStatusDTO.self, forKey: .uiOperationStatus) {
            self = .uiOperationStatus(reply)
        } else if let reply = try container.decodeIfPresent(
            UIActionReviewListDTO.self, forKey: .uiActionReviewList) {
            self = .uiActionReviewList(reply)
        } else if let reply = try container.decodeIfPresent(
            UIActionChallengeBundleDTO.self, forKey: .uiActionChallengeBundle) {
            self = .uiActionChallengeBundle(reply)
        } else if let reply = try container.decodeIfPresent(
            UIActionStatusDTO.self, forKey: .uiActionStatus) {
            self = .uiActionStatus(reply)
        } else if let reply = try container.decodeIfPresent(
            UIHookReviewListDTO.self, forKey: .uiHookReviewList) {
            self = .uiHookReviewList(reply)
        } else if let reply = try container.decodeIfPresent(
            UIHookChallengeBundleDTO.self, forKey: .uiHookChallengeBundle) {
            self = .uiHookChallengeBundle(reply)
        } else if let reply = try container.decodeIfPresent(
            UIHookStatusDTO.self, forKey: .uiHookStatus) {
            self = .uiHookStatus(reply)
        } else if let reply = try container.decodeIfPresent(
            HostActionApprovalCreatedDTO.self, forKey: .hostActionApprovalCreated) {
            self = .hostActionApprovalCreated(reply)
        } else if let reply = try container.decodeIfPresent(
            HostActionApprovalStatusReplyDTO.self, forKey: .hostActionApprovalStatus) {
            self = .hostActionApprovalStatus(reply)
        } else if let reply = try container.decodeIfPresent(
            HostActionApprovalDecisionDTO.self, forKey: .hostActionApprovalDecision) {
            self = .hostActionApprovalDecision(reply)
        } else if let error = try container.decodeIfPresent(IPCError.self, forKey: .error) {
            self = .error(error)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unknown IPCResult")
            )
        }
    }
}

struct EmptyPayload: Sendable, Equatable, Codable {}

enum RequestCwdCoding {
    enum CodingKeys: String, CodingKey {
        case request
        case cwd
    }

    static func nonempty(_ cwd: String?) -> WorkingDirectory? {
        cwd.flatMap { WorkingDirectory(validating: $0) }
    }

    static func decode(from decoder: Decoder) throws -> (EvaluationRequest, WorkingDirectory?) {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let request = try container.decode(EvaluationRequest.self, forKey: .request)
        let cwd = nonempty(try container.decodeIfPresent(String.self, forKey: .cwd))
        return (request, cwd)
    }

    static func encode(request: EvaluationRequest, cwd: WorkingDirectory?, to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(request, forKey: .request)
        try container.encodeIfPresent(cwd, forKey: .cwd)
    }
}
