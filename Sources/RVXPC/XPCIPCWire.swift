#if canImport(XPC)
import Foundation
@preconcurrency import XPC

/// Dictionary key for UTF-8 `IPCRequest` / `IPCResponse` / Hello JSON (`IPCJSON`).
package enum XPCIPCWire {
    package static let key = "rv.ipc"
    package static let actionEndpointKey = "rv.action-endpoint"

    package static func body(from message: xpc_object_t) -> Data? {
        var length = 0
        guard let bytes = xpc_dictionary_get_data(message, key, &length) else {
            return nil
        }
        return Data(bytes: bytes, count: length)
    }

    package static func set(_ data: Data, on message: xpc_object_t) {
        set(data, key: key, on: message)
    }

    /// Sibling of `rv.ipc`. Present (including empty) means use these bytes as
    /// `hookEvaluate` stdin instead of the JSON `stdin` field.
    package static let stdinKey = "rv.stdin"

    package static func stdin(from message: xpc_object_t) -> Data? {
        var length = 0
        guard let bytes = xpc_dictionary_get_data(message, stdinKey, &length) else {
            return nil
        }
        return Data(bytes: bytes, count: length)
    }

    package static func setStdin(_ data: Data, on message: xpc_object_t) {
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
#endif
