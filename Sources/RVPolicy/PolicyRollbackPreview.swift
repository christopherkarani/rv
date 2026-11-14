import Foundation
import RVDomain

/// What a rollback would do, read without writing: the revision it would
/// restore, the current head, the live layer document (nil when it does
/// not parse, so the gate judges the head alone), and the union of the
/// risk reports the rollback gate judges. `risk.hasBlockingFindings` means
/// the rollback itself would refuse with `blockedByFindings`.
public struct PolicyRollbackPreview: Sendable, Equatable {
    public var target: PolicyRevision
    public var head: PolicyRevision
    public var live: PolicyDocument?
    public var risk: PolicyDiffRiskReport

    public init(
        target: PolicyRevision,
        head: PolicyRevision,
        live: PolicyDocument?,
        risk: PolicyDiffRiskReport
    ) {
        self.target = target
        self.head = head
        self.live = live
        self.risk = risk
    }
}
