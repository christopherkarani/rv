#if canImport(XPC)
import Foundation
import RVIPC
@preconcurrency import XPC

/// Dictionary key for UTF-8 `IPCRequest` / `IPCResponse` / Hello JSON (`IPCJSON`).
enum XPCIPCWire {
    static let key = "rv.ipc"

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
public final class XPCEvaluateListener: @unchecked Sendable {
    private let runtime: ServiceRuntime
    private let watchdog: IdleWatchdog
    private let serviceName: String
    private let lock = NSLock()
    private var listener: xpc_connection_t?

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
        let connection = xpc_connection_create_mach_service(
            serviceName,
            nil,
            UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER)
        )
        xpc_connection_set_event_handler(connection) { [weak self] event in
            self?.handleListenerEvent(event)
        }
        lock.withLock { listener = connection }
        xpc_connection_resume(connection)
    }

    public func stop() {
        let existing = lock.withLock { () -> xpc_connection_t? in
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
            accept(event)
        }
    }

    private func accept(_ peer: xpc_connection_t) {
        let session = XPCPeerSession(runtime: runtime, watchdog: watchdog)
        xpc_connection_set_event_handler(peer) { event in
            session.handle(event)
        }
        xpc_connection_resume(peer)
    }
}

final class XPCPeerSession: @unchecked Sendable {
    private let runtime: ServiceRuntime
    private let watchdog: IdleWatchdog
    private let lock = NSLock()
    private var handshakeOK = false
    private let beginTransaction: @Sendable () -> Void
    private let endTransaction: @Sendable () -> Void

    init(
        runtime: ServiceRuntime,
        watchdog: IdleWatchdog,
        beginTransaction: @escaping @Sendable () -> Void = { xpc_transaction_begin() },
        endTransaction: @escaping @Sendable () -> Void = { xpc_transaction_end() }
    ) {
        self.runtime = runtime
        self.watchdog = watchdog
        self.beginTransaction = beginTransaction
        self.endTransaction = endTransaction
    }

    @discardableResult
    func handle(_ event: xpc_object_t) -> Task<Void, Never>? {
        let type = xpc_get_type(event)
        if type == XPC_TYPE_ERROR {
            return nil
        }
        guard type == XPC_TYPE_DICTIONARY else {
            return nil
        }
        beginTransaction()
        let held = XPCHeld(event)
        return Task {
            defer { self.endTransaction() }
            await self.watchdog.ping()
            let message = held.object
            let incoming = XPCIPCWire.body(from: message)
            let stdinOverlay = XPCIPCWire.stdin(from: message)
            let accepted = self.lock.withLock { self.handshakeOK }
            let (data, ok): (Data, Bool)
            if let incoming {
                (data, ok) = await self.runtime.handleIncoming(
                    incoming,
                    handshakeOK: accepted,
                    stdinOverlay: stdinOverlay
                )
            } else {
                let response = IPCResponse(id: UUID(), result: .error(.decodeFailed))
                data = (try? IPCJSON.encode(response)) ?? Data()
                ok = accepted
            }
            self.lock.withLock { self.handshakeOK = ok }
            guard let reply = xpc_dictionary_create_reply(message) else {
                return
            }
            XPCIPCWire.set(data, on: reply)
            if let peer = xpc_dictionary_get_remote_connection(message) {
                xpc_connection_send_message(peer, reply)
            }
        }
    }
}

final class XPCHeld: @unchecked Sendable {
    let object: xpc_object_t

    init(_ object: xpc_object_t) {
        self.object = object
    }
}
#endif

