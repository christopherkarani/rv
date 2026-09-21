import Foundation

/// Identifier RV mints for one contained execution.
///
/// This is not `SessionID`. Hook and host input can carry a `SessionID`.
/// Nothing outside RV's launch path can turn that value, or any chosen UUID,
/// into the identifier of a launch. `init()` always mints a new value.
public struct RuntimeSessionID: Hashable, Sendable, Equatable {
    public let rawValue: UUID

    public init() {
        self.rawValue = UUID()
    }
}
