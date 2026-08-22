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
    private let serviceName: String
    private let lock = NSLock()
    private var listener: xpc_connection_t?

    public init(runtime: ServiceRuntime, machServiceName: String = RVService.machServiceName) {
        self.runtime = runtime
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
        let session = XPCPeerSession(runtime: runtime)
        xpc_connection_set_event_handler(peer) { event in
            session.handle(event)
        }
        xpc_connection_resume(peer)
    }
}

final class XPCPeerSession: @unchecked Sendable {
    private let runtime: ServiceRuntime
    private let lock = NSLock()
    private var handshakeOK = false

    init(runtime: ServiceRuntime) {
        self.runtime = runtime
    }

    func handle(_ event: xpc_object_t) {
        let type = xpc_get_type(event)
        if type == XPC_TYPE_ERROR {
            return
        }
        guard type == XPC_TYPE_DICTIONARY else {
            return
        }
        let held = XPCHeld(event)
        Task {
            let message = held.object
            let incoming = XPCIPCWire.body(from: message)
            let accepted = self.lock.withLock { self.handshakeOK }
            let (data, ok): (Data, Bool)
            if let incoming {
                (data, ok) = await self.runtime.handleIncoming(incoming, handshakeOK: accepted)
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
