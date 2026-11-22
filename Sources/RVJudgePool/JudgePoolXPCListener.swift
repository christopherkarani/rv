#if canImport(XPC)
import Foundation
import Synchronization
@preconcurrency import XPC

/// Raw libxpc listener on `dev.rv.judge`, in the custodian's and rvd's
/// two-hop shape: the Mach-service connection is discovery-only (hello →
/// anonymous endpoint), and requests run on endpoint connections that a
/// replacement process cannot rediscover. Every message's sender is
/// authorized from its own audit-token-bound code before it is read.
public final class JudgePoolXPCListener: Sendable {
    private let supervisor: JudgePoolSupervisor
    private let authorize: @Sendable (xpc_object_t) -> JudgePoolClient?
    private let makeDiscoveryListener: @Sendable () -> xpc_connection_t
    private let listener = Mutex<JudgePoolHeld?>(nil)
    private let endpointListener = Mutex<JudgePoolHeld?>(nil)
    private let peers = Mutex<[ObjectIdentifier: JudgePoolHeld]>([:])

    public convenience init(
        supervisor: JudgePoolSupervisor,
        machServiceName: String = JudgePoolWire.machServiceName,
        authorize: @escaping @Sendable (xpc_object_t) -> JudgePoolClient?
    ) {
        self.init(supervisor: supervisor, authorize: authorize) {
            xpc_connection_create_mach_service(machServiceName, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
        }
    }

    /// `discoveryListener` makes the listener the hello arrives on (the
    /// Mach service in production, an anonymous listener in tests).
    init(
        supervisor: JudgePoolSupervisor,
        authorize: @escaping @Sendable (xpc_object_t) -> JudgePoolClient?,
        discoveryListener: @escaping @Sendable () -> xpc_connection_t
    ) {
        self.supervisor = supervisor
        self.authorize = authorize
        self.makeDiscoveryListener = discoveryListener
    }

    public func start() {
        let requests = xpc_connection_create(nil, nil)
        xpc_connection_set_event_handler(requests) { [weak self] event in
            if xpc_get_type(event) == XPC_TYPE_CONNECTION { self?.accept(event, discoveryOnly: false) }
        }
        endpointListener.withLock { $0 = JudgePoolHeld(requests) }
        xpc_connection_resume(requests)
        let discovery = makeDiscoveryListener()
        xpc_connection_set_event_handler(discovery) { [weak self] event in
            if xpc_get_type(event) == XPC_TYPE_CONNECTION { self?.accept(event, discoveryOnly: true) }
        }
        listener.withLock { $0 = JudgePoolHeld(discovery) }
        xpc_connection_resume(discovery)
    }

    public func stop() {
        let taken = [
            endpointListener.withLock { state -> JudgePoolHeld? in
                defer { state = nil }
                return state
            },
            listener.withLock { state -> JudgePoolHeld? in
                defer { state = nil }
                return state
            },
        ]
        let connected = peers.withLock { state -> [JudgePoolHeld] in
            defer { state = [:] }
            return Array(state.values)
        }
        for held in taken.compactMap({ $0 }) + connected { xpc_connection_cancel(held.object) }
    }

    private func accept(_ peer: xpc_connection_t, discoveryOnly: Bool) {
        let endpoint = discoveryOnly
            ? endpointListener.withLock { $0.map { JudgePoolHeld(xpc_endpoint_create($0.object)) } }
            : nil
        let session = JudgePoolPeerSession(
            supervisor: supervisor, authorize: authorize, discoveryOnly: discoveryOnly, endpoint: endpoint)
        let held = JudgePoolHeld(peer)
        let id = ObjectIdentifier(held)
        peers.withLock { $0[id] = held }
        xpc_connection_set_event_handler(peer) { [weak self] event in
            if xpc_get_type(event) == XPC_TYPE_ERROR {
                self?.peers.withLock { $0[id] = nil }
                return
            }
            session.handle(event)
        }
        xpc_connection_resume(peer)
    }
}

final class JudgePoolPeerSession: Sendable {
    private let supervisor: JudgePoolSupervisor
    private let authorize: @Sendable (xpc_object_t) -> JudgePoolClient?
    private let discoveryOnly: Bool
    private let endpoint: JudgePoolHeld?
    private let handshake = Mutex(false)

    init(
        supervisor: JudgePoolSupervisor, authorize: @escaping @Sendable (xpc_object_t) -> JudgePoolClient?,
        discoveryOnly: Bool, endpoint: JudgePoolHeld?
    ) {
        self.supervisor = supervisor
        self.authorize = authorize
        self.discoveryOnly = discoveryOnly
        self.endpoint = endpoint
    }

    func handle(_ event: xpc_object_t) {
        guard xpc_get_type(event) == XPC_TYPE_DICTIONARY else { return }
        let message = JudgePoolHeld(event)
        // Authorized synchronously from this message's own code identity.
        guard let client = authorize(event),
              let body = JudgePoolXPCBody.get(from: event),
              let request = JudgePoolJSON.decode(JudgePoolRequest.self, from: body) else {
            respond(.refused, to: message)
            return
        }
        if case .hello = request {
        } else if discoveryOnly || !handshake.withLock({ $0 }) {
            // Requests only on an endpoint connection that said hello.
            respond(.refused, to: message)
            return
        }
        switch (client, request) {
        case (.evaluator, .warm), (.evaluator, .status):
            // The hook-local evaluator only asks for verdicts.
            respond(.refused, to: message)
            return
        default:
            break
        }
        switch request {
        case .hello(let version):
            guard version == JudgePoolWire.protocolVersion else {
                respond(.refused, to: message)
                return
            }
            handshake.withLock { $0 = true }
            respond(.helloAck(protocolVersion: JudgePoolWire.protocolVersion), to: message,
                    endpoint: discoveryOnly ? endpoint : nil)
        case .judge(let key, let input, let budgetMilliseconds):
            let budget = Duration.milliseconds(min(max(budgetMilliseconds, 0), 60_000))
            supervisor.submit(key: key, input: input, budget: budget) { [self] outcome in
                respond(.outcome(outcome), to: message)
            }
        case .warm(let key):
            supervisor.warm(key: key)
            respond(.ack, to: message)
        case .status:
            respond(.status(supervisor.status()), to: message)
        }
    }

    private func respond(_ reply: JudgePoolReply, to message: JudgePoolHeld, endpoint: JudgePoolHeld? = nil) {
        guard let data = JudgePoolJSON.encode(reply),
              let response = xpc_dictionary_create_reply(message.object) else { return }
        JudgePoolXPCBody.set(data, on: response)
        if let endpoint { xpc_dictionary_set_value(response, JudgePoolWire.xpcEndpointKey, endpoint.object) }
        if let peer = xpc_dictionary_get_remote_connection(message.object) {
            xpc_connection_send_message(peer, response)
        }
    }
}

/// The JSON body inside an XPC dictionary, shared by listener and client.
enum JudgePoolXPCBody {
    static func get(from message: xpc_object_t) -> Data? {
        var length = 0
        guard let bytes = xpc_dictionary_get_data(message, JudgePoolWire.xpcDataKey, &length) else { return nil }
        return Data(bytes: bytes, count: length)
    }

    static func set(_ data: Data, on message: xpc_object_t) {
        data.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress {
                xpc_dictionary_set_data(message, JudgePoolWire.xpcDataKey, base, buffer.count)
            } else {
                xpc_dictionary_set_data(message, JudgePoolWire.xpcDataKey, "", 0)
            }
        }
    }
}

// Immutable after init. libxpc objects are safe to use from any thread;
// the handle is only passed to xpc calls.
final class JudgePoolHeld: @unchecked Sendable {
    let object: xpc_object_t

    init(_ object: xpc_object_t) {
        self.object = object
    }
}
#endif
