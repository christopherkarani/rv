#if canImport(XPC)
import Darwin
import Foundation
import Synchronization
@preconcurrency import XPC

/// rvd's client for `dev.rv.judge`. Two-hop like every rv XPC client:
/// hello on the Mach-service discovery connection, hello again on the
/// anonymous endpoint it returns, then requests on that endpoint, which is
/// cached. Every reply's sender is verified before any field is read
/// (`JudgePoolTrust.verifySupervisor`): a Mach service name is not
/// identity. Any failure — unreachable, unverifiable, refused, malformed,
/// or past the deadline — returns nil, which the caller fails closed.
///
/// Calls block (they run on the judge's Dispatch threads, never the
/// cooperative pool) and are bounded by the caller's budget plus
/// `JudgePoolWire.transportSlack`.
public final class XPCJudgeClient: JudgeClient, Sendable {
    /// The most a handshake may take when no budget bounds it tighter.
    public static let helloTimeout: Duration = .seconds(1)

    private let serviceName: String
    private let siblingSupervisorPath: String?
    private let cached = Mutex<JudgePoolHeld?>(nil)

    public init(
        serviceName: String = JudgePoolWire.machServiceName,
        siblingSupervisorPath: String? = JudgePoolTrust.siblingPath("rv-judge")
    ) {
        self.serviceName = serviceName
        self.siblingSupervisorPath = siblingSupervisorPath
    }

    public func judge(key: ModelKey, input: JudgeInput, budget: Duration) -> PoolOutcome? {
        guard budget > .zero else { return nil }
        let request = JudgePoolRequest.judge(key: key, input: input, budgetMilliseconds: budget.wholeMilliseconds)
        guard case .outcome(let outcome)? = send(request, timeout: budget + JudgePoolWire.transportSlack) else { return nil }
        return outcome
    }

    public func warm(key: ModelKey) {
        DispatchQueue.global(qos: .utility).async {
            _ = self.send(.warm(key: key), timeout: Self.helloTimeout * 2)
        }
    }

    public func status(timeout: Duration) -> PoolStatus? {
        guard case .status(let status)? = send(.status, timeout: timeout) else { return nil }
        return status
    }

    private func send(_ request: JudgePoolRequest, timeout: Duration) -> JudgePoolReply? {
        let deadline = ContinuousClock.now + timeout
        guard let body = JudgePoolJSON.encode(request), let connection = connection(until: deadline) else {
            return nil
        }
        guard let reply = exchange(body, on: connection.object, until: deadline),
              JudgePoolTrust.verifySupervisor(reply: reply.object, siblingSupervisorPath: siblingSupervisorPath),
              let data = JudgePoolXPCBody.get(from: reply.object),
              let decoded = JudgePoolJSON.decode(JudgePoolReply.self, from: data),
              decoded != .refused else {
            forget(connection)
            return nil
        }
        return decoded
    }

    /// The cached, verified request connection, or a fresh one.
    private func connection(until deadline: ContinuousClock.Instant) -> JudgePoolHeld? {
        if let existing = cached.withLock({ $0 }) { return existing }
        guard let hello = JudgePoolJSON.encode(JudgePoolRequest.hello(protocolVersion: JudgePoolWire.protocolVersion))
        else { return nil }
        let handshakeDeadline = min(deadline, ContinuousClock.now + Self.helloTimeout)

        let discovery = xpc_connection_create_mach_service(serviceName, nil, 0)
        let heldDiscovery = JudgePoolHeld(discovery)
        xpc_connection_set_event_handler(discovery) { event in
            if xpc_get_type(event) == XPC_TYPE_ERROR { xpc_connection_cancel(heldDiscovery.object) }
        }
        xpc_connection_resume(discovery)
        defer { xpc_connection_cancel(discovery) }
        // Authenticated before its endpoint field is touched.
        guard let ack = exchange(hello, on: discovery, until: handshakeDeadline),
              acknowledges(ack),
              let endpoint = xpc_dictionary_get_value(ack.object, JudgePoolWire.xpcEndpointKey),
              xpc_get_type(endpoint) == XPC_TYPE_ENDPOINT else { return nil }

        let requests = xpc_connection_create_from_endpoint(endpoint)
        let held = JudgePoolHeld(requests)
        xpc_connection_set_event_handler(requests) { [weak self] event in
            guard xpc_get_type(event) == XPC_TYPE_ERROR else { return }
            self?.forget(held)
            xpc_connection_cancel(held.object)
        }
        xpc_connection_resume(requests)
        // The endpoint's own peer proves itself before any request.
        guard let second = exchange(hello, on: requests, until: handshakeDeadline), acknowledges(second) else {
            xpc_connection_cancel(requests)
            return nil
        }
        return cached.withLock { slot in
            if let winner = slot {
                xpc_connection_cancel(requests)
                return winner
            }
            slot = held
            return held
        }
    }

    private func acknowledges(_ reply: JudgePoolHeld) -> Bool {
        guard JudgePoolTrust.verifySupervisor(reply: reply.object, siblingSupervisorPath: siblingSupervisorPath),
              let data = JudgePoolXPCBody.get(from: reply.object),
              case .helloAck(let version)? = JudgePoolJSON.decode(JudgePoolReply.self, from: data) else {
            return false
        }
        return version == JudgePoolWire.protocolVersion
    }

    private func forget(_ connection: JudgePoolHeld) {
        let dropped = cached.withLock { slot -> Bool in
            guard let current = slot, current === connection else { return false }
            slot = nil
            return true
        }
        if dropped { xpc_connection_cancel(connection.object) }
    }

    /// One bounded request/reply; nil on an XPC error or the deadline.
    private func exchange(
        _ body: Data, on connection: xpc_connection_t, until deadline: ContinuousClock.Instant
    ) -> JudgePoolHeld? {
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        let slot = Mutex<JudgePoolHeld?>(nil)
        let message = xpc_dictionary_create_empty()
        JudgePoolXPCBody.set(body, on: message)
        xpc_connection_send_message_with_reply(connection, message, nil) { reply in
            if xpc_get_type(reply) == XPC_TYPE_DICTIONARY { slot.withLock { $0 = JudgePoolHeld(reply) } }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + JudgePoolSupervisor.dispatchInterval(remaining)) == .success else {
            return nil
        }
        return slot.withLock { $0 }
    }
}
#endif
