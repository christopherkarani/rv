import Foundation

/// Identity of one review row. Egress ids are pending-approval store ids;
/// block ids are derived by the source (the denial ledger has none).
/// Selection follows this id, never a row index, so a refresh that
/// inserts newer rows can never move a keypress onto another item.
public enum ReviewItemID: Hashable, Sendable {
    case egress(String)
    case block(String)
}

public enum ReviewItemKind: Equatable, Sendable {
    /// A network proposal awaiting a human. The only kind with actions.
    case pendingEgress
    /// A recorded denial. Read-only.
    case block
}

/// One row of the review pane as the source read it. Text is untrusted
/// (hosts, paths, reasons come from files an agent can influence); the
/// pane strips control and bidi scalars before display.
public struct ReviewItem: Equatable, Sendable {
    public var id: ReviewItemID
    public var kind: ReviewItemKind
    /// Sort key: newest first.
    public var at: Date
    public var summary: String
    public var detail: [String]

    public init(id: ReviewItemID, kind: ReviewItemKind, at: Date, summary: String, detail: [String]) {
        self.id = id
        self.kind = kind
        self.at = at
        self.summary = summary
        self.detail = detail
    }
}

public enum ReviewLoadResult: Equatable, Sendable {
    case loaded([ReviewItem])
    /// The queue could not be read. The pane shows the message and offers
    /// no actions until a later read succeeds.
    case failed(String)
}

/// What one approve or deny ceremony reported. The pane shows the text and
/// then re-reads the store; it never applies the outcome to a row itself.
public enum ReviewActionOutcome: Equatable, Sendable {
    case completed(String)
    case refused(String)
}

/// The stores behind the review pane. The CLI supplies the live
/// implementation; approve and deny must enter the same ceremony as
/// `rv egress approve` / `rv egress deny` (TTY, robot refusal, local
/// control boundary, device-owner authentication, throttling, re-read).
/// The pane only starts that flow.
public protocol ReviewQueueSource: Sendable {
    func load(now: Date) async -> ReviewLoadResult
    func approve(egress id: String) async -> ReviewActionOutcome
    func deny(egress id: String, reason: String) async -> ReviewActionOutcome
}
