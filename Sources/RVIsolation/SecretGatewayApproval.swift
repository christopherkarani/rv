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
    /// An approval is filed for one placeholder, so one runtime: another
    /// runtime's identical request never waits on or spends it.
    struct ParkedApprovalKey: Hashable {
        var token: String
        var digest: String
    }

    struct ParkedApproval {
        var token: String
        var approval: CreatedActionApproval
        var approver: SecretRequestApprover
        var filed: Date
    }

    /// How long the approval service keeps an approval
    /// (`ActionApprovalAuthorization.approvalLifetime`); older parked entries are dropped.
    static let approvalLifetime: TimeInterval = 15 * 60

    /// Headers an SDK legitimately changes between retries of one call, so
    /// they are not bound. Hop-by-hop and framing headers are already gone
    /// by the time the gateway hashes. Every other header is bound.
    static let volatileHeaders: Set<String> = Set([
        "authorization", "date", "x-amz-date", "x-amz-content-sha256", "x-amz-security-token",
        "amz-sdk-invocation-id", "amz-sdk-request", "user-agent", "x-amz-user-agent", "content-length",
        "traceparent", "tracestate", "x-amzn-trace-id", "x-request-id", "idempotency-key",
    ]).union(GatewayHeaders.dropOnRequest)

    /// Headers that select the operation, shown to the approver.
    static let operationHeaderNames: Set<String> = ["x-amz-target", "x-amz-copy-source", "stripe-account", "content-type"]

    /// The longest header value shown; the hash covers the whole value.
    static let shownHeaderBytes = 200

    /// The hash binding the non-volatile `headers` and the operation-selecting
    /// ones to show. Runs before substitution, and placeholders are redacted
    /// from every value, so the hash is the same across runtimes.
    static func requestHeaders(_ headers: [(name: String, value: String)])
        -> (sha256: String, operation: [SecretRequestAction.Header])
    {
        let bound = headers.map { (name: $0.name.lowercased(), value: SecretPlaceholder.redacted($0.value)) }
            .filter { Self.volatileHeaders.contains($0.name) == false && $0.name.hasPrefix("proxy-") == false }
            .sorted { ($0.name, $0.value) < ($1.name, $1.value) }
        let canonical = bound.map { "\($0.name):\($0.value)" }.joined(separator: "\n")
        let shown = bound.filter { Self.operationHeaderNames.contains($0.name) }.map {
            SecretRequestAction.Header(name: $0.name, value: String($0.value.prefix(Self.shownHeaderBytes)))
        }
        return (RVDigest.sha256Hex(Array(canonical.utf8)), shown)
    }

    /// Nil lets the request through: no `approve` rule matches it, or a
    /// human approved this exact request and the grant was consumed now.
    func approval(
        _ entry: Entry, token: String, method: String, route: GatewayRoute, basePath: String, url: URL,
        target: String, headers: [(name: String, value: String)], body: Data
    ) -> GatewayRefusal? {
        // An ambiguous path is held too: only a request clearly outside the rules skips the human.
        guard entry.approvals.isEmpty == false,
            GatewayAccess.holds(entry.approvals, method: method, route: route, basePath: basePath)
        else { return nil }
        // Only a live, usable agent principal can be asked about; the approval
        // service refuses anything else, so fail before filing.
        guard let approver = entry.approver, let subject = approver.subject(), subject.agent?.isUsable == true else {
            return .approvalUnavailable
        }
        let bound = Self.requestHeaders(headers)
        let action = ProposedAction.secretRequest(SecretRequestAction(
            secret: entry.secret, method: method, host: url.host ?? "",
            path: basePath + SecretPlaceholder.redactedPath(route.remainder),
            targetSHA256: RVDigest.sha256Hex(Array(target.utf8)), bodySHA256: RVDigest.sha256Hex(Array(body)),
            bodyBytes: body.count, headersSHA256: bound.sha256, operationHeaders: bound.operation))
        let digest = CanonicalActionDigest.sha256Hex(of: action)
        let key = ParkedApprovalKey(token: token, digest: digest)
        lock.lock()
        let existing = parkedApprovals[key]
        lock.unlock()
        if let existing { return awaitApproval(existing, key: key) }
        guard let created = approver.asker.createApproval(
            subject: subject, action: action, reason: .mandatoryHuman,
            policyContext: "secret \(entry.secret): approve rule")
        else { return .approvalUnavailable }
        let filed = ParkedApproval(token: token, approval: created, approver: approver, filed: now())
        lock.lock()
        let cutoff = filed.filed.addingTimeInterval(-Self.approvalLifetime)
        parkedApprovals = parkedApprovals.filter { $0.value.filed > cutoff }
        // A concurrent identical request may have filed first: wait on its approval, withdraw ours.
        let winner = parkedApprovals[key] ?? filed
        parkedApprovals[key] = winner
        lock.unlock()
        if winner.approval.approvalID != created.approvalID { approver.asker.cancelApproval(created) }
        return awaitApproval(winner, key: key)
    }

    private func awaitApproval(_ parked: ParkedApproval, key: ParkedApprovalKey) -> GatewayRefusal? {
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
                forget(key)
                // Single use and bound to this digest by the approval service.
                return asker.consumeApproval(parked.approval, actionDigestHex: key.digest) ? nil : .approvalDenied
            case .pending, .awaitingAuthentication, nil:
                // nil is a transport blip: keep the approval and keep waiting.
                guard DispatchTime.now() < deadline else { return .approvalPending }
                Thread.sleep(forTimeInterval: approvalTiming.poll)
            case .consumed, .denied, .cancelled, .expired, .invalidated, .failed, .unknown:
                forget(key)
                return .approvalDenied
            }
        }
    }

    private func forget(_ key: ParkedApprovalKey) {
        lock.lock()
        parkedApprovals[key] = nil
        lock.unlock()
    }

    /// Cancels approvals filed for `tokens`, or all when nil. Best effort.
    func cancelApprovals(for tokens: Set<String>?) {
        lock.lock()
        let cancelled = parkedApprovals.filter { tokens?.contains($0.value.token) ?? true }
        for key in cancelled.keys { parkedApprovals[key] = nil }
        lock.unlock()
        for parked in cancelled.values { parked.approver.asker.cancelApproval(parked.approval) }
    }
}
