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
    /// After the cached connection breaks (the supervisor exited or was
    /// restarted), reconnect and re-warm the last model at these delays,
    /// stopping at the first connection. launchd restarts the agent within
    /// its ThrottleInterval (5 s).
    static let rewarmDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)]

    private let discover: @Sendable () -> xpc_connection_t
    private let verify: @Sendable (xpc_object_t) -> Bool
    private let rewarmDelays: [Duration]
    private let cached = Mutex<JudgePoolHeld?>(nil)
    private let lastKey = Mutex<ModelKey?>(nil)

    public convenience init(
        serviceName: String = JudgePoolWire.machServiceName,
        siblingSupervisorPath: String? = JudgePoolTrust.siblingPath("rv-judge")
    ) {
        self.init(
            discover: { xpc_connection_create_mach_service(serviceName, nil, 0) },
            verify: { JudgePoolTrust.verifySupervisor(reply: $0, siblingSupervisorPath: siblingSupervisorPath) })
    }

    /// `discover` opens a connection to the discovery listener; `verify`
    /// authenticates every reply before it is read.
    init(
        discover: @escaping @Sendable () -> xpc_connection_t,
        verify: @escaping @Sendable (xpc_object_t) -> Bool,
        rewarmDelays: [Duration] = XPCJudgeClient.rewarmDelays
    ) {
        self.discover = discover
        self.verify = verify
        self.rewarmDelays = rewarmDelays
    }

    public func judge(key: ModelKey, input: JudgeInput, budget: Duration) -> PoolOutcome? {
        guard budget > .zero else { return nil }
        lastKey.withLock { $0 = key }
        let deadline = ContinuousClock.now + budget + JudgePoolWire.transportSlack
        guard let connection = connection(until: deadline) else { return nil }
        // The pool gets only what is left once the connection is up.
        let left = deadline - ContinuousClock.now - JudgePoolWire.transportSlack
        guard left >= .milliseconds(1) else { return nil }
        let request = JudgePoolRequest.judge(key: key, input: input, budgetMilliseconds: left.wholeMilliseconds)
        guard case .outcome(let outcome)? = call(request, on: connection, until: deadline) else { return nil }
        return outcome
    }

    public func warm(key: ModelKey) {
        lastKey.withLock { $0 = key }
        DispatchQueue.global(qos: .utility).async {
            let deadline = ContinuousClock.now + Self.helloTimeout * 2
            // A new connection sends warm itself.
            guard let connection = self.connection(until: deadline, warmNew: false) else { return }
            _ = self.call(.warm(key: key), on: connection, until: deadline)
        }
    }

    public func status(timeout: Duration) -> PoolStatus? {
        let deadline = ContinuousClock.now + timeout
        guard let connection = connection(until: deadline),
              case .status(let status)? = call(.status, on: connection, until: deadline) else { return nil }
        return status
    }

    /// One request on `connection`. A reply that fails verification, is
    /// malformed or refused, or an XPC error, drops the cached connection.
    /// A timeout does not: the supervisor answers late but the connection
    /// is sound, and dropping it would fail every other request in flight.
    private func call(
        _ request: JudgePoolRequest, on connection: JudgePoolHeld, until deadline: ContinuousClock.Instant
    ) -> JudgePoolReply? {
        guard let body = JudgePoolJSON.encode(request) else { return nil }
        switch exchange(body, on: connection.object, until: deadline) {
        case .timedOut:
            return nil
        case .failed:
            forget(connection)
            return nil
        case .reply(let reply):
            guard verify(reply.object),
                  let data = JudgePoolXPCBody.get(from: reply.object),
                  let decoded = JudgePoolJSON.decode(JudgePoolReply.self, from: data),
                  decoded != .refused else {
                forget(connection)
                return nil
            }
            return decoded
        }
    }

    /// The cached, verified request connection, or a fresh one. A fresh
    /// connection re-warms the last model asked for (a restarted supervisor
    /// starts cold) unless `warmNew` is false.
    private func connection(until deadline: ContinuousClock.Instant, warmNew: Bool = true) -> JudgePoolHeld? {
        if let existing = cached.withLock({ $0 }) { return existing }
        guard let hello = JudgePoolJSON.encode(JudgePoolRequest.hello(protocolVersion: JudgePoolWire.protocolVersion))
        else { return nil }
        let handshakeDeadline = min(deadline, ContinuousClock.now + Self.helloTimeout)

        let discovery = discover()
        let heldDiscovery = JudgePoolHeld(discovery)
        xpc_connection_set_event_handler(discovery) { event in
            if xpc_get_type(event) == XPC_TYPE_ERROR { xpc_connection_cancel(heldDiscovery.object) }
        }
        xpc_connection_resume(discovery)
        defer { xpc_connection_cancel(discovery) }
        // Authenticated before its endpoint field is touched.
        guard case .reply(let ack) = exchange(hello, on: discovery, until: handshakeDeadline),
              acknowledges(ack),
              let endpoint = xpc_dictionary_get_value(ack.object, JudgePoolWire.xpcEndpointKey),
              xpc_get_type(endpoint) == XPC_TYPE_ENDPOINT else { return nil }

        let requests = xpc_connection_create_from_endpoint(endpoint)
        let held = JudgePoolHeld(requests)
        xpc_connection_set_event_handler(requests) { [weak self] event in
            guard xpc_get_type(event) == XPC_TYPE_ERROR else { return }
            // Only the live cached connection breaking means the supervisor
            // went away; one this client dropped or cancelled itself does not.
            if let self, self.forget(held) { self.rewarm(attempt: 0) }
            xpc_connection_cancel(held.object)
        }
        xpc_connection_resume(requests)
        // The endpoint's own peer proves itself before any request.
        guard case .reply(let second) = exchange(hello, on: requests, until: handshakeDeadline),
              acknowledges(second) else {
            xpc_connection_cancel(requests)
            return nil
        }
        let winner = cached.withLock { slot -> JudgePoolHeld in
            if let winner = slot { return winner }
            slot = held
            return held
        }
        guard winner === held else {
            xpc_connection_cancel(requests)
            return winner
        }
        if warmNew, let key = lastKey.withLock({ $0 }) {
            DispatchQueue.global(qos: .utility).async {
                _ = self.call(.warm(key: key), on: held, until: ContinuousClock.now + Self.helloTimeout * 2)
            }
        }
        return held
    }

    /// Reconnects (which re-warms) after the supervisor went away, retrying
    /// at `rewarmDelays` until a connection is up or the delays run out.
    private func rewarm(attempt: Int) {
        guard attempt < rewarmDelays.count, lastKey.withLock({ $0 }) != nil else { return }
        let delay = JudgePoolSupervisor.dispatchInterval(rewarmDelays[attempt])
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.cached.withLock({ $0 }) == nil else { return }
            if self.connection(until: ContinuousClock.now + Self.helloTimeout) == nil {
                self.rewarm(attempt: attempt + 1)
            }
        }
    }

    private func acknowledges(_ reply: JudgePoolHeld) -> Bool {
        guard verify(reply.object),
              let data = JudgePoolXPCBody.get(from: reply.object),
              case .helloAck(let version)? = JudgePoolJSON.decode(JudgePoolReply.self, from: data) else {
            return false
        }
        return version == JudgePoolWire.protocolVersion
    }

    /// Drops `connection` if it is the cached one; returns whether it was.
    @discardableResult
    private func forget(_ connection: JudgePoolHeld) -> Bool {
        let dropped = cached.withLock { slot -> Bool in
            guard let current = slot, current === connection else { return false }
            slot = nil
            return true
        }
        if dropped { xpc_connection_cancel(connection.object) }
        return dropped
    }

    enum Exchange {
        case reply(JudgePoolHeld)
        /// An XPC error instead of a reply: the connection is broken.
        case failed
        /// No answer by the deadline; says nothing about the connection.
        case timedOut
    }

    /// One bounded request/reply.
    private func exchange(
        _ body: Data, on connection: xpc_connection_t, until deadline: ContinuousClock.Instant
    ) -> Exchange {
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { return .timedOut }
        let semaphore = DispatchSemaphore(value: 0)
        let slot = Mutex<JudgePoolHeld?>(nil)
        let message = xpc_dictionary_create_empty()
        JudgePoolXPCBody.set(body, on: message)
        xpc_connection_send_message_with_reply(connection, message, nil) { reply in
            if xpc_get_type(reply) == XPC_TYPE_DICTIONARY { slot.withLock { $0 = JudgePoolHeld(reply) } }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + JudgePoolSupervisor.dispatchInterval(remaining)) == .success else {
            return .timedOut
        }
        return slot.withLock { $0 }.map { .reply($0) } ?? .failed
    }
}
#endif
