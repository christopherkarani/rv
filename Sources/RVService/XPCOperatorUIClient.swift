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
        /// In-flight first-connect. Concurrent callers join it instead of
        /// building a second connection, so nobody ever observes (or sends
        /// on) a session the server has not registered yet.
        var connecting: Task<xpc_connection_t, Error>?
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

    // MARK: - Action approvals (Step 6)

    /// Action-review calls ride the same persistent action connection (and
    /// the same registered UI session) as launch review, on the action
    /// request key with the action vocabulary. A dropped connection
    /// invalidates bound action challenges server-side, mirroring launch:
    /// the caller reconnects and re-binds; nothing completes across it.
    public func actionList() async throws -> UIActionReviewListDTO {
        let response = try await actionRoundTrip(.actionList)
        guard case .uiActionReviewList(let list) = response.result else {
            throw mapUnexpected(response.result)
        }
        return list
    }

    public func actionBind(approvalID: UUID) async throws -> UIActionChallengeBundleDTO {
        let response = try await actionRoundTrip(.actionBind(approvalID: approvalID))
        guard case .uiActionChallengeBundle(let bundle) = response.result else {
            throw mapUnexpected(response.result)
        }
        return bundle
    }

    public func actionComplete(_ completion: UIActionCompletion) async throws -> UIActionStatusDTO {
        let response = try await actionRoundTrip(.actionComplete(completion))
        guard case .uiActionStatus(let status) = response.result else {
            throw mapUnexpected(response.result)
        }
        return status
    }

    public func actionDeny(_ deny: UIActionDeny) async throws -> UIActionStatusDTO {
        let response = try await actionRoundTrip(.actionDeny(deny))
        guard case .uiActionStatus(let status) = response.result else {
            throw mapUnexpected(response.result)
        }
        return status
    }

    public func actionCancel(approvalID: UUID) async throws -> UIActionStatusDTO {
        let response = try await actionRoundTrip(.actionCancel(approvalID: approvalID))
        guard case .uiActionStatus(let status) = response.result else {
            throw mapUnexpected(response.result)
        }
        return status
    }

    public func actionStatus(approvalID: UUID) async throws -> UIActionStatusDTO {
        let response = try await actionRoundTrip(.actionStatus(approvalID: approvalID))
        guard case .uiActionStatus(let status) = response.result else {
            throw mapUnexpected(response.result)
        }
        return status
    }

    // MARK: - Hook reviews (Step 8B)

    /// Hook-review calls ride the same persistent action connection (and
    /// the same registered UI session) as launch/action review, on the
    /// hook request key with the hook vocabulary. A dropped connection
    /// invalidates bound hook challenges server-side: the caller
    /// reconnects and re-binds; nothing completes across it.
    public func hookList() async throws -> UIHookReviewListDTO {
        let response = try await hookRoundTrip(.hookList)
        guard case .uiHookReviewList(let list) = response.result else {
            throw mapUnexpected(response.result)
        }
        return list
    }

    public func hookBind(approvalID: String) async throws -> UIHookChallengeBundleDTO {
        let response = try await hookRoundTrip(.hookBind(approvalID: approvalID))
        guard case .uiHookChallengeBundle(let bundle) = response.result else {
            throw mapUnexpected(response.result)
        }
        return bundle
    }

    public func hookComplete(_ completion: UIHookCompletion) async throws -> UIHookStatusDTO {
        let response = try await hookRoundTrip(.hookComplete(completion))
        guard case .uiHookStatus(let status) = response.result else {
            throw mapUnexpected(response.result)
        }
        return status
    }

    public func hookDeny(_ deny: UIHookDeny) async throws -> UIHookStatusDTO {
        let response = try await hookRoundTrip(.hookDeny(deny))
        guard case .uiHookStatus(let status) = response.result else {
            throw mapUnexpected(response.result)
        }
        return status
    }

    public func hookCancel(approvalID: String) async throws -> UIHookStatusDTO {
        let response = try await hookRoundTrip(.hookCancel(approvalID: approvalID))
        guard case .uiHookStatus(let status) = response.result else {
            throw mapUnexpected(response.result)
        }
        return status
    }

    public func hookStatus(approvalID: String) async throws -> UIHookStatusDTO {
        let response = try await hookRoundTrip(.hookStatus(approvalID: approvalID))
        guard case .uiHookStatus(let status) = response.result else {
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

    private func actionRoundTrip(_ request: UIActionBridgeRequest) async throws -> IPCResponse {
        if Task.isCancelled {
            throw XPCOperatorUIClientError.cancelled
        }
        let actions = try await liveActions()
        let body = try IPCJSON.encode(request)
        do {
            let frame = try await exchangeAction(body, on: actions)
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

    private func hookRoundTrip(_ request: UIHookBridgeRequest) async throws -> IPCResponse {
        if Task.isCancelled {
            throw XPCOperatorUIClientError.cancelled
        }
        let actions = try await liveActions()
        let body = try IPCJSON.encode(request)
        do {
            let frame = try await exchangeHook(body, on: actions)
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
        enum Next {
            case use(xpc_connection_t)
            case join(Task<xpc_connection_t, Error>)
            case establish(Task<xpc_connection_t, Error>)
        }
        // Check-and-join-or-start under ONE lock: two concurrent
        // first-connects must not both build a connection, or the loser
        // would send on the winner's session before registration lands
        // (spurious Denied until refresh on cold start). The flight
        // check comes first: `establishActions` stores `actions` a full
        // RTT before `register()` completes, so an in-flight caller that
        // used the stored connection would send on an unregistered
        // session. Joining observes only the registered session.
        let next: Next = state.withLock { state in
            if let flight = state.connecting {
                return .join(flight)
            }
            if let existing = state.actions {
                return .use(existing)
            }
            let flight = Task<xpc_connection_t, Error> { try await self.establishActions() }
            state.connecting = flight
            return .establish(flight)
        }
        switch next {
        case .use(let existing):
            return existing
        case .join(let flight):
            // Joins observe only the registered session: the flight
            // completes after `register()` inside `establishActions`.
            return try await flight.value
        case .establish(let flight):
            do {
                let actions = try await flight.value
                state.withLock { $0.connecting = nil }
                return actions
            } catch {
                state.withLock { $0.connecting = nil }
                throw error
            }
        }
    }

    /// Builds, authenticates, stores, and registers one action connection.
    /// Runs at most once at a time (see `liveActions`).
    private func establishActions() async throws -> xpc_connection_t {
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

    /// Action-review round trip. Same connection and session as launch;
    /// the request rides `rv.ui-action-request` with the action vocabulary.
    private func exchangeAction(_ body: Data, on connection: xpc_connection_t) async throws -> Data {
        try await exchangeRaw(body: body, key: UIBridgeWire.actionRequestKey, on: connection).body
    }

    /// Hook-review round trip. Same connection and session as launch and
    /// action; the request rides `rv.ui-hook-request` with the hook
    /// vocabulary.
    private func exchangeHook(_ body: Data, on connection: xpc_connection_t) async throws -> Data {
        try await exchangeRaw(body: body, key: UIBridgeWire.hookRequestKey, on: connection).body
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
