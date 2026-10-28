import ArgumentParser
import RVDomain
import RVHooks

/// Why a hook consult could not reach an authorized evaluation.
///
/// Every case still denies: the cause only changes the guidance the
/// blocked agent sees, so "the service is down" stops reading as a
/// policy verdict.
enum HookUnavailability: Sendable, Equatable {
    /// No transport, or the service could not be reached.
    case serviceUnreachable
    /// The service took longer than the hook budget.
    case serviceTimeout
    /// CLI and service major versions disagree.
    case versionSkew(clientSemver: String, serviceSemver: String?)
    /// The running service failed its identity check.
    case daemonRejected

    var reason: String {
        switch self {
        case .serviceUnreachable:
            "The RV background service (rvd) is not reachable, so this command was blocked. Run `rv doctor` to diagnose it."
        case .serviceTimeout:
            "The RV background service (rvd) did not answer in time, so this command was blocked. Retry the command; if it keeps happening, run `rv doctor`."
        case .versionSkew(let clientSemver, let serviceSemver):
            "The rv CLI and the rvd service versions disagree (cli \(clientSemver), service \(serviceSemver ?? "unknown")), so this command was blocked. Reinstall RV so both match."
        case .daemonRejected:
            "The running rvd service failed its identity check, so this command was blocked. Run `rv setup` to restart the service."
        }
    }
}

/// Transitional fail-closed boundary until authenticated service mutation routes exist.
enum LocalControlBoundary {
    static let reason = "Authenticated RV service and operation-bound owner authorization required."

    static func requireOwnerAuthorization() throws {
        throw ValidationError(reason)
    }

    static func deniedHook(host: HookHost, cause: HookUnavailability) -> HookWire {
        productionHostCodec(host).encodeDeny(reason: cause.reason, rule: nil, next: .none)
    }
}
