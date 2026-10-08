public protocol IPCCall: Sendable {
    associatedtype Reply: Sendable
    var method: IPCMethod { get }
    static func extract(_ result: IPCResult) -> Reply?
}

public struct EvaluateCall: IPCCall {
    public var params: EvaluateParams
    public var method: IPCMethod { .evaluate(params) }

    public init(params: EvaluateParams) {
        self.params = params
    }

    public static func extract(_ result: IPCResult) -> EvaluateReply? {
        if case .evaluate(let reply) = result { return reply }
        return nil
    }
}

public struct HookEvaluateCall: IPCCall {
    public var params: HookEvaluateParams
    public var method: IPCMethod { .hookEvaluate(params) }

    public init(params: HookEvaluateParams) {
        self.params = params
    }

    public static func extract(_ result: IPCResult) -> HookEvaluateReply? {
        if case .hookEvaluate(let reply) = result { return reply }
        return nil
    }
}

public struct DoctorSnapshotCall: IPCCall {
    public var method: IPCMethod { .doctorSnapshot }

    public init() {}

    public static func extract(_ result: IPCResult) -> DoctorSnapshotReply? {
        if case .doctorSnapshot(let reply) = result { return reply }
        return nil
    }
}

public struct ProposeLaunchCall: IPCCall {
    public var params: ProposeLaunchParams
    public var method: IPCMethod { .proposeWorkspaceLaunch(params) }

    public init(params: ProposeLaunchParams) {
        self.params = params
    }

    public static func extract(_ result: IPCResult) -> ProposeLaunchReply? {
        if case .proposeWorkspaceLaunch(let reply) = result { return reply }
        return nil
    }
}

public struct ProposalStatusCall: IPCCall {
    public var params: ProposalStatusParams
    public var method: IPCMethod { .launchProposalStatus(params) }

    public init(params: ProposalStatusParams) {
        self.params = params
    }

    public static func extract(_ result: IPCResult) -> ProposalStatusReply? {
        if case .launchProposalStatus(let reply) = result { return reply }
        return nil
    }
}

public struct AttestTTYRedemptionCall: IPCCall {
    public var params: AttestTTYRedemptionParams
    public var method: IPCMethod { .attestTTYRedemption(params) }

    public init(params: AttestTTYRedemptionParams) {
        self.params = params
    }

    public static func extract(_ result: IPCResult) -> AttestTTYRedemptionReply? {
        if case .attestTTYRedemption(let reply) = result { return reply }
        return nil
    }
}
