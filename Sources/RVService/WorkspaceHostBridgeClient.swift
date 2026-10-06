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
    private let prepareHandler = Mutex<HostPrepareHandler?>(nil)
    private let redeemHandler = Mutex<HostRedeemHandler?>(nil)
    private let serviceName: String

    public init(serviceName: String = RVService.machServiceName) {
        self.serviceName = serviceName
    }

    /// Installs the host's prepare-only handler (resolve + prepare + describe).
    /// Absent by default: prepare requests are refused, never dispatched.
    public func setPrepareHandler(_ handler: HostPrepareHandler?) {
        prepareHandler.withLock { $0 = handler }
    }

    /// Installs the host's redemption handler (verify + accept + dispatch).
    /// Absent by default: redemption commits are refused, never dispatched.
    public func setRedeemHandler(_ handler: HostRedeemHandler?) {
        redeemHandler.withLock { $0 = handler }
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
                  let response = xpc_dictionary_create_reply(event) else { return }
            if xpc_dictionary_get_value(event, HostBridgeWire.prepareKey) != nil {
                Self.answerPrepare(
                    event, response: response, connection: actions.object,
                    handler: self.flatMap { $0.prepareHandler.withLock { $0 } })
                return
            }
            if xpc_dictionary_get_value(event, HostBridgeWire.redeemKey) != nil {
                Self.answerRedeem(
                    event, response: response, connection: actions.object,
                    handler: self.flatMap { $0.redeemHandler.withLock { $0 } })
                return
            }
            guard Self.isService(event),
                  let referenceBytes = Self.data(event, key: "rv.host-validity"),
                  let reference = try? IPCJSON.decode(AgentPrincipalReference.self, from: referenceBytes) else { return }
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

    // MARK: - Action approvals (Step 6)

    /// Records one host-gate ASK as a principal-bound approval. The subject
    /// must carry a usable agent context for the runtime the authority
    /// names; references come from live host authority, never from the
    /// caller. Fast RPC (no human wait): the service mints the approval and
    /// returns correlation IDs. Any failure means no approval exists.
    public func createActionApproval(
        subject: RuntimeAdmissionSubject,
        action: ProposedAction,
        reason: RuntimeAskReason,
        policyContext: String
    ) async throws -> HostActionApprovalCreatedDTO {
        let (authority, connection, reference) = try approvalReference(for: subject)
        let agent = try approvalAgent(for: subject)
        let reasonRaw: String = switch reason {
        case .mandatoryHuman: "mandatoryHuman"
        case .reviewAsk: "reviewAsk"
        }
        let dto = HostActionApprovalCreateDTO(
            reference: reference,
            action: action,
            reason: reasonRaw,
            policyContext: policyContext,
            definitionID: agent.instance.definitionID,
            definitionRevision: agent.instance.definitionRevision)
        let message = xpc_dictionary_create_empty()
        Self.set(
            try IPCJSON.encode(dto), key: HostActionApprovalWire.createKey, on: message)
        let reply = try await exchange(XPCHeld(message), on: connection)
        guard state.withLock({ $0.connection?.object === connection.object }),
              authority.resolve(reference) != nil,
              let body = XPCIPCWire.body(from: reply.object) else {
            throw XPCEvaluateClientError.authenticationFailed
        }
        let response = try IPCJSON.decode(IPCResponse.self, from: body)
        guard case .hostActionApprovalCreated(let created) = response.result else {
            throw XPCEvaluateClientError.authenticationFailed
        }
        return created
    }

    /// Safe status poll for one approval. Never consumes, never a grant.
    /// Any transport failure throws; the caller keeps polling or gives up.
    public func actionApprovalStatus(
        approvalID: UUID,
        subject: RuntimeAdmissionSubject
    ) async throws -> HostActionApprovalStatus {
        let (authority, connection, reference) = try approvalReference(for: subject)
        let dto = HostActionApprovalStatusDTO(approvalID: approvalID, reference: reference)
        let message = xpc_dictionary_create_empty()
        Self.set(
            try IPCJSON.encode(dto), key: HostActionApprovalWire.statusKey, on: message)
        let reply = try await exchange(XPCHeld(message), on: connection)
        guard state.withLock({ $0.connection?.object === connection.object }),
              authority.resolve(reference) != nil,
              let body = XPCIPCWire.body(from: reply.object) else {
            throw XPCEvaluateClientError.authenticationFailed
        }
        let response = try IPCJSON.decode(IPCResponse.self, from: body)
        guard case .hostActionApprovalStatus(let status) = response.result else {
            throw XPCEvaluateClientError.authenticationFailed
        }
        return status.status
    }

    /// Consumes one grant for the host's exact parked continuation.
    /// `mayExecute` is true if and only if this call atomically consumed
    /// the grant; any other answer means do not run.
    public func consumeActionApproval(
        approvalID: UUID,
        subject: RuntimeAdmissionSubject,
        actionDigestHex: String,
        continuationID: UUID
    ) async throws -> HostActionApprovalDecisionDTO {
        let (authority, connection, reference) = try approvalReference(for: subject)
        let dto = HostActionApprovalConsumeDTO(
            approvalID: approvalID,
            reference: reference,
            actionDigestHex: actionDigestHex,
            continuationID: continuationID)
        let message = xpc_dictionary_create_empty()
        Self.set(
            try IPCJSON.encode(dto), key: HostActionApprovalWire.consumeKey, on: message)
        let reply = try await exchange(XPCHeld(message), on: connection)
        guard state.withLock({ $0.connection?.object === connection.object }),
              authority.resolve(reference) != nil,
              let body = XPCIPCWire.body(from: reply.object) else {
            throw XPCEvaluateClientError.authenticationFailed
        }
        let response = try IPCJSON.decode(IPCResponse.self, from: body)
        guard case .hostActionApprovalDecision(let decision) = response.result else {
            throw XPCEvaluateClientError.authenticationFailed
        }
        return decision
    }

    /// Cancels one approval (the parked continuation went away).
    /// Idempotent; terminal approvals report their status. Cancel transmits
    /// even after the runtime died: it authorizes nothing, and the
    /// descriptive reference lets the service prove the death via its own
    /// validity pull and invalidate eagerly instead of lingering to TTL.
    public func cancelActionApproval(
        approvalID: UUID,
        subject: RuntimeAdmissionSubject
    ) async throws -> HostActionApprovalStatus {
        let snapshot = state.withLock { $0 }
        guard let authority = snapshot.authority, let connection = snapshot.connection else {
            throw XPCEvaluateClientError.authenticationFailed
        }
        let reference = try Self.descriptiveReference(authority: authority, subject: subject)
        let dto = HostActionApprovalCancelDTO(approvalID: approvalID, reference: reference)
        let message = xpc_dictionary_create_empty()
        Self.set(
            try IPCJSON.encode(dto), key: HostActionApprovalWire.cancelKey, on: message)
        let reply = try await exchange(XPCHeld(message), on: connection)
        // No liveness re-check: the principal may have died mid-flight and
        // the cancel still landed; the reply status is the answer.
        guard state.withLock({ $0.connection?.object === connection.object }),
              let body = XPCIPCWire.body(from: reply.object) else {
            throw XPCEvaluateClientError.authenticationFailed
        }
        let response = try IPCJSON.decode(IPCResponse.self, from: body)
        guard case .hostActionApprovalStatus(let status) = response.result else {
            throw XPCEvaluateClientError.authenticationFailed
        }
        return status.status
    }

    /// Descriptive reference for cancel, built from authority-owned bytes
    /// only (live record + authority identity): the record's existence, the
    /// waiter's own instance, and workspace agreement. Usable whether the
    /// runtime is live or dead — the service always re-resolves live before
    /// acting, so a dead reference can only report death, never authorize.
    static func descriptiveReference(
        authority: WorkspacePrincipalAuthority,
        subject: RuntimeAdmissionSubject
    ) throws -> AgentPrincipalReference {
        guard let agent = subject.agent, agent.isUsable,
              let record = authority.descriptiveInstanceForCancel(forRuntime: subject.session.id),
              record.id == agent.instance.id,
              record.runtimeSessionID == subject.session.id,
              record.workspaceSessionID == subject.session.workspaceSessionID else {
            throw XPCEvaluateClientError.authenticationFailed
        }
        return AgentPrincipalReference(
            agentInstanceID: record.id,
            runtimeSessionID: subject.session.id,
            workspaceSessionID: record.workspaceSessionID,
            workspaceHostID: authority.host,
            workspaceHostGeneration: authority.generation)
    }

    /// Live reference for approval RPCs. Same binding checks as `evaluate`:
    /// usable agent context, authority-owned reference for this runtime,
    /// instance and workspace agreement. Nothing caller-supplied.
    private func approvalReference(
        for subject: RuntimeAdmissionSubject
    ) throws -> (WorkspacePrincipalAuthority, XPCHeld, AgentPrincipalReference) {
        let snapshot = state.withLock { $0 }
        guard let authority = snapshot.authority, let connection = snapshot.connection,
              let agent = subject.agent, agent.isUsable,
              let reference = authority.reference(forRuntime: subject.session.id),
              reference.agentInstanceID == agent.instance.id,
              reference.workspaceSessionID == subject.session.workspaceSessionID else {
            throw XPCEvaluateClientError.authenticationFailed
        }
        return (authority, connection, reference)
    }

    private func approvalAgent(
        for subject: RuntimeAdmissionSubject
    ) throws -> AuthenticatedAgentContext {
        guard let agent = subject.agent, agent.isUsable else {
            throw XPCEvaluateClientError.authenticationFailed
        }
        return agent
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

    /// Answers one prepare reverse-RPC. Silence on authentication failure (no
    /// oracle); an explicit refusal DTO on decode/handler failure. The service
    /// side bounds the wait regardless.
    private static func answerPrepare(
        _ event: xpc_object_t, response: xpc_object_t, connection: xpc_object_t,
        handler: HostPrepareHandler?
    ) {
        guard isService(event) else { return }
        var size = 0
        let refusal = HostPrepareResponseDTO(description: nil, error: "invalidRequest")
        guard let bytes = xpc_dictionary_get_data(event, HostBridgeWire.prepareKey, &size),
              size <= HostBridgeWire.maxPrepareBytes,
              let request = try? JSONDecoder().decode(
                  HostPrepareRequestDTO.self, from: Data(bytes: bytes, count: size)),
              let handler else {
            if let encoded = try? JSONEncoder().encode(refusal) {
                set(encoded, key: HostBridgeWire.prepareKey, on: response)
            }
            xpc_connection_send_message(connection, response)
            return
        }
        // Authentication happened before parsing or invoking host preparation.
        let answered = handler(request)
        if let encoded = try? JSONEncoder().encode(answered) {
            set(encoded, key: HostBridgeWire.prepareKey, on: response)
        }
        xpc_connection_send_message(connection, response)
    }

    /// Answers one redemption reverse-RPC. Silence on authentication failure
    /// (no oracle); an explicit refusal DTO on decode/handler failure. The
    /// service side bounds the wait regardless. The handler runs off the
    /// XPC event queue: redemption spawns (up to the service-side 60s
    /// bound), and running it here would head-of-line-block every other
    /// message on the connection; its acceptance fence makes any duplicate
    /// commit safe.
    private static func answerRedeem(
        _ event: xpc_object_t, response: xpc_object_t, connection: xpc_object_t,
        handler: HostRedeemHandler?
    ) {
        guard isService(event) else { return }
        var size = 0
        let refusal = HostRedeemResponseDTO(accepted: false, error: "unknown")
        guard let bytes = xpc_dictionary_get_data(event, HostBridgeWire.redeemKey, &size),
              size <= HostBridgeWire.maxRedeemBytes,
              let request = try? JSONDecoder().decode(
                  HostRedeemCommitDTO.self, from: Data(bytes: bytes, count: size)),
              let handler else {
            if let encoded = try? JSONEncoder().encode(refusal) {
                set(encoded, key: HostBridgeWire.redeemKey, on: response)
            }
            xpc_connection_send_message(connection, response)
            return
        }
        // Authentication happened before parsing or invoking host redemption.
        // The reply rides the retained response/connection from a worker
        // queue; XPC objects are thread-safe and the closure retains both.
        let heldResponse = XPCHeld(response)
        let heldConnection = XPCHeld(connection)
        DispatchQueue.global(qos: .userInitiated).async {
            let answered = handler(request)
            if let encoded = try? JSONEncoder().encode(answered) {
                set(encoded, key: HostBridgeWire.redeemKey, on: heldResponse.object)
            }
            xpc_connection_send_message(heldConnection.object, heldResponse.object)
        }
    }

    private static func set(_ data: Data, key: String, on message: xpc_object_t) {
        data.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { xpc_dictionary_set_data(message, key, base, bytes.count) }
        }
    }
}
#endif
