#if os(macOS)
import Darwin
import Foundation
import RVIsolation
import Security
import Synchronization
import Testing
@preconcurrency import XPC
@testable import RVService

/// Uses kernel-delivered anonymous-endpoint traffic, without an installed Mach
/// service or a trust manifest. Both endpoints are deliberately this process:
/// this proves the message evidence API, not distinct-process role assignment.
@Test func anonymousXPCMessagesAndRepliesCarryLiveCodeEvidence() throws {
    let requestID = UUID()
    let replyID = UUID()
    let received = Mutex<Result<AuthenticatedPeer, any Error>?>(nil)
    let replied = Mutex<Result<AuthenticatedPeer, any Error>?>(nil)
    let crossedTask = Mutex<AuthenticatedRequestContext?>(nil)
    let connections = Mutex<[XPCHeld]>([])
    let replyDone = DispatchSemaphore(value: 0)
    let taskDone = DispatchSemaphore(value: 0)
    let listener = xpc_connection_create(nil, nil)
    xpc_connection_set_event_handler(listener) { event in
        guard xpc_get_type(event) == XPC_TYPE_CONNECTION else { return }
        let held = XPCHeld(event)
        connections.withLock { $0.append(held) }
        xpc_connection_set_event_handler(held.object) { message in
            guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else { return }
            // Authentication is synchronous on the received message. Only the
            // immutable context crosses the Task boundary.
            let captured = Result {
                try MacOSPeerAuthenticator.capture(message: message,
                    connectionID: requestID, trust: .denyAll)
            }
            received.withLock { $0 = captured }
            if case .success(let peer) = captured {
                let context = AuthenticatedRequestContext.captured(peer: peer, connectionID: requestID)
                Task {
                    crossedTask.withLock { $0 = context }
                    taskDone.signal()
                }
            } else {
                taskDone.signal()
            }
            guard let reply = xpc_dictionary_create_reply(message) else {
                replyDone.signal()
                return
            }
            xpc_dictionary_set_bool(reply, "received", true)
            xpc_connection_send_message(held.object, reply)
        }
        xpc_connection_resume(held.object)
    }
    xpc_connection_resume(listener)
    let endpoint = xpc_endpoint_create(listener)
    let client = xpc_connection_create_from_endpoint(endpoint)
    xpc_connection_set_event_handler(client) { _ in }
    xpc_connection_resume(client)
    defer {
        xpc_connection_cancel(client)
        connections.withLock { peers in
            for peer in peers { xpc_connection_cancel(peer.object) }
        }
        xpc_connection_cancel(listener)
    }
    let message = xpc_dictionary_create_empty()
    // Payload identity claims cannot turn this peer into a trusted component.
    xpc_dictionary_set_string(message, "role", "service")
    xpc_dictionary_set_int64(message, "pid", 1)
    xpc_connection_send_message_with_reply(client, message, nil) { reply in
        replied.withLock {
            $0 = Result {
                try MacOSPeerAuthenticator.capture(message: reply,
                    connectionID: replyID, trust: .denyAll)
            }
        }
        replyDone.signal()
    }
    try #require(replyDone.wait(timeout: .now() + 10) == .success,
        "Real XPC endpoint reply timed out")
    try #require(taskDone.wait(timeout: .now() + 10) == .success,
        "Captured XPC context did not cross the Task boundary")
    let serverPeer = try #require(received.withLock { $0 }).get()
    let clientPeer = try #require(replied.withLock { $0 }).get()
    let context = try #require(crossedTask.withLock { $0 })

    var selfCode: SecCode?
    try #require(SecCodeCopySelf([], &selfCode) == errSecSuccess)
    let expected = try MacOSPeerCodeVerifier.capture(code: #require(selfCode),
        processID: getpid(), effectiveUserID: geteuid(), trust: .denyAll)
    for peer in [serverPeer, clientPeer] {
        #expect(peer.evidence.processID == getpid())
        #expect(peer.evidence.effectiveUserID == geteuid())
        #expect(peer.evidence.codeIdentity == expected.codeIdentity)
        #expect(!peer.evidence.codeIdentity.cdHash.isEmpty)
        #expect(peer.componentRole == nil)
    }
    #expect(serverPeer.connectionID == requestID)
    #expect(clientPeer.connectionID == replyID)
    #expect(context.connectionID == requestID)
    #expect(context.peer == serverPeer)
    #expect(context.componentRole == nil)
    #expect(context.agent == nil)
}
#endif
