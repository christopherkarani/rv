import Foundation

/// Pure arrival tracking for the hook review list: which approval IDs have
/// appeared since the baseline and not yet been opened.
struct ArrivalLedger<ID: Hashable & Sendable>: Equatable, Sendable {
    private(set) var seen: Set<ID> = []
    private(set) var unseen: Set<ID> = []

    /// Rows already pending when the app (re)connects are not arrivals.
    mutating func baseline(_ ids: [ID]) {
        seen.formUnion(ids)
        unseen.removeAll()
    }

    /// Folds a freshly listed set in: never-before-listed IDs become unseen;
    /// IDs that vanished server-side stop being unseen.
    mutating func observe(_ ids: [ID]) {
        let current = Set(ids)
        unseen = unseen.intersection(current).union(current.subtracting(seen))
        seen.formUnion(current)
    }

    /// Opening a request marks it seen: the human is looking at it.
    mutating func open(_ id: ID) {
        unseen.remove(id)
    }
}
