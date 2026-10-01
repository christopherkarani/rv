#if canImport(XPC)
import Foundation
import Synchronization
import RVIsolation
import RVIPC
@preconcurrency import XPC

/// RVOperatorUI side of the operator-UI channel. Unlike `XPCEvaluateClient`
/// (one action connection per call), this client holds ONE persistent action
/// connection: the server binds Step 3 challenges to the registered UI
/// session, so list/bind/complete must all ride the same connection. A
/// dropped connection invalidates the session server-side; the caller
/// reconnects and re-binds (fail-closed: nothing completes across it).
public final class XPCOperatorUIClient: Sendable {
    public let serviceName: String
    private let state: Mutex<ClientState>

    /// Never cancel/resume a connection while holding the state lock.
    private struct ClientState {
        var discovery: xpc_connection_t?
        var actions: xpc_connection_t?
    }

    public init(serviceName: String = RVService.machServiceName) {
        self.serviceName = serviceName
        self.state = Mutex(ClientState())
    }

    public func invalidate() {
        let (discovery, actions) = state.withLock { state -> (xpc_connection_t?, xpc_connection_t?) in
            let pair = (state.discovery, state.actions)
            state.discovery = nil
            state.actions = nil
            return pair
        }
        if let discovery { xpc_connection_cancel(discovery) }
        if let actions { xpc_connection_cancel(actions) }
    }

    /// Establishes the session: discovery Hello, action Hello, register.
    /// Idempotent while the action connection is alive.
    public func connect() async throws {
        // liveActions ends with registration; idempotent while alive.
        _ = try await liveActions()
    }

    public func list() async throws -> UIReviewListDTO {
        let response = try await roundTrip(.list)
        guard case .uiReviewList(let list) = response.result else {
            throw mapUnexpected(response.result)
        }
        return list
    }

    public func bind(operationID: UUID) async throws -> UIChallengeBundleDTO {
        let response = try await roundTrip(.bind(operationID: operationID))
        guard case .uiChallengeBundle(let bundle) = response.result else {
            throw mapUnexpected(response.result)
        }
        return bundle
    }

    public func complete(_ completion: UIOperatorCompletion) async throws -> UIOperationStatusDTO {
        let response = try await roundTrip(.complete(completion))
        guard case .uiOperationStatus(let status) = response.result else {
            throw mapUnexpected(response.result)
        }
        return status
    }

    public func cancel(operationID: UUID) async throws -> UIOperationStatusDTO {
        let response = try await roundTrip(.cancel(operationID: operationID))
        guard case .uiOperationStatus(let status) = response.result else {
            throw mapUnexpected(response.result)
        }
        return status
    }

    public func status(operationID: UUID) async throws -> UIOperationStatusDTO {
        let response = try await roundTrip(.status(operationID: operationID))
        guard case .uiOperationStatus(let status) = response.result else {
            throw mapUnexpected(response.result)
        }
        return status
    }

    private func register() async throws -> UIRegisteredDTO {
        let response = try await roundTrip(.register)
        guard case .uiRegistered(let receipt) = response.result else {
            throw mapUnexpected(response.result)
        }
        return receipt
    }

    private func mapUnexpected(_ result: IPCResult) -> XPCOperatorUIClientError {
        if case .error(let error) = result, error == .authorizationDenied {
            return .denied
        }
        return .protocolMismatch
    }

    private func roundTrip(_ request: UIBridgeRequest) async throws -> IPCResponse {
        if Task.isCancelled {
            throw XPCOperatorUIClientError.cancelled
        }
        let actions = try await liveActions()
        let body = try IPCJSON.encode(request)
        do {
            let frame = try await exchange(body, on: actions)
            return try IPCJSON.decode(IPCResponse.self, from: frame)
        } catch let error as XPCOperatorUIClientError {
            // Transport failure. Decoded denials surface from the callers
            // (mapUnexpected), outside this catch: a live server answering
            // denial keeps the session.
            forgetActions()
            throw error
        } catch {
            // Undecodable frame from an authenticated peer: drop the
            // connection, report a protocol violation.
            forgetActions()
            throw XPCOperatorUIClientError.protocolMismatch
        }
    }

    private func liveActions() async throws -> xpc_connection_t {
        if let existing = state.withLock({ $0.actions }) {
            return existing
        }
        let discovery = try liveDiscovery()
        let hello = try IPCJSON.encode(Hello())
        // This reply is authenticated before its endpoint field is inspected.
        let discoveryReply = try await exchangeHello(hello, on: discovery, requireEndpoint: true)
        let discoveryAck = try IPCJSON.decode(HelloAck.self, from: discoveryReply.body)
        guard discoveryAck.status == .ok, let endpoint = discoveryReply.endpoint else {
            invalidate()
            throw XPCOperatorUIClientError.authenticationFailed
        }
        let actions = xpc_connection_create_from_endpoint(endpoint.object)
        let heldActions = XPCHeld(actions)
        xpc_connection_set_event_handler(actions) { [weak self] event in
            if xpc_get_type(event) == XPC_TYPE_ERROR {
                xpc_connection_cancel(heldActions.object)
                self?.forgetActions()
            }
        }
        xpc_connection_resume(actions)
        // Authenticate this exact non-rediscoverable peer before sending action bytes.
        let actionReply = try await exchangeHello(hello, on: actions)
        let actionAck = try IPCJSON.decode(HelloAck.self, from: actionReply.body)
        guard actionAck.status == .ok else {
            xpc_connection_cancel(actions)
            throw XPCOperatorUIClientError.authenticationFailed
        }
        let winner = state.withLock { state -> xpc_connection_t in
            if let existing = state.actions {
                return existing
            }
            state.actions = actions
            return actions
        }
        if winner !== actions {
            xpc_connection_cancel(actions)
            return winner
        }
        do {
            _ = try await register()
        } catch {
            forgetActions()
            throw error
        }
        return actions
    }

    private func liveDiscovery() throws -> xpc_connection_t {
        if let existing = state.withLock({ $0.discovery }) {
            return existing
        }
        let created = xpc_connection_create_mach_service(serviceName, nil, 0)
        let heldCreated = XPCHeld(created)
        xpc_connection_set_event_handler(created) { [weak self] event in
            if xpc_get_type(event) == XPC_TYPE_ERROR {
                self?.forget(heldCreated.object)
            }
        }
        let winner = state.withLock { state -> xpc_connection_t in
            if let existing = state.discovery {
                return existing
            }
            state.discovery = created
            return created
        }
        if winner !== created {
            xpc_connection_cancel(created)
            return winner
        }
        xpc_connection_resume(created)
        return created
    }

    private func forget(_ candidate: xpc_connection_t) {
        xpc_connection_cancel(candidate)
        state.withLock {
            if $0.discovery === candidate {
                $0.discovery = nil
            }
        }
    }

    private func forgetActions() {
        let existing = state.withLock { state -> xpc_connection_t? in
            let current = state.actions
            state.actions = nil
            return current
        }
        if let existing {
            xpc_connection_cancel(existing)
        }
    }

    private struct VerifiedExchange: Sendable {
        let body: Data
        let endpoint: XPCHeld?
    }

    /// UI request round trip. The request rides `rv.ui-request`; the reply is
    /// an `IPCResponse` frame on the shared wire key.
    private func exchange(_ body: Data, on connection: xpc_connection_t) async throws -> Data {
        try await exchangeRaw(body: body, key: UIBridgeWire.requestKey, on: connection).body
    }

    private func exchangeHello(
        _ body: Data, on connection: xpc_connection_t, requireEndpoint: Bool = false
    ) async throws -> VerifiedExchange {
        try await exchangeRaw(body: body, key: nil, on: connection, requireEndpoint: requireEndpoint)
    }

    private func exchangeRaw(
        body: Data, key: String?, on connection: xpc_connection_t, requireEndpoint: Bool = false
    ) async throws -> VerifiedExchange {
        let once = OnceResume<VerifiedExchange>()
        let held = XPCHeld(connection)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if once.install(continuation) {
                    return
                }
                if Task.isCancelled {
                    once.resume(throwing: XPCOperatorUIClientError.cancelled)
                    return
                }
                let message = xpc_dictionary_create_empty()
                if let key {
                    body.withUnsafeBytes { buffer in
                        xpc_dictionary_set_data(message, key, buffer.baseAddress, buffer.count)
                    }
                } else {
                    XPCIPCWire.set(body, on: message)
                }
                xpc_connection_send_message_with_reply(held.object, message, nil) { reply in
                    let type = xpc_get_type(reply)
                    if type == XPC_TYPE_ERROR {
                        xpc_connection_cancel(held.object)
                        once.resume(throwing: XPCOperatorUIClientError.connectFailed)
                        return
                    }
                    // A Mach service name is not server identity. Do not consume
                    // authority-bearing results from an unverified daemon.
                    guard let trust = try? ProtectedPeerTrustConfiguration.installed(),
                        let peer = try? MacOSPeerAuthenticator.capture(
                            message: reply, connectionID: UUID(), trust: trust
                        ), peer.componentRole == .service
                    else {
                        xpc_connection_cancel(held.object)
                        once.resume(throwing: XPCOperatorUIClientError.authenticationFailed)
                        self.invalidate()
                        return
                    }
                    guard let data = XPCIPCWire.body(from: reply) else {
                        once.resume(throwing: XPCOperatorUIClientError.connectFailed)
                        return
                    }
                    let endpoint: XPCHeld?
                    if requireEndpoint {
                        guard let object = xpc_dictionary_get_value(reply, XPCIPCWire.actionEndpointKey),
                            xpc_get_type(object) == XPC_TYPE_ENDPOINT else {
                            xpc_connection_cancel(held.object)
                            once.resume(throwing: XPCOperatorUIClientError.authenticationFailed)
                            return
                        }
                        endpoint = XPCHeld(object)
                    } else {
                        endpoint = nil
                    }
                    once.resume(returning: VerifiedExchange(body: data, endpoint: endpoint))
                }
            }
        } onCancel: {
            xpc_connection_cancel(held.object)
            once.resume(throwing: XPCOperatorUIClientError.cancelled)
            self.invalidate()
        }
    }
}

public enum XPCOperatorUIClientError: Error, Sendable, Equatable {
    case authenticationFailed
    case connectFailed
    case denied
    case protocolMismatch
    case cancelled
}
#endif
