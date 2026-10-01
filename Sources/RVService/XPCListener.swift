#if canImport(XPC)
import Foundation
import RVIPC
import RVIsolation
import Synchronization
@preconcurrency import XPC

/// Dictionary key for UTF-8 `IPCRequest` / `IPCResponse` / Hello JSON (`IPCJSON`).
enum XPCIPCWire {
    static let key = "rv.ipc"
    static let actionEndpointKey = "rv.action-endpoint"

    static func body(from message: xpc_object_t) -> Data? {
        var length = 0
        guard let bytes = xpc_dictionary_get_data(message, key, &length) else {
            return nil
        }
        return Data(bytes: bytes, count: length)
    }

    static func set(_ data: Data, on message: xpc_object_t) {
        set(data, key: key, on: message)
    }

    /// Sibling of `rv.ipc`. Present (including empty) means use these bytes as
    /// `hookEvaluate` stdin instead of the JSON `stdin` field.
    static let stdinKey = "rv.stdin"

    static func stdin(from message: xpc_object_t) -> Data? {
        var length = 0
        guard let bytes = xpc_dictionary_get_data(message, stdinKey, &length) else {
            return nil
        }
        return Data(bytes: bytes, count: length)
    }

    static func setStdin(_ data: Data, on message: xpc_object_t) {
        set(data, key: stdinKey, on: message)
    }

    private static func set(_ data: Data, key: String, on message: xpc_object_t) {
        data.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress {
                xpc_dictionary_set_data(message, key, base, buffer.count)
            } else {
                xpc_dictionary_set_data(message, key, "", 0)
            }
        }
    }
}

/// Raw libxpc listener on `dev.rv.evaluate`. C and Swift share `rv.ipc` xpc_data.
public final class XPCEvaluateListener: Sendable {
    private let runtime: ServiceRuntime
    private let watchdog: IdleWatchdog
    private let serviceName: String
    private let listener = Mutex<xpc_connection_t?>(nil)
    private let actionListener = Mutex<xpc_connection_t?>(nil)
    private let hostRegistry = LiveWorkspaceHostRegistry()

    public init(
        runtime: ServiceRuntime,
        watchdog: IdleWatchdog,
        machServiceName: String = RVService.machServiceName
    ) {
        self.runtime = runtime
        self.watchdog = watchdog
        self.serviceName = machServiceName
    }

    public func start() {
        // Anonymous endpoint connections cannot rediscover a replacement daemon.
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
            self?.handleListenerEvent(event)
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
        if let existing {
            xpc_connection_cancel(existing)
        }
    }

    private func handleListenerEvent(_ event: xpc_object_t) {
        let type = xpc_get_type(event)
        if type == XPC_TYPE_ERROR {
            return
        }
        if type == XPC_TYPE_CONNECTION {
            accept(event, discoveryOnly: true)
        }
    }

    private func accept(_ peer: xpc_connection_t, discoveryOnly: Bool) {
        let endpoint = discoveryOnly ? actionListener.withLock { listener in
            listener.map { XPCHeld(xpc_endpoint_create($0)) }
        } : nil
        let session = XPCPeerSession(runtime: runtime, watchdog: watchdog,
            discoveryOnly: discoveryOnly, actionEndpoint: endpoint, hostRegistry: hostRegistry)
        xpc_connection_set_event_handler(peer) { event in
            session.handle(event)
        }
        xpc_connection_resume(peer)
    }
}

final class XPCPeerSession: Sendable {
    private let runtime: ServiceRuntime
    private let watchdog: IdleWatchdog
    private let handshake = Mutex(false)
    private let discoveryOnly: Bool
    private let actionEndpoint: XPCHeld?
    private let connectionID = UUID()
    private let hostRegistry: LiveWorkspaceHostRegistry
    private let hostLiveness = HostBridgeLiveness()
    private let beginTransaction: @Sendable () -> Void
    private let endTransaction: @Sendable () -> Void

    init(
        runtime: ServiceRuntime,
        watchdog: IdleWatchdog,
        discoveryOnly: Bool = false,
        actionEndpoint: XPCHeld? = nil,
        hostRegistry: LiveWorkspaceHostRegistry = LiveWorkspaceHostRegistry(),
        beginTransaction: @escaping @Sendable () -> Void = { xpc_transaction_begin() },
        endTransaction: @escaping @Sendable () -> Void = { xpc_transaction_end() }
    ) {
        self.runtime = runtime
        self.watchdog = watchdog
        self.discoveryOnly = discoveryOnly
        self.actionEndpoint = actionEndpoint
        self.hostRegistry = hostRegistry
        self.beginTransaction = beginTransaction
        self.endTransaction = endTransaction
    }

    @discardableResult
    func handle(_ event: xpc_object_t) -> Task<Void, Never>? {
        let type = xpc_get_type(event)
        if type == XPC_TYPE_ERROR {
            hostLiveness.disconnect()
            let registry = hostRegistry
            let id = connectionID
            return Task { await registry.disconnect(connectionID: id) }
        }
        guard type == XPC_TYPE_DICTIONARY else {
            return nil
        }
        // The message's audit-token-backed SecCode is captured synchronously.
        // A payload PID, host label or later connection lookup cannot replace it.
        let trust = (try? ProtectedPeerTrustConfiguration.installed()) ?? .denyAll
        let context: AuthenticatedRequestContext
        if let peer = try? MacOSPeerAuthenticator.capture(
            message: event, connectionID: connectionID, trust: trust
        ) {
            context = .captured(peer: peer, connectionID: connectionID)
        } else {
            context = .unauthenticated
        }
        beginTransaction()
        let held = XPCHeld(event)
        return Task {
            defer { self.endTransaction() }
            await self.watchdog.ping()
            let message = held.object
            let incoming = XPCIPCWire.body(from: message)
            let stdinOverlay = XPCIPCWire.stdin(from: message)
            let accepted = self.handshake.withLock { $0 }
            if XPCWorkspaceHostBridge.handles(message) {
                await XPCWorkspaceHostBridge.handle(message: held, context: context,
                    handshakeOK: accepted, discoveryOnly: self.discoveryOnly,
                    liveness: self.hostLiveness, registry: self.hostRegistry, runtime: self.runtime)
                return
            }
            let incomingReply: IncomingReply
            let isHello = incoming.flatMap { try? IPCJSON.decode(Hello.self, from: $0) } != nil
            if self.discoveryOnly && !isHello {
                let request = incoming.flatMap { try? IPCJSON.decode(IPCRequest.self, from: $0) }
                let response = IPCResponse(id: request?.id ?? UUID(), result: .error(.authorizationDenied))
                incomingReply = IncomingReply(frame: (try? IPCJSON.encode(response)) ?? Data(), handshakeAccepted: false)
            } else if let incoming {
                incomingReply = await self.runtime.handleIncoming(
                    incoming,
                    handshakeOK: accepted,
                    stdinOverlay: stdinOverlay,
                    context: context
                )
            } else {
                let response = IPCResponse(id: UUID(), result: .error(.decodeFailed))
                incomingReply = IncomingReply(
                    frame: (try? IPCJSON.encode(response)) ?? Data(),
                    handshakeAccepted: accepted
                )
            }
            self.handshake.withLock { $0 = incomingReply.handshakeAccepted }
            guard let reply = xpc_dictionary_create_reply(message) else {
                return
            }
            XPCIPCWire.set(incomingReply.frame, on: reply)
            if isHello && incomingReply.handshakeAccepted, let endpoint = self.actionEndpoint {
                xpc_dictionary_set_value(reply, XPCIPCWire.actionEndpointKey, endpoint.object)
            }
            if let peer = xpc_dictionary_get_remote_connection(message) {
                xpc_connection_send_message(peer, reply)
            }
        }
    }
}

// Immutable after init. libxpc objects are safe to use from multiple
// threads; the handle itself is never mutated, only passed to xpc calls.
final class XPCHeld: @unchecked Sendable {
    let object: xpc_object_t

    init(_ object: xpc_object_t) {
        self.object = object
    }
}
#endif
