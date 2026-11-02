import Dispatch
import Foundation
import RVDomain

/// How long a request an `approve` rule matches is held open for a human.
/// Agents' HTTP clients time out in well under the 15 minutes an approval
/// lives, so the request is refused as pending after `wait`; an identical
/// retry once the human has said yes is forwarded.
public struct GatewayApprovalTiming: Sendable {
    public var wait: TimeInterval
    public var poll: TimeInterval
    /// Held requests use gateway connection slots (64); past this many, a
    /// request is checked once and not held.
    public var maximumWaiting: Int

    public init(wait: TimeInterval, poll: TimeInterval, maximumWaiting: Int) {
        self.wait = wait
        self.poll = poll
        self.maximumWaiting = maximumWaiting
    }

    public static let standard = GatewayApprovalTiming(wait: 20, poll: 1, maximumWaiting: 16)
}

/// Files approvals through a runtime's admission channel.
struct SecretRequestApprover: Sendable {
    let asker: any ActionApprovalAsking
    /// Resolved per request, so a revoked principal never approves on a
    /// stale snapshot. Nil once the runtime's channel is gone.
    let subject: @Sendable () -> RuntimeAdmissionSubject?
}

extension RuntimeAdmissionSession {
    /// Nil when this runtime's admission has no approval service to ask.
    func secretRequestApprover() -> SecretRequestApprover? {
        guard let asker = askBackend else { return nil }
        return SecretRequestApprover(asker: asker) { [weak self] in self?.currentSubject() }
    }
}

extension SecretGateway {
    struct ParkedApproval {
        var token: String
        var approval: CreatedActionApproval
        var approver: SecretRequestApprover
        var filed: Date
    }

    /// How long the approval service keeps an approval
    /// (`ActionApprovalAuthorization.approvalLifetime`); older parked entries are dropped.
    static let approvalLifetime: TimeInterval = 15 * 60

    /// Nil lets the request through: no `approve` rule matches it, or a
    /// human approved this exact request and the grant was consumed now.
    func approval(
        _ entry: Entry, token: String, method: String, route: GatewayRoute, basePath: String, url: URL,
        target: String, body: Data
    ) -> GatewayRefusal? {
        // An ambiguous path is held too: only a request clearly outside the rules skips the human.
        guard entry.approvals.isEmpty == false,
            GatewayAccess.refusal(entry.approvals, method: method, route: route, basePath: basePath)
                != .outsideAllowRules
        else { return nil }
        // Only a live, usable agent principal can be asked about; the approval
        // service refuses anything else, so fail before filing.
        guard let approver = entry.approver, let subject = approver.subject(), subject.agent?.isUsable == true else {
            return .approvalUnavailable
        }
        let action = ProposedAction.secretRequest(SecretRequestAction(
            secret: entry.secret, method: method, host: url.host ?? "",
            path: basePath + SecretPlaceholder.redactedPath(route.remainder),
            targetSHA256: RVDigest.sha256Hex(Array(target.utf8)), bodySHA256: RVDigest.sha256Hex(Array(body)),
            bodyBytes: body.count))
        let digest = CanonicalActionDigest.sha256Hex(of: action)
        lock.lock()
        let existing = parkedApprovals[digest]
        lock.unlock()
        if let existing { return awaitApproval(existing, digest: digest) }
        guard let created = approver.asker.createApproval(
            subject: subject, action: action, reason: .mandatoryHuman,
            policyContext: "secret \(entry.secret): approve rule")
        else { return .approvalUnavailable }
        let filed = ParkedApproval(token: token, approval: created, approver: approver, filed: now())
        lock.lock()
        let cutoff = filed.filed.addingTimeInterval(-Self.approvalLifetime)
        parkedApprovals = parkedApprovals.filter { $0.value.filed > cutoff }
        // A concurrent identical request may have filed first: wait on its approval, withdraw ours.
        let winner = parkedApprovals[digest] ?? filed
        parkedApprovals[digest] = winner
        lock.unlock()
        if winner.approval.approvalID != created.approvalID { approver.asker.cancelApproval(created) }
        return awaitApproval(winner, digest: digest)
    }

    private func awaitApproval(_ parked: ParkedApproval, digest: String) -> GatewayRefusal? {
        lock.lock()
        let holds = waitingApprovals < approvalTiming.maximumWaiting
        if holds { waitingApprovals += 1 }
        lock.unlock()
        defer {
            if holds {
                lock.lock()
                waitingApprovals -= 1
                lock.unlock()
            }
        }
        let asker = parked.approver.asker
        let deadline = DispatchTime.now() + (holds ? approvalTiming.wait : 0)
        while true {
            switch asker.approvalStatus(parked.approval) {
            case .authorized:
                forget(digest)
                // Single use and bound to this digest by the approval service.
                return asker.consumeApproval(parked.approval, actionDigestHex: digest) ? nil : .approvalDenied
            case .pending, .awaitingAuthentication, nil:
                // nil is a transport blip: keep the approval and keep waiting.
                guard DispatchTime.now() < deadline else { return .approvalPending }
                Thread.sleep(forTimeInterval: approvalTiming.poll)
            case .consumed, .denied, .cancelled, .expired, .invalidated, .failed, .unknown:
                forget(digest)
                return .approvalDenied
            }
        }
    }

    private func forget(_ digest: String) {
        lock.lock()
        parkedApprovals[digest] = nil
        lock.unlock()
    }

    /// Cancels approvals filed for `tokens`, or all when nil. Best effort.
    func cancelApprovals(for tokens: Set<String>?) {
        lock.lock()
        let cancelled = parkedApprovals.filter { tokens?.contains($0.value.token) ?? true }
        for digest in cancelled.keys { parkedApprovals[digest] = nil }
        lock.unlock()
        for parked in cancelled.values { parked.approver.asker.cancelApproval(parked.approval) }
    }
}
