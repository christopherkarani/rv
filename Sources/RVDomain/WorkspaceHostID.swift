import Foundation

/// Identifier of one persistent workspace-host process.
///
/// This is not `WorkspaceSessionID`, `RuntimeSessionID`, or hook `SessionID`.
/// A pid is not this value. The host mints it when the process starts, and
/// clients learn it from the owner-bound endpoint record.
public struct WorkspaceHostID: Hashable, Sendable, Equatable {
    public let rawValue: UUID

    public init() {
        self.rawValue = UUID()
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}
