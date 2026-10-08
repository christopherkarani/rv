#if canImport(XPC)
import Foundation
import Synchronization
import RVIsolation
import RVIPC
@preconcurrency import XPC

public final class XPCEvaluateClient: Sendable {
    public let serviceName: String
    private let state: Mutex<ClientState>

    /// Never cancel/resume a connection while holding the state lock.
    private struct ClientState {
        var connection: xpc_connection_t?
        var opened = 0
    }

    public init(serviceName: String = RVService.machServiceName) {
        self.serviceName = serviceName
        self.state = Mutex(ClientState())
    }

    public var openedConnectionCount: Int {
        state.withLock { $0.opened }
    }

    public func invalidate() {
        let existing = state.withLock { state -> xpc_connection_t? in
            let current = state.connection
            state.connection = nil
            return current
        }
        if let existing {
            xpc_connection_cancel(existing)
        }
    }

    public func perform(_ body: Data) async throws -> Data {
        if Task.isCancelled {
            throw XPCEvaluateClientError.cancelled
        }
        let discovery = try liveConnection()
        let hello = try IPCJSON.encode(Hello())
        // This reply is authenticated before its endpoint field is inspected.
        let discoveryReply = try await exchange(hello, on: discovery, requireEndpoint: true)
        let discoveryAck = try IPCJSON.decode(HelloAck.self, from: discoveryReply.body)
        guard discoveryAck.status == .ok, let endpoint = discoveryReply.endpoint else {
            invalidate()
            throw XPCEvaluateClientError.authenticationFailed
        }
        let actions = xpc_connection_create_from_endpoint(endpoint.object)
        let heldActions = XPCHeld(actions)
        xpc_connection_set_event_handler(actions) { event in
            if xpc_get_type(event) == XPC_TYPE_ERROR {
                xpc_connection_cancel(heldActions.object)
            }
        }
        xpc_connection_resume(actions)
        defer { xpc_connection_cancel(actions) }
        // Authenticate this exact non-rediscoverable peer before sending action bytes.
        let actionHello = try await exchange(hello, on: actions)
        let actionAck = try IPCJSON.decode(HelloAck.self, from: actionHello.body)
        guard actionAck.status == .ok else {
            throw XPCEvaluateClientError.authenticationFailed
        }
        return (try await exchange(body, on: actions)).body
    }

    private struct VerifiedExchange: Sendable {
        let body: Data
        let endpoint: XPCHeld?
    }

    private func exchange(_ body: Data, on connection: xpc_connection_t, requireEndpoint: Bool = false) async throws -> VerifiedExchange {
        let once = OnceResume<VerifiedExchange>()
        let held = XPCHeld(connection)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if once.install(continuation) {
                    return
                }
                if Task.isCancelled {
                    once.resume(throwing: XPCEvaluateClientError.cancelled)
                    return
                }
                let message = xpc_dictionary_create_empty()
                XPCIPCWire.set(body, on: message)
                xpc_connection_send_message_with_reply(held.object, message, nil) { reply in
                    let type = xpc_get_type(reply)
                    if type == XPC_TYPE_ERROR {
                        xpc_connection_cancel(held.object)
                        once.resume(throwing: XPCEvaluateClientError.connectFailed)
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
                        once.resume(throwing: XPCEvaluateClientError.authenticationFailed)
                        self.invalidate()
                        return
                    }
                    guard let data = XPCIPCWire.body(from: reply) else {
                        once.resume(throwing: XPCEvaluateClientError.connectFailed)
                        return
                    }
                    let endpoint: XPCHeld?
                    if requireEndpoint {
                        guard let object = xpc_dictionary_get_value(reply, XPCIPCWire.actionEndpointKey),
                            xpc_get_type(object) == XPC_TYPE_ENDPOINT else {
                            xpc_connection_cancel(held.object)
                            once.resume(throwing: XPCEvaluateClientError.authenticationFailed)
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
            once.resume(throwing: XPCEvaluateClientError.cancelled)
            self.invalidate()
        }
    }

    private func liveConnection() throws -> xpc_connection_t {
        if let existing = state.withLock({ $0.connection }) {
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
            if let existing = state.connection {
                return existing
            }
            state.connection = created
            state.opened += 1
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
            if $0.connection === candidate {
                $0.connection = nil
            }
        }
    }
}

public enum XPCEvaluateClientError: Error, Sendable, Equatable {
    case authenticationFailed
    case connectFailed
    case cancelled
}

final class OnceResume<T: Sendable>: Sendable {
    private enum State {
        case idle
        case pending(Error)
        case armed(CheckedContinuation<T, Error>)
        case finished
    }

    private enum InstallAction {
        case resumeThrowing(Error)
        case armed
        case settled
    }

    // A taken continuation is always resumed after the state lock is released.
    private let state: Mutex<State>

    init() {
        state = Mutex(.idle)
    }

    init(_ continuation: CheckedContinuation<T, Error>) {
        state = Mutex(.armed(continuation))
    }

    /// Stores `continuation`, or resumes it immediately if cancel already landed.
    /// Returns `true` when the continuation is already settled.
    @discardableResult
    func install(_ continuation: CheckedContinuation<T, Error>) -> Bool {
        let action = state.withLock { state -> InstallAction in
            switch state {
            case .pending(let error):
                state = .finished
                return .resumeThrowing(error)
            case .idle:
                state = .armed(continuation)
                return .armed
            case .armed, .finished:
                return .settled
            }
        }
        switch action {
        case .resumeThrowing(let error):
            continuation.resume(throwing: error)
            return true
        case .armed:
            return false
        case .settled:
            return true
        }
    }

    func resume(returning value: T) {
        let taken = state.withLock { state -> CheckedContinuation<T, Error>? in
            guard case .armed(let continuation) = state else { return nil }
            state = .finished
            return continuation
        }
        taken?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        let taken = state.withLock { state -> CheckedContinuation<T, Error>? in
            switch state {
            case .armed(let continuation):
                state = .finished
                return continuation
            case .idle:
                state = .pending(error)
                return nil
            case .pending, .finished:
                return nil
            }
        }
        taken?.resume(throwing: error)
    }
}
#endif
