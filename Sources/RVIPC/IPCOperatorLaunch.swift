import Foundation
import RVDomain

// MARK: - Untrusted launch proposals (CLI → rvd)
//
// A signed genuine `rv` executable does not imply operator intent. These
// params are routing hints only: rvd forwards them to the registered
// workspace host, and only the authenticated host-prepared description that
// comes back may create Step 3 state. Replies carry status, never authority.

/// Proposal to prepare (not launch) one identity launch in a workspace.
public struct ProposeLaunchParams: Sendable, Equatable, Codable {
    /// Project-path hint used only to route to a registered host.
    public let workspace: String
    /// Endpoint-file routing hints. Never authoritative; the live registry and
    /// the returned description's own bindings decide. No generation hint:
    /// only the live registration names the incarnation.
    public let hostID: UUID?
    public let workspaceSessionID: UUID?
    /// "named" or "custom".
    public let kind: String
    public let definitionID: String?
    public let executable: String?
    public let expectedDigest: String?
    public let arguments: [String]
    public let io: UIIODTO

    public init(
        workspace: String, hostID: UUID? = nil, workspaceSessionID: UUID? = nil,
        kind: String, definitionID: String? = nil, executable: String? = nil,
        expectedDigest: String? = nil, arguments: [String] = [], io: UIIODTO = .discard
    ) {
        self.workspace = workspace
        self.hostID = hostID
        self.workspaceSessionID = workspaceSessionID
        self.kind = kind
        self.definitionID = definitionID
        self.executable = executable
        self.expectedDigest = expectedDigest
        self.arguments = arguments
        self.io = io
    }
}

public struct ProposeLaunchReply: Sendable, Equatable, Codable {
    /// Correlation-only operation ID for status polling. Grants nothing.
    public let operationID: UUID
    public let status: String

    public init(operationID: UUID, status: String) {
        self.operationID = operationID
        self.status = status
    }
}

public struct ProposalStatusParams: Sendable, Equatable, Codable {
    public let operationID: UUID

    public init(operationID: UUID) {
        self.operationID = operationID
    }
}

public struct ProposalStatusReply: Sendable, Equatable, Codable {
    public let operationID: UUID
    public let status: String
    /// Terminal launch outcome once the permit is consumed: "launched",
    /// "failed", or "unknown" (transport lost after consume). Nil while the
    /// operation has no redemption outcome. Advisory attribution only.
    public let launchResult: String?
    /// Fresh runtime/instance IDs for a launched operation. Identifiers for
    /// audit attribution only; never capabilities.
    public let runtimeSessionID: UUID?
    public let agentInstanceID: UUID?

    public init(
        operationID: UUID, status: String, launchResult: String? = nil,
        runtimeSessionID: UUID? = nil, agentInstanceID: UUID? = nil
    ) {
        self.operationID = operationID
        self.status = status
        self.launchResult = launchResult
        self.runtimeSessionID = runtimeSessionID
        self.agentInstanceID = agentInstanceID
    }
}
