#if canImport(XPC)
import Darwin
import Foundation
import Synchronization
import RVIsolation
@preconcurrency import XPC

/// Synchronous XPC client for the approvals custodian, mirroring
/// `XPCEvaluateClient`'s two-hop shape: hello on the Mach-service
/// discovery connection, hello again on the anonymous action endpoint,
/// then one request. Every reply's sender is verified before any field
/// is consumed — a Mach service name is not server identity.
///
/// Approval callers are synchronous (CLI paths and the gateway's serial
/// queue; never the main actor), so each exchange is an XPC async reply
/// bounded by a semaphore wait. Hellos and status get a short bound;
/// mac/verify may wait on a Touch ID prompt in the custodian, so they
/// get the long one. Any failure — unreachable, unverifiable, timed
/// out, malformed — returns nil and the signing seam fails closed.
public final class MCPCustodianXPCClient: Sendable {
    public static let defaultHelloTimeout: TimeInterval = 5
    public static let defaultRequestTimeout: TimeInterval = 120

    private let serviceName: String
    private let custodianExecutablePath: String
    private let helloTimeout: TimeInterval
    private let requestTimeout: TimeInterval

    public init(
        serviceName: String = MCPCustodianWire.machServiceName,
        custodianExecutablePath: String,
        helloTimeout: TimeInterval = MCPCustodianXPCClient.defaultHelloTimeout,
        requestTimeout: TimeInterval = MCPCustodianXPCClient.defaultRequestTimeout
    ) {
        self.serviceName = serviceName
        self.custodianExecutablePath = custodianExecutablePath
        self.helloTimeout = helloTimeout
        self.requestTimeout = requestTimeout
    }

    /// Where `rv setup` installs the custodian bundle for this user.
    public static func custodianExecutablePath(home: String) -> String {
        (home as NSString).appendingPathComponent(
            "Applications/RVApprovals.app/Contents/MacOS/rv-mcp-custodian")
    }

    public static func live(home: String) -> MCPCustodianXPCClient {
        MCPCustodianXPCClient(custodianExecutablePath: custodianExecutablePath(home: home))
    }

    public static func liveTransport(home: String) -> MCPCustodianTransport {
        live(home: home).transport
    }

    public var transport: MCPCustodianTransport {
        { self.send($0) }
    }

    /// The bound for one request's action exchange. Status never prompts;
    /// mac/verify can sit behind user presence in the custodian.
    public static func timeout(
        for request: MCPCustodianRequest, hello helloTimeout: TimeInterval, request requestTimeout: TimeInterval
    ) -> TimeInterval {
        switch request {
        case .status: helloTimeout
        case .mac, .verify: requestTimeout
        }
    }

    public func send(_ request: MCPCustodianRequest) -> MCPCustodianResponse? {
        guard let hello = try? JSONEncoder().encode(MCPCustodianHello()),
            let body = try? JSONEncoder().encode(request)
        else { return nil }

        let discovery = xpc_connection_create_mach_service(serviceName, nil, 0)
        let heldDiscovery = CustodianXPCHeld(discovery)
        xpc_connection_set_event_handler(discovery) { event in
            if xpc_get_type(event) == XPC_TYPE_ERROR {
                xpc_connection_cancel(heldDiscovery.object)
            }
        }
        xpc_connection_resume(discovery)
        defer { xpc_connection_cancel(discovery) }

        // This reply is authenticated before its endpoint field is inspected.
        guard let discoveryReply = exchange(hello, on: discovery, timeout: helloTimeout),
            verifyCustodian(reply: discoveryReply.object),
            let ackData = CustodianXPCWire.body(from: discoveryReply.object),
            let ack = try? JSONDecoder().decode(MCPCustodianHelloAck.self, from: ackData),
            ack.ok, ack.protocolVersion == MCPCustodianWire.protocolVersion,
            let endpoint = xpc_dictionary_get_value(discoveryReply.object, MCPCustodianWire.xpcEndpointKey),
            xpc_get_type(endpoint) == XPC_TYPE_ENDPOINT
        else { return nil }

        let actions = xpc_connection_create_from_endpoint(endpoint)
        let heldActions = CustodianXPCHeld(actions)
        xpc_connection_set_event_handler(actions) { event in
            if xpc_get_type(event) == XPC_TYPE_ERROR {
                xpc_connection_cancel(heldActions.object)
            }
        }
        xpc_connection_resume(actions)
        defer { xpc_connection_cancel(actions) }

        // Authenticate this exact non-rediscoverable peer before sending it a request.
        guard let actionHello = exchange(hello, on: actions, timeout: helloTimeout),
            verifyCustodian(reply: actionHello.object),
            let actionAckData = CustodianXPCWire.body(from: actionHello.object),
            let actionAck = try? JSONDecoder().decode(MCPCustodianHelloAck.self, from: actionAckData),
            actionAck.ok
        else { return nil }

        let actionTimeout = Self.timeout(for: request, hello: helloTimeout, request: requestTimeout)
        guard let reply = exchange(body, on: actions, timeout: actionTimeout),
            verifyCustodian(reply: reply.object),
            let data = CustodianXPCWire.body(from: reply.object),
            let response = try? JSONDecoder().decode(MCPCustodianResponse.self, from: data)
        else { return nil }
        return response
    }

    /// Verifies the sender of one reply before any field is consumed.
    /// An installed trust manifest requires the `.mcpCustodian` role.
    /// With no manifest (one-click install), the peer must be the exact
    /// bundled binary: same euid, hardened runtime, canonical path and
    /// CDHash equal to the on-disk custodian. A manifest that exists but
    /// fails validation is tamper evidence: fail closed, never fall back.
    private func verifyCustodian(reply: xpc_object_t) -> Bool {
        switch ProtectedPeerTrustConfiguration.hookTrustSource() {
        case .manifest(let trust):
            guard let peer = try? MacOSPeerAuthenticator.capture(
                message: reply, connectionID: UUID(), trust: trust
            ), peer.componentRole == .mcpCustodian
            else { return false }
            return true
        case .siblingPin:
            guard let peer = try? MacOSPeerAuthenticator.capture(
                message: reply, connectionID: UUID(), trust: .denyAll
            ), peer.evidence.effectiveUserID == geteuid(),
                peer.evidence.codeIdentity.hardenedRuntime
            else { return false }
            return MacOSPeerCodeVerifier.matches(
                peer: peer.evidence.codeIdentity, path: custodianExecutablePath)
        case .invalid:
            return false
        }
    }

    /// One bounded request/reply. Nil on error, wrong type, or timeout
    /// (the connection is cancelled so a late reply goes nowhere).
    private func exchange(
        _ body: Data, on connection: xpc_connection_t, timeout: TimeInterval
    ) -> CustodianXPCHeld? {
        let semaphore = DispatchSemaphore(value: 0)
        let slot = Mutex<CustodianXPCHeld?>(nil)
        let held = CustodianXPCHeld(connection)
        let message = xpc_dictionary_create_empty()
        CustodianXPCWire.set(body, on: message)
        xpc_connection_send_message_with_reply(connection, message, nil) { reply in
            if xpc_get_type(reply) != XPC_TYPE_ERROR {
                slot.withLock { $0 = CustodianXPCHeld(reply) }
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            xpc_connection_cancel(held.object)
            return nil
        }
        return slot.withLock { $0 }
    }
}

/// Dictionary access for custodian hello/request/response JSON, shared
/// by the client here and the custodian's listener.
public enum CustodianXPCWire {
    public static func body(from message: xpc_object_t) -> Data? {
        var length = 0
        guard let bytes = xpc_dictionary_get_data(message, MCPCustodianWire.xpcDataKey, &length) else {
            return nil
        }
        return Data(bytes: bytes, count: length)
    }

    public static func set(_ data: Data, on message: xpc_object_t) {
        data.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress {
                xpc_dictionary_set_data(message, MCPCustodianWire.xpcDataKey, base, buffer.count)
            } else {
                xpc_dictionary_set_data(message, MCPCustodianWire.xpcDataKey, "", 0)
            }
        }
    }
}

// Immutable after init. libxpc objects are safe to use from multiple
// threads; the handle itself is never mutated, only passed to xpc calls.
final class CustodianXPCHeld: @unchecked Sendable {
    let object: xpc_object_t

    init(_ object: xpc_object_t) {
        self.object = object
    }
}
#endif
