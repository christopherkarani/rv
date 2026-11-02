import ArgumentParser

/// Transitional fail-closed boundary until authenticated service mutation routes exist.
enum LocalControlBoundary {
    static let reason = "Authenticated RV service and operation-bound owner authorization required."

    static func requireOwnerAuthorization() throws {
        throw ValidationError(reason)
    }
}
