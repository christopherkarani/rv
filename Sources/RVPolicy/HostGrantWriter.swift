import Foundation
import RVDomain

public enum HostGrantRejection: Sendable, Equatable {
    /// Missing cwd, empty matching view, or no spend callback.
    case missingCallback
    case spendFailed
}

public enum HostGrantSpendResult: Sendable, Equatable {
    case spent(tokenID: String)
    case rejected(HostGrantRejection)
}

/// Same-turn host Allow once on the existing `AllowOnceStore` ledger.
public enum HostGrantWriter {
    /// Plant a granted row and spend it this turn. Fail-closed.
    public static func plantAndSpend(
        matchingView: MatchingView,
        cwd: WorkingDirectory?,
        store: AllowOnceStore,
        now: Date
    ) async -> HostGrantSpendResult {
        guard let cwd, matchingView.isEmpty == false else {
            return .rejected(.missingCallback)
        }
        switch await store.plantAndConsume(
            matchingView: matchingView,
            cwd: cwd,
            now: now
        ) {
        case .consumed(let tokenID):
            return .spent(tokenID: tokenID)
        case .notFound, .alreadyConsumed, .expired, .unavailable:
            return .rejected(.spendFailed)
        }
    }
}
