import Foundation

/// Fresh host-start identity. Naming one does not establish a live incarnation.
/// Never restore this value from history as active authority.
public struct WorkspaceHostGeneration: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init() { rawValue = UUID() }
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// Untrusted cross-process name, never a credential or authenticated context.
/// All five fields must match a live authenticated workspace host and its registry.
public struct AgentPrincipalReference: Hashable, Sendable, Codable {
    public let agentInstanceID: AgentInstanceID
    public let runtimeSessionID: RuntimeSessionID
    public let workspaceSessionID: WorkspaceSessionID
    public let workspaceHostID: WorkspaceHostID
    public let workspaceHostGeneration: WorkspaceHostGeneration

    public init(
        agentInstanceID: AgentInstanceID,
        runtimeSessionID: RuntimeSessionID,
        workspaceSessionID: WorkspaceSessionID,
        workspaceHostID: WorkspaceHostID,
        workspaceHostGeneration: WorkspaceHostGeneration
    ) {
        self.agentInstanceID = agentInstanceID
        self.runtimeSessionID = runtimeSessionID
        self.workspaceSessionID = workspaceSessionID
        self.workspaceHostID = workspaceHostID
        self.workspaceHostGeneration = workspaceHostGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case agentInstanceID, runtimeSessionID, workspaceSessionID
        case workspaceHostID, workspaceHostGeneration
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        agentInstanceID = AgentInstanceID(rawValue: try values.decode(UUID.self, forKey: .agentInstanceID))
        runtimeSessionID = RuntimeSessionID(rawValue: try values.decode(UUID.self, forKey: .runtimeSessionID))
        workspaceSessionID = WorkspaceSessionID(rawValue: try values.decode(UUID.self, forKey: .workspaceSessionID))
        workspaceHostID = WorkspaceHostID(rawValue: try values.decode(UUID.self, forKey: .workspaceHostID))
        workspaceHostGeneration = WorkspaceHostGeneration(rawValue: try values.decode(UUID.self, forKey: .workspaceHostGeneration))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(agentInstanceID.rawValue, forKey: .agentInstanceID)
        try values.encode(runtimeSessionID.rawValue, forKey: .runtimeSessionID)
        try values.encode(workspaceSessionID.rawValue, forKey: .workspaceSessionID)
        try values.encode(workspaceHostID.rawValue, forKey: .workspaceHostID)
        try values.encode(workspaceHostGeneration.rawValue, forKey: .workspaceHostGeneration)
    }
}

/// Descriptive RPC data. Even `active` grants nothing without authenticated
/// transport evidence and service-side lifetime checks for this operation.
public struct AgentPrincipalValidity: Sendable, Codable, Equatable {
    public let reference: AgentPrincipalReference
    public let validity: AgentInstanceValidity

    public init(reference: AgentPrincipalReference, validity: AgentInstanceValidity) {
        self.reference = reference
        self.validity = validity
    }
}
