#if os(macOS)
import Foundation
import RVDomain
import RVIPC
import RVIsolation
import Synchronization
@preconcurrency import XPC

/// A workspace host's persistent, bidirectional, authenticated service channel.
/// No caller-supplied principal is accepted: references come from its live registry.
public final class WorkspaceHostBridgeClient: Sendable {
    private struct State {
        var authority: WorkspacePrincipalAuthority?
        var connection: XPCHeld?
    }
    private let state = Mutex(State())
    private let serviceName: String

    public init(serviceName: String = RVService.machServiceName) {
        self.serviceName = serviceName
    }

    public func connect(_ authority: WorkspacePrincipalAuthority) async throws {
        // This client never reconnects into an old incarnation automatically.
        invalidate()
        let discovery = XPCHeld(xpc_connection_create_mach_service(serviceName, nil, 0))
        xpc_connection_set_event_handler(discovery.object) { _ in }
        xpc_connection_resume(discovery.object)
        defer { xpc_connection_cancel(discovery.object) }
        let hello = xpc_dictionary_create_empty()
        XPCIPCWire.set(try IPCJSON.encode(Hello()), on: hello)
        let reply = try await exchange(XPCHeld(hello), on: discovery)
        guard let body = XPCIPCWire.body(from: reply.object),
              try IPCJSON.decode(HelloAck.self, from: body).status == .ok,
              let endpoint = xpc_dictionary_get_value(reply.object, XPCIPCWire.actionEndpointKey),
              xpc_get_type(endpoint) == XPC_TYPE_ENDPOINT else {
            throw XPCEvaluateClientError.authenticationFailed
        }
        let actions = XPCHeld(xpc_connection_create_from_endpoint(endpoint))
        state.withLock { $0 = State(authority: authority, connection: actions) }
        xpc_connection_set_event_handler(actions.object) { [weak self] event in
            if xpc_get_type(event) == XPC_TYPE_ERROR {
                self?.invalidate()
                return
            }
            guard xpc_get_type(event) == XPC_TYPE_DICTIONARY,
                  Self.isService(event),
                  let referenceBytes = Self.data(event, key: "rv.host-validity"),
                  let reference = try? IPCJSON.decode(AgentPrincipalReference.self, from: referenceBytes),
                  let response = xpc_dictionary_create_reply(event) else { return }
            // Authentication happens before parsing or invoking host authority.
            let validity = authority.resolve(reference)
            if let validity, let bytes = try? IPCJSON.encode(validity) {
                Self.set(bytes, key: "rv.host-validity", on: response)
            }
            xpc_connection_send_message(actions.object, response)
        }
        xpc_connection_resume(actions.object)
        do {
            let actionHello = xpc_dictionary_create_empty()
            XPCIPCWire.set(try IPCJSON.encode(Hello()), on: actionHello)
            let actionReply = try await exchange(XPCHeld(actionHello), on: actions)
            guard let body = XPCIPCWire.body(from: actionReply.object),
                  try IPCJSON.decode(HelloAck.self, from: body).status == .ok else {
                throw XPCEvaluateClientError.authenticationFailed
            }
            let registration = HostBridgeRegistration(workspace: authority.workspace.rawValue,
                host: authority.host.rawValue, generation: authority.generation.rawValue)
            let message = xpc_dictionary_create_empty()
            Self.set(try IPCJSON.encode(registration), key: "rv.host-registration", on: message)
            let registered = try await exchange(XPCHeld(message), on: actions)
            guard xpc_dictionary_get_bool(registered.object, "rv.host-registered") else {
                throw XPCEvaluateClientError.authenticationFailed
            }
        } catch {
            invalidate()
            throw error
        }
    }

    public func invalidate() {
        let old = state.withLock { value -> XPCHeld? in
            let old = value.connection
            value = State()
            return old
        }
        if let old { xpc_connection_cancel(old.object) }
    }

    /// Called only after runtime admission has authenticated its granted channel.
    /// The host checks the bound instance again before and after service evaluation.
    public func evaluate(
        subject: RuntimeAdmissionSubject, command: ShellCommand
    ) async throws -> EvaluateReply {
        let snapshot = state.withLock { $0 }
        guard let authority = snapshot.authority, let connection = snapshot.connection,
              let agent = subject.agent, agent.isUsable,
              let reference = authority.reference(forRuntime: subject.session.id),
              reference.agentInstanceID == agent.instance.id,
              reference.workspaceSessionID == subject.session.workspaceSessionID else {
            throw XPCEvaluateClientError.authenticationFailed
        }
        let evaluation = HostBridgeEvaluation(id: UUID(), reference: reference,
            params: EvaluateParams(request: .makeDayOne(command: command), cwd: subject.policyWorkspace))
        let message = xpc_dictionary_create_empty()
        Self.set(try IPCJSON.encode(evaluation), key: "rv.host-evaluate", on: message)
        let reply = try await exchange(XPCHeld(message), on: connection)
        guard state.withLock({ $0.connection?.object === connection.object }),
              authority.resolve(reference) != nil,
              let body = XPCIPCWire.body(from: reply.object) else {
            throw XPCEvaluateClientError.authenticationFailed
        }
        let response = try IPCJSON.decode(IPCResponse.self, from: body)
        guard response.id == evaluation.id, case .evaluate(let result) = response.result else {
            throw XPCEvaluateClientError.authenticationFailed
        }
        return result
    }

    private func exchange(_ message: XPCHeld, on connection: XPCHeld) async throws -> XPCHeld {
        let once = OnceResume<XPCHeld>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !once.install(continuation) else { return }
                if Task.isCancelled {
                    once.resume(throwing: XPCEvaluateClientError.cancelled)
                    return
                }
                // Bounded failure; no hung RPC can keep a positive context alive.
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                    once.resume(throwing: XPCEvaluateClientError.connectFailed)
                }
                xpc_connection_send_message_with_reply(connection.object, message.object, nil) { reply in
                    guard Self.isService(reply) else {
                        xpc_connection_cancel(connection.object)
                        once.resume(throwing: XPCEvaluateClientError.authenticationFailed)
                        return
                    }
                    once.resume(returning: XPCHeld(reply))
                }
            }
        } onCancel: {
            xpc_connection_cancel(connection.object)
            once.resume(throwing: XPCEvaluateClientError.cancelled)
        }
    }

    private static func isService(_ message: xpc_object_t) -> Bool {
        guard let trust = try? ProtectedPeerTrustConfiguration.installed(),
              let peer = try? MacOSPeerAuthenticator.capture(message: message,
                connectionID: UUID(), trust: trust) else { return false }
        return peer.componentRole == .service
    }

    private static func data(_ message: xpc_object_t, key: String) -> Data? {
        var size = 0
        guard let bytes = xpc_dictionary_get_data(message, key, &size), size <= 65_536 else { return nil }
        return Data(bytes: bytes, count: size)
    }

    private static func set(_ data: Data, key: String, on message: xpc_object_t) {
        data.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { xpc_dictionary_set_data(message, key, base, bytes.count) }
        }
    }
}
#endif
