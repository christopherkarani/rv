import Foundation

/// Durable description of the principal and exact operation awaiting approval.
/// Decoding this description never establishes a live principal or resolver authority.
public struct ApprovalSubject: Sendable, Equatable, Codable {
    public let agentInstanceID: AgentInstanceID
    public let runtimeSessionID: RuntimeSessionID
    public let workspaceSessionID: WorkspaceSessionID
    public let workspaceHostID: UUID
    public let hostGeneration: UInt64
    public let fingerprint: ActionFingerprint
    public let continuation: ApprovalContinuation
    public let policyContext: String

    public init(
        agentInstanceID: AgentInstanceID,
        runtimeSessionID: RuntimeSessionID,
        workspaceSessionID: WorkspaceSessionID,
        workspaceHostID: UUID,
        hostGeneration: UInt64,
        fingerprint: ActionFingerprint,
        continuation: ApprovalContinuation,
        policyContext: String
    ) {
        self.agentInstanceID = agentInstanceID
        self.runtimeSessionID = runtimeSessionID
        self.workspaceSessionID = workspaceSessionID
        self.workspaceHostID = workspaceHostID
        self.hostGeneration = hostGeneration
        self.fingerprint = fingerprint
        self.continuation = continuation
        self.policyContext = policyContext
    }

    private enum CodingKeys: String, CodingKey {
        case agentInstanceID, runtimeSessionID, workspaceSessionID, workspaceHostID
        case hostGeneration, fingerprint, continuation, policyContext
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        agentInstanceID = try values.decode(AgentInstanceID.self, forKey: .agentInstanceID)
        runtimeSessionID = RuntimeSessionID(rawValue: try values.decode(UUID.self, forKey: .runtimeSessionID))
        workspaceSessionID = WorkspaceSessionID(rawValue: try values.decode(UUID.self, forKey: .workspaceSessionID))
        workspaceHostID = try values.decode(UUID.self, forKey: .workspaceHostID)
        hostGeneration = try values.decode(UInt64.self, forKey: .hostGeneration)
        fingerprint = try values.decode(ActionFingerprint.self, forKey: .fingerprint)
        continuation = try values.decode(ApprovalContinuation.self, forKey: .continuation)
        policyContext = try values.decode(String.self, forKey: .policyContext)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(agentInstanceID, forKey: .agentInstanceID)
        try values.encode(runtimeSessionID.rawValue, forKey: .runtimeSessionID)
        try values.encode(workspaceSessionID.rawValue, forKey: .workspaceSessionID)
        try values.encode(workspaceHostID, forKey: .workspaceHostID)
        try values.encode(hostGeneration, forKey: .hostGeneration)
        try values.encode(fingerprint, forKey: .fingerprint)
        try values.encode(continuation, forKey: .continuation)
        try values.encode(policyContext, forKey: .policyContext)
    }
}
