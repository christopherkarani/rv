#if os(macOS)
import Foundation
import RVDomain
import RVIPC
import RVIsolation
import RVService
import Synchronization

/// Live Step 6 approval driver: speaks to rvd over the host's authenticated
/// principal bridge. All calls are synchronous and bounded (fail-closed on
/// timeout or transport failure), matching the admission pipeline's shape;
/// the human wait itself happens in the session's asynchronous waiter.
///
/// Creation, status, and consume re-prove the live principal: the bridge
/// client checks its live authority before and after each exchange, and the
/// service re-validates via its own validity RPC before acting. Cancel
/// instead transmits a descriptive reference (live or dead) with no
/// liveness re-check: it authorizes nothing, and the service proves death
/// via its own pull to invalidate eagerly. No call blocks the human wait —
/// creation, status, consume, and cancel are all fast RPCs.
struct HostActionApprovalBackend: ActionApprovalAsking, Sendable {
    private let bridge: WorkspaceHostBridgeClient
    private let timeoutSeconds: TimeInterval

    init(bridge: WorkspaceHostBridgeClient, timeoutSeconds: TimeInterval = 11) {
        self.bridge = bridge
        self.timeoutSeconds = timeoutSeconds
    }

    func createApproval(
        subject: RuntimeAdmissionSubject,
        action: ProposedAction,
        reason: RuntimeAskReason,
        policyContext: String
    ) -> CreatedActionApproval? {
        let result = Mutex<HostActionApprovalCreatedDTO?>(nil)
        let finished = DispatchSemaphore(value: 0)
        let task = Task {
            defer { finished.signal() }
            if let created = try? await bridge.createActionApproval(
                subject: subject, action: action, reason: reason, policyContext: policyContext
            ) {
                result.withLock { $0 = created }
            }
        }
        guard finished.wait(timeout: .now() + timeoutSeconds) == .success else {
            task.cancel()
            return nil
        }
        guard let created = result.withLock({ $0 }) else { return nil }
        return CreatedActionApproval(
            approvalID: created.approvalID,
            continuationID: created.continuationID,
            subject: subject)
    }

    func approvalStatus(_ approval: CreatedActionApproval) -> String? {
        let result = Mutex<String?>(nil)
        let finished = DispatchSemaphore(value: 0)
        let task = Task {
            defer { finished.signal() }
            if let status = try? await bridge.actionApprovalStatus(
                approvalID: approval.approvalID, subject: approval.subject
            ) {
                result.withLock { $0 = status }
            }
        }
        guard finished.wait(timeout: .now() + timeoutSeconds) == .success else {
            task.cancel()
            return nil
        }
        return result.withLock { $0 }
    }

    func consumeApproval(
        _ approval: CreatedActionApproval,
        actionDigestHex: String
    ) -> Bool {
        let result = Mutex(false)
        let finished = DispatchSemaphore(value: 0)
        let task = Task {
            defer { finished.signal() }
            if let decision = try? await bridge.consumeActionApproval(
                approvalID: approval.approvalID,
                subject: approval.subject,
                actionDigestHex: actionDigestHex,
                continuationID: approval.continuationID
            ), decision.mayExecute {
                result.withLock { $0 = true }
            }
        }
        guard finished.wait(timeout: .now() + timeoutSeconds) == .success else {
            task.cancel()
            return false
        }
        return result.withLock { $0 }
    }

    func cancelApproval(_ approval: CreatedActionApproval) {
        let finished = DispatchSemaphore(value: 0)
        let task = Task {
            defer { finished.signal() }
            _ = try? await bridge.cancelActionApproval(
                approvalID: approval.approvalID, subject: approval.subject)
        }
        // Aligned past the exchange's own 10s bound like the other RPCs:
        // an earlier backend timeout would task-cancel into the shared
        // connection and kill the bridge for subsequent calls.
        guard finished.wait(timeout: .now() + timeoutSeconds) == .success else {
            task.cancel()
            return
        }
    }
}
#endif
