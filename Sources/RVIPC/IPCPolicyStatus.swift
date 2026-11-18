import Foundation
import RVDomain

/// `policyStatus`: what rvd's evaluation loads for `cwd` right now. Read
/// only and diagnostic; it reports no rule content, only hashes, counts and
/// the failing step. rvd answers from its own HOME, so the answer covers a
/// CLI whose HOME, binary or file access differs from rvd's.
public struct PolicyStatusParams: Sendable, Equatable, Codable {
    /// The workspace whose `.rv/policy.toml` evaluation reads, as hooks send it.
    public var cwd: WorkingDirectory?

    public init(cwd: WorkingDirectory?) {
        self.cwd = cwd
    }
}

public struct PolicyStatusReply: Sendable, Equatable, Codable {
    public var status: PolicyLoadStatus

    public init(status: PolicyLoadStatus) {
        self.status = status
    }
}

public struct PolicyStatusCall: IPCCall {
    public var params: PolicyStatusParams
    public var method: IPCMethod { .policyStatus(params) }

    public init(params: PolicyStatusParams) {
        self.params = params
    }

    public static func extract(_ result: IPCResult) -> PolicyStatusReply? {
        if case .policyStatus(let reply) = result { return reply }
        return nil
    }
}
