import Foundation
import RVDomain

public struct ServiceLogEvent: Sendable, Equatable {
    public var method: String
    public var decision: String?
    public var ruleID: String?
    public var elapsedMs: Double
    public var requestID: UUID
    public var principal: AgentPrincipalReference?

    public init(
        method: String,
        decision: String? = nil,
        ruleID: String? = nil,
        elapsedMs: Double,
        requestID: UUID,
        principal: AgentPrincipalReference? = nil
    ) {
        self.method = method
        self.decision = decision
        self.ruleID = ruleID
        self.elapsedMs = elapsedMs
        self.requestID = requestID
        self.principal = principal
    }
}

public protocol ServiceLog: Sendable {
    func record(_ event: ServiceLogEvent)
}
