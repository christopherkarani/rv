import Foundation

/// Identifier RV mints for one contained execution.
///
/// This is not `SessionID`. Hook and host input can carry a `SessionID`.
/// Nothing outside RV's launch path can turn that value, or any chosen UUID,
/// into the identifier of a launch. `init()` always mints a new value.
/// `init(rawValue:)` only names an identifier RV already minted. Naming one
/// does not create a session and does not grant a capability.
public struct RuntimeSessionID: Hashable, Sendable, Equatable {
    public let rawValue: UUID

    public init() {
        self.rawValue = UUID()
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}
