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

/// rvd's load, or `busy`: rvd runs only a few status loads at once (each
/// may block on file I/O for seconds) and refuses more rather than queue
/// them. A busy reply says nothing about the policy.
///
/// Wire: `{"status": {...}}` or `{"busy": true}`.
public enum PolicyStatusReply: Sendable, Equatable, Codable {
    case status(PolicyLoadStatus)
    case busy

    private enum CodingKeys: String, CodingKey {
        case status, busy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let status = try container.decodeIfPresent(PolicyLoadStatus.self, forKey: .status) {
            self = .status(status)
        } else if try container.decodeIfPresent(Bool.self, forKey: .busy) == true {
            self = .busy
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "policyStatus reply has neither status nor busy"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status(let status):
            try container.encode(status, forKey: .status)
        case .busy:
            try container.encode(true, forKey: .busy)
        }
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
