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
