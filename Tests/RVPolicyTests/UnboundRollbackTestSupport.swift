import Foundation
@testable import RVPolicy

/// Gate and log tests exercise the store rollback itself, with no preview
/// to bind to. Production callers must pass a `PolicyRollbackBinding`.
extension TypedRuleStore {
    @discardableResult
    func rollbackMachine(to revision: Int) throws -> PolicyRevision {
        try rollbackMachine(to: revision, binding: nil)
    }

    @discardableResult
    func rollbackRepo(to revision: Int, workspace: URL) throws -> PolicyRevision {
        try rollbackRepo(to: revision, workspace: workspace, interlock: nil)
    }
}

extension PolicyRollbackBinding {
    /// For calls that must refuse before any binding is checked.
    static let unchecked = PolicyRollbackBinding(
        target: PolicyRevisionHead(revision: 1, hash: ""),
        head: PolicyRevisionHead(revision: 1, hash: "")
    )
}
