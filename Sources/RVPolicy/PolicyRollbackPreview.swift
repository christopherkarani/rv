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

/// What an owner approved after a preview: the revision to restore and
/// the head it replaces, each as revision number plus content hash. A
/// rollback given this binding refuses `headChanged` when either differs
/// under the lock.
public struct PolicyRollbackBinding: Sendable, Equatable {
    public var target: PolicyRevisionHead
    public var head: PolicyRevisionHead

    public init(target: PolicyRevisionHead, head: PolicyRevisionHead) {
        self.target = target
        self.head = head
    }

    public init(target: PolicyRevision, head: PolicyRevision) {
        self.init(target: PolicyRevisionHead(target), head: PolicyRevisionHead(head))
    }
}

/// One revision a rollback preview showed: revision number plus content hash.
public struct PolicyRevisionHead: Sendable, Equatable {
    public var revision: Int
    public var hash: String

    public init(revision: Int, hash: String) {
        self.revision = revision
        self.hash = hash
    }

    public init(_ entry: PolicyRevision) {
        self.init(revision: entry.revision, hash: entry.hash)
    }
}
