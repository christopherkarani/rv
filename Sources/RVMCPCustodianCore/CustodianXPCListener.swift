#if canImport(XPC)
import Foundation
import RVIsolation
import RVMCP
import Synchronization
@preconcurrency import XPC

/// Raw libxpc listener on `dev.rv.mcp-custodian`, copying
/// `XPCEvaluateListener`'s two-hop shape: the Mach-service connection
/// is discovery-only (hello → anonymous endpoint), and requests run on
/// endpoint connections a replacement process cannot rediscover.
public final class CustodianXPCListener: Sendable {
    private let handler: CustodianRequestHandler
    private let watchdog: CustodianIdleWatchdog
    private let serviceName: String
    private let listener = Mutex<xpc_connection_t?>(nil)
    private let actionListener = Mutex<xpc_connection_t?>(nil)

    public init(
        handler: CustodianRequestHandler,
        watchdog: CustodianIdleWatchdog,
        machServiceName: String = MCPCustodianWire.machServiceName
    ) {
        self.handler = handler
        self.watchdog = watchdog
        self.serviceName = machServiceName
    }

    public func start() {
        let actions = xpc_connection_create(nil, nil)
        xpc_connection_set_event_handler(actions) { [weak self] event in
            if xpc_get_type(event) == XPC_TYPE_CONNECTION {
                self?.accept(event, discoveryOnly: false)
            }
        }
        actionListener.withLock { $0 = actions }
        xpc_connection_resume(actions)
        let connection = xpc_connection_create_mach_service(
            serviceName,
            nil,
            UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER)
        )
        xpc_connection_set_event_handler(connection) { [weak self] event in
            if xpc_get_type(event) == XPC_TYPE_CONNECTION {
                self?.accept(event, discoveryOnly: true)
            }
        }
        listener.withLock { $0 = connection }
        xpc_connection_resume(connection)
    }

    public func stop() {
        let actions = actionListener.withLock { state -> xpc_connection_t? in
            let current = state
            state = nil
            return current
        }
        if let actions { xpc_connection_cancel(actions) }
        let existing = listener.withLock { listener -> xpc_connection_t? in
            let current = listener
            listener = nil
            return current
        }
        if let existing { xpc_connection_cancel(existing) }
    }

    private func accept(_ peer: xpc_connection_t, discoveryOnly: Bool) {
        let endpoint = discoveryOnly ? actionListener.withLock { listener in
            listener.map { CustodianHeld(xpc_endpoint_create($0)) }
        } : nil
        let session = CustodianPeerSession(
            handler: handler, watchdog: watchdog,
            discoveryOnly: discoveryOnly, actionEndpoint: endpoint)
        xpc_connection_set_event_handler(peer) { event in
            session.handle(event)
        }
        xpc_connection_resume(peer)
    }
}

final class CustodianPeerSession: Sendable {
    private let handler: CustodianRequestHandler
    private let watchdog: CustodianIdleWatchdog
    private let handshake = Mutex(false)
    private let discoveryOnly: Bool
    private let actionEndpoint: CustodianHeld?
    private let connectionID = UUID()
    private let beginTransaction: @Sendable () -> Void
    private let endTransaction: @Sendable () -> Void

    init(
        handler: CustodianRequestHandler,
        watchdog: CustodianIdleWatchdog,
        discoveryOnly: Bool = false,
        actionEndpoint: CustodianHeld? = nil,
        beginTransaction: @escaping @Sendable () -> Void = { xpc_transaction_begin() },
        endTransaction: @escaping @Sendable () -> Void = { xpc_transaction_end() }
    ) {
        self.handler = handler
        self.watchdog = watchdog
        self.discoveryOnly = discoveryOnly
        self.actionEndpoint = actionEndpoint
        self.beginTransaction = beginTransaction
        self.endTransaction = endTransaction
    }

    func handle(_ event: xpc_object_t) {
        let type = xpc_get_type(event)
        if type == XPC_TYPE_ERROR {
            return
        }
        guard type == XPC_TYPE_DICTIONARY else {
            return
        }
        // The message's audit-token-backed SecCode is captured synchronously.
        // A payload PID, host label or later connection lookup cannot replace it.
        let trust = (try? ProtectedPeerTrustConfiguration.installed()) ?? .denyAll
        let peerRole = (try? MacOSPeerAuthenticator.capture(
            message: event, connectionID: connectionID, trust: trust
        ))?.componentRole
        beginTransaction()
        let held = CustodianHeld(event)
        Task {
            defer { self.endTransaction() }
            await self.watchdog.ping()
            let message = held.object
            let incoming = CustodianXPCWire.body(from: message) ?? Data()
            let accepted = self.handshake.withLock { $0 }
            let reply = self.handler.handleIncoming(
                incoming,
                peerRole: peerRole,
                handshakeOK: accepted,
                discoveryOnly: self.discoveryOnly)
            self.handshake.withLock { $0 = reply.handshakeAccepted }
            guard let response = xpc_dictionary_create_reply(message) else {
                return
            }
            CustodianXPCWire.set(reply.frame, on: response)
            if reply.includeEndpoint, let endpoint = self.actionEndpoint {
                xpc_dictionary_set_value(response, MCPCustodianWire.xpcEndpointKey, endpoint.object)
            }
            if let peer = xpc_dictionary_get_remote_connection(message) {
                xpc_connection_send_message(peer, response)
            }
        }
    }
}

// Immutable after init. libxpc objects are safe to use from multiple
// threads; the handle itself is never mutated, only passed to xpc calls.
final class CustodianHeld: @unchecked Sendable {
    let object: xpc_object_t

    init(_ object: xpc_object_t) {
        self.object = object
    }
}
#endif
