import ArgumentParser
import RVDomain
import RVHooks

/// Transitional fail-closed boundary until authenticated service mutation routes exist.
enum LocalControlBoundary {
    static let reason = "Authenticated RV service and operation-bound owner authorization required."

    static func requireOwnerAuthorization() throws {
        throw ValidationError(reason)
    }

    static func deniedHook(host: HookHost) -> HookWire {
        productionHostCodec(host).encodeDeny(reason: reason, rule: nil, next: .none)
    }
}
