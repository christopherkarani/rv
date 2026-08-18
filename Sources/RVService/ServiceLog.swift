import Foundation

public struct ServiceLogEvent: Sendable, Equatable {
    public var method: String
    public var decision: String?
    public var ruleID: String?
    public var elapsedMs: Double
    public var requestID: UUID

    public init(
        method: String,
        decision: String? = nil,
        ruleID: String? = nil,
        elapsedMs: Double,
        requestID: UUID
    ) {
        self.method = method
        self.decision = decision
        self.ruleID = ruleID
        self.elapsedMs = elapsedMs
        self.requestID = requestID
    }
}

public protocol ServiceLog: Sendable {
    func record(_ event: ServiceLogEvent)
}
