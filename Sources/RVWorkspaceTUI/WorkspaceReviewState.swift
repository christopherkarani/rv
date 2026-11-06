import Foundation

/// Decision state for the review pane. The reducer owns every field; the
/// runtime only executes the load/approve/deny effects it emits.
///
/// Rows change only when a load lands. An approve or deny result never
/// edits a row: it sets the notice and forces a fresh load, so what the
/// pane shows is always what the store last said.
public struct WorkspaceReviewState: Equatable, Sendable {
    public enum Load: Equatable, Sendable {
        /// No read has landed yet.
        case loading
        case loaded([ReviewItem])
        case failed(String)
    }

    public enum Action: Equatable, Sendable {
        case approving(String)
        case denying(String)

        var id: String {
            switch self {
            case .approving(let id), .denying(let id): id
            }
        }
    }

    public struct Notice: Equatable, Sendable {
        public var text: String
        public var isError: Bool
    }

    /// Poll cadence for the stores while the shell runs.
    static let pollInterval: TimeInterval = 1.5
    /// Matches the store's canonical rejection-reason bound.
    static let maximumReasonLength = 500

    /// False when no source is configured: nothing polls and the pane
    /// refuses to open.
    public internal(set) var enabled: Bool
    public internal(set) var load: Load = .loading
    public internal(set) var selected: ReviewItemID?
    /// At most one ceremony at a time; no approve-all.
    public internal(set) var action: Action?
    public internal(set) var notice: Notice?
    /// Every issued load carries the next sequence. Only the newest
    /// in-flight sequence may land, so a slow read that started before an
    /// approve can never overwrite the post-approve re-read.
    var loadSequence: UInt64 = 0
    var inflightLoad: UInt64?
    var nextPollAt: Date?

    init(enabled: Bool) {
        self.enabled = enabled
    }

    public var items: [ReviewItem] {
        if case .loaded(let items) = load { return items }
        return []
    }

    public var pendingCount: Int {
        items.filter { $0.kind == .pendingEgress }.count
    }

    public var selectedItem: ReviewItem? {
        guard let selected else { return nil }
        return items.first { $0.id == selected }
    }
}
