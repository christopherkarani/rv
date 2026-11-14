import Foundation
import RVHistory
import RVPolicy
import Synchronization

/// `policy.managed` events for organization bundle transitions a running
/// process observes: a bundle that stops verifying, goes away, verifies
/// again, or changes content without a higher serial. A newly accepted
/// serial is recorded where it is accepted (`ManagedSerialStore`), so a raise
/// is not recorded twice.
///
/// The first state a process loads is its baseline and records nothing, so
/// short-lived CLI runs stay quiet and `rvd` records what changes while it
/// runs. A transition the audit log cannot hold is retried on the next load.
enum ManagedGateAudit {
    /// What a transition compares: kind, content hash, serial, reason.
    struct Seen: Equatable, Sendable {
        var kind: String
        var sha256: String?
        var serial: Int?
        var reason: String?

        init(_ state: ManagedPolicyState) {
            switch state {
            case .none:
                kind = "none"
            case .active(let bundle):
                kind = "active"
                sha256 = bundle.sha256
                serial = bundle.policy.serial
            case .invalid(let why):
                kind = "invalid"
                reason = why
            }
        }
    }

    private static let seen = Mutex<[String: Seen]>([:])

    /// Records the transition from the last state seen for `configDirectory`.
    static func observe(_ state: ManagedPolicyState, configDirectory: URL) {
        let key = configDirectory.path
        let now = Seen(state)
        let previous: Seen? = seen.withLock { map in
            let previous = map[key]
            map[key] = now
            return previous
        }
        guard let previous, previous != now, let event = event(from: previous, to: state) else { return }
        guard AuditLog.append(event, configDirectory: configDirectory) else {
            // Not recorded: put the old state back so the next load retries.
            seen.withLock { map in
                if map[key] == now { map[key] = previous }
            }
            return
        }
    }

    /// Nil for a raised serial on an active bundle (recorded when accepted).
    static func event(from previous: Seen, to state: ManagedPolicyState) -> AuditEvent? {
        var detail = ["prior_state": previous.kind]
        if let sha = previous.sha256 { detail["prior_sha256"] = sha }
        if let serial = previous.serial { detail["prior_serial"] = String(serial) }
        let subject: String
        var decision = AuditDecision.info
        var reason: String?
        switch state {
        case .none:
            subject = "organization policy"
            detail["change"] = "removed"
        case .invalid(let why):
            subject = "organization policy"
            detail["change"] = "verification-failed"
            decision = .failed
            reason = why
        case .active(let bundle):
            if previous.kind == "active", let serial = bundle.policy.serial, serial > (previous.serial ?? Int.min) {
                return nil
            }
            subject = bundle.policy.organization ?? bundle.directory
            detail["change"] = previous.kind == "active" ? "changed" : "verified"
            detail["sha256"] = bundle.sha256
            detail["directory"] = bundle.directory
            detail["signed"] = String(bundle.isSigned)
            if let serial = bundle.policy.serial { detail["serial"] = String(serial) }
            detail["authorized_by"] = bundle.signingKey.map { "organization signature (key \($0))" }
                ?? (bundle.isSigned ? "organization signature" : "unsigned bundle")
        }
        var event = ConfigChangeAudit.event(.policyManaged, subject: subject, detail: detail)
        event.decision = decision
        event.reason = reason
        return event
    }
}
