#if canImport(XPC)
import Dispatch
import Foundation
import Synchronization
import Testing
@preconcurrency import XPC
@testable import RVService

/// Real libxpc endpoint lifetime proof, separate from code-identity authentication.
struct XPCEndpointLifetimeTests {
    @Test func cancelledEndpointCannotRediscoverReplacementListener() throws {
        let firstReceived = DispatchSemaphore(value: 0)
        let invalidated = DispatchSemaphore(value: 0)
        let peers = Mutex<[XPCHeld]>([])
        let first = xpc_connection_create(nil, nil)
        xpc_connection_set_event_handler(first) { event in
            guard xpc_get_type(event) == XPC_TYPE_CONNECTION else { return }
            peers.withLock { $0.append(XPCHeld(event)) }
            xpc_connection_set_event_handler(event) { message in
                guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else { return }
                firstReceived.signal()
            }
            xpc_connection_resume(event)
        }
        xpc_connection_resume(first)
        let oldEndpoint = xpc_endpoint_create(first)
        let client = xpc_connection_create_from_endpoint(oldEndpoint)
        xpc_connection_set_event_handler(client) { event in
            if xpc_get_type(event) == XPC_TYPE_ERROR { invalidated.signal() }
        }
        xpc_connection_resume(client)
        defer {
            xpc_connection_cancel(client)
            xpc_connection_cancel(first)
            peers.withLock { $0.forEach { xpc_connection_cancel($0.object) } }
        }
        xpc_connection_send_message(client, xpc_dictionary_create_empty())
        #expect(firstReceived.wait(timeout: .now() + 3) == .success)

        // A replacement listener offers a different endpoint. The old channel
        // can never perform a named-service lookup to reach this new listener.
        let replacementReceived = DispatchSemaphore(value: 0)
        let replacement = xpc_connection_create(nil, nil)
        xpc_connection_set_event_handler(replacement) { event in
            guard xpc_get_type(event) == XPC_TYPE_CONNECTION else { return }
            peers.withLock { $0.append(XPCHeld(event)) }
            xpc_connection_set_event_handler(event) { message in
                if xpc_get_type(message) == XPC_TYPE_DICTIONARY { replacementReceived.signal() }
            }
            xpc_connection_resume(event)
        }
        xpc_connection_resume(replacement)
        defer { xpc_connection_cancel(replacement) }
        xpc_connection_cancel(first)
        #expect(invalidated.wait(timeout: .now() + 3) == .success)
        xpc_connection_send_message(client, xpc_dictionary_create_empty())
        #expect(replacementReceived.wait(timeout: .now() + 0.1) == .timedOut)
    }
}
#endif
