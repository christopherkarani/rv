import Foundation

/// UI identity of one pane.
///
/// A pane is not a `RuntimeSessionID`. A session is a security and process
/// object owned by the workspace host. A pane only names a place in the
/// layout that may later show a terminal, an approval, or another surface.
public struct PaneID: Hashable, Sendable, Equatable, Codable {
    public let rawValue: UUID

    public init() {
        self.rawValue = UUID()
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}
