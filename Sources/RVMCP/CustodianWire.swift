import Foundation

/// Wire shapes between an approvals client and the custodian that holds
/// the key. No request or response can carry key material: clients send
/// purposes and fields, the custodian returns MAC strings and verdicts.
public enum MCPCustodianRequest: Sendable, Equatable, Codable {
    case status
    case mac(purpose: String, fields: [String], createIfMissing: Bool)
    case verify(candidate: String?, purpose: String, fields: [String])
}

public enum MCPCustodianError: String, Sendable, Equatable, Codable {
    case unauthorized
    case unavailable
    case badRequest
    case internalError
}

public enum MCPCustodianResponse: Sendable, Equatable, Codable {
    case status(MCPApprovalKeyStatus)
    case mac(String?)
    /// Nil means the custodian has no key to judge with; false means forged.
    case verify(Bool?)
    case error(MCPCustodianError)
}

/// Bounds on every custodian request, enforced on both sides of the seam.
/// The `enrollment` purpose is custodian-internal and never crosses it.
public enum MCPCustodianWire {
    public static let protocolVersion = "rv.mcp-custodian.v1"
    public static let allowedPurposes: Set<String> = ["grant", "code", "argument-keys", "mcp.json"]
    public static let maximumFields = 16
    public static let maximumFieldBytes = 64 * 1024
    public static let maximumCandidateBytes = 128

    public static func isValid(_ request: MCPCustodianRequest) -> Bool {
        switch request {
        case .status: true
        case .mac(let purpose, let fields, _): isValid(purpose: purpose, fields: fields, candidate: nil)
        case .verify(let candidate, let purpose, let fields): isValid(purpose: purpose, fields: fields, candidate: candidate)
        }
    }

    static func isValid(purpose: String, fields: [String], candidate: String?) -> Bool {
        guard allowedPurposes.contains(purpose), fields.count <= maximumFields else { return false }
        guard fields.reduce(0, { $0 + $1.utf8.count }) <= maximumFieldBytes else { return false }
        if let candidate, candidate.utf8.count > maximumCandidateBytes { return false }
        return true
    }
}
