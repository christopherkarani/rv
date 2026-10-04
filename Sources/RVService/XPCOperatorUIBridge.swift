#if os(macOS)
import Foundation
import RVDomain
import RVIPC
import RVIsolation
import Synchronization
@preconcurrency import XPC

/// rvd side of the operator-UI channel. Mirrors `XPCWorkspaceHostBridge`:
/// discovery Hello stays nonsensitive; every authority-bearing receive
/// requires an established handshake, a non-discovery connection, and a
/// message-authenticated `operatorUI` peer. Session teardown invalidates the
/// ceremony (fail-closed); mutating failures answer opaque denial.
enum XPCOperatorUIBridge {
    static func handles(_ message: xpc_object_t) -> Bool {
        xpc_get_type(message) == XPC_TYPE_DICTIONARY
            && (xpc_dictionary_get_value(message, UIBridgeWire.requestKey) != nil
                || xpc_dictionary_get_value(message, UIBridgeWire.actionRequestKey) != nil
                || xpc_dictionary_get_value(message, UIBridgeWire.hookRequestKey) != nil)
    }

    static func handle(
        message: XPCHeld,
        context: AuthenticatedRequestContext,
        handshakeOK: Bool,
        discoveryOnly: Bool,
        sessions: LiveOperatorUISessionRegistry,
        ceremonies: WorkspaceOperatorCeremonyService,
        actionCeremonies: ActionApprovalCeremonyService,
        hookCeremonies: HookReviewCeremonyService
    ) async {
        guard let response = await reply(
            message: message.object,
            context: context,
            handshakeOK: handshakeOK,
            discoveryOnly: discoveryOnly,
            sessions: sessions,
            ceremonies: ceremonies,
            actionCeremonies: actionCeremonies,
            hookCeremonies: hookCeremonies
        ),
            let peer = xpc_dictionary_get_remote_connection(message.object)
        else {
            return
        }
        xpc_connection_send_message(peer, response)
    }

    static func reply(
        message: xpc_object_t,
        context: AuthenticatedRequestContext,
        handshakeOK: Bool,
        discoveryOnly: Bool,
        sessions: LiveOperatorUISessionRegistry,
        ceremonies: WorkspaceOperatorCeremonyService,
        actionCeremonies: ActionApprovalCeremonyService? = nil,
        hookCeremonies: HookReviewCeremonyService? = nil
    ) async -> xpc_object_t? {
        // Reply-always: the only nil is a missing remote (nothing to send
        // to). Every gate failure answers opaque denial so the requestor's
        // reply handler fires instead of hanging.
        guard let response = xpc_dictionary_create_reply(message) else {
            return nil
        }
        // Action review rides its own key and its own ceremony. The launch
        // path below is untouched.
        if xpc_dictionary_get_value(message, UIBridgeWire.actionRequestKey) != nil {
            return await actionReply(
                message: message,
                response: response,
                context: context,
                handshakeOK: handshakeOK,
                discoveryOnly: discoveryOnly,
                sessions: sessions,
                actionCeremonies: actionCeremonies)
        }
        // Hook review rides its own key and its own ceremony. The launch
        // and action paths are untouched.
        if xpc_dictionary_get_value(message, UIBridgeWire.hookRequestKey) != nil {
            return await hookReply(
                message: message,
                response: response,
                context: context,
                handshakeOK: handshakeOK,
                discoveryOnly: discoveryOnly,
                sessions: sessions,
                hookCeremonies: hookCeremonies)
        }
        guard handshakeOK, !discoveryOnly,
            let peer = context.peer, peer.componentRole == .operatorUI,
            let data = body(message, key: UIBridgeWire.requestKey),
            let request = try? IPCJSON.decode(UIBridgeRequest.self, from: data)
        else {
            return deny(response)
        }
        switch request {
        case .register:
            guard let uiConnection = try? await sessions.register(peer: peer) else {
                return deny(response)
            }
            await ceremonies.uiSessionAuthenticated()
            await actionCeremonies?.uiSessionAuthenticated()
            await hookCeremonies?.uiSessionAuthenticated()
            return answer(
                response,
                result: .uiRegistered(
                    UIRegisteredDTO(uiConnection: uiConnection.rawValue)))
        case .list:
            guard await sessions.session(connectionID: peer.connectionID) != nil else {
                return deny(response)
            }
            let list = await ceremonies.listReviewItems()
            return answer(response, result: .uiReviewList(list))
        case .bind(let operationID):
            guard let session = await sessions.session(connectionID: peer.connectionID) else {
                return deny(response)
            }
            do {
                let (challenge, item) = try await ceremonies.bindReview(
                    operationID: operationID, uiConnection: session.uiConnection)
                return answer(
                    response,
                    result: .uiChallengeBundle(
                        UIChallengeBundleDTO(challenge: challenge, item: item)))
            } catch {
                return deny(response)
            }
        case .complete(let completion):
            guard let session = await sessions.session(connectionID: peer.connectionID) else {
                return deny(response)
            }
            do {
                let status = try await ceremonies.completeCeremony(
                    completion, uiConnection: session.uiConnection)
                return answer(
                    response,
                    result: .uiOperationStatus(
                        UIOperationStatusDTO(operationID: completion.operationID, status: status)))
            } catch {
                return deny(response)
            }
        case .cancel(let operationID):
            guard let session = await sessions.session(connectionID: peer.connectionID) else {
                return deny(response)
            }
            do {
                let status = try await ceremonies.cancelReview(
                    operationID: operationID, uiConnection: session.uiConnection)
                return answer(
                    response,
                    result: .uiOperationStatus(
                        UIOperationStatusDTO(operationID: operationID, status: status)))
            } catch {
                return deny(response)
            }
        case .status(let operationID):
            guard await sessions.session(connectionID: peer.connectionID) != nil else {
                return deny(response)
            }
            let status = await ceremonies.ceremonyStatus(operationID: operationID)
            return answer(
                response,
                result: .uiOperationStatus(
                    UIOperationStatusDTO(operationID: operationID, status: status)))
        }
    }

    private static func answer(_ response: xpc_object_t, result: IPCResult) -> xpc_object_t? {
        guard let bytes = try? IPCJSON.encode(
            IPCResponse(id: UUID(), result: result)) else {
            return nil
        }
        XPCIPCWire.set(bytes, on: response)
        return response
    }

    private static func deny(_ response: xpc_object_t) -> xpc_object_t? {
        answer(response, result: .error(.authorizationDenied))
    }

    private static func body(_ message: xpc_object_t, key: String) -> Data? {
        var size = 0
        guard let bytes = xpc_dictionary_get_data(message, key, &size),
            size <= UIBridgeWire.maxBodyBytes else {
            return nil
        }
        return Data(bytes: bytes, count: size)
    }

    /// Action-review reply path. Same gating shape as launch (handshake,
    /// non-discovery, authenticated `operatorUI` peer, registered session,
    /// reply-always opaque denial), but a separate request vocabulary and
    /// a separate ceremony: no launch challenge, completion, or status can
    /// enter here, and no action completion can reach the launch ceremony.
    static func actionReply(
        message: xpc_object_t,
        response: xpc_object_t,
        context: AuthenticatedRequestContext,
        handshakeOK: Bool,
        discoveryOnly: Bool,
        sessions: LiveOperatorUISessionRegistry,
        actionCeremonies: ActionApprovalCeremonyService?
    ) async -> xpc_object_t? {
        guard handshakeOK, !discoveryOnly,
            let peer = context.peer, peer.componentRole == .operatorUI,
            let data = body(message, key: UIBridgeWire.actionRequestKey),
            let request = try? IPCJSON.decode(UIActionBridgeRequest.self, from: data),
            let actionCeremonies
        else {
            return deny(response)
        }
        switch request {
        case .actionList:
            guard await sessions.session(connectionID: peer.connectionID) != nil else {
                return deny(response)
            }
            let list = await actionCeremonies.listActionReviews()
            return answer(response, result: .uiActionReviewList(list))
        case .actionBind(let approvalID):
            guard let session = await sessions.session(connectionID: peer.connectionID) else {
                return deny(response)
            }
            do {
                let (challenge, item) = try await actionCeremonies.bindActionReview(
                    approvalID: approvalID, uiConnection: session.uiConnection)
                return answer(
                    response,
                    result: .uiActionChallengeBundle(
                        UIActionChallengeBundleDTO(challenge: challenge, item: item)))
            } catch {
                return deny(response)
            }
        case .actionComplete(let completion):
            guard let session = await sessions.session(connectionID: peer.connectionID) else {
                return deny(response)
            }
            do {
                let status = try await actionCeremonies.completeActionCeremony(
                    completion, uiConnection: session.uiConnection)
                return answer(
                    response,
                    result: .uiActionStatus(
                        UIActionStatusDTO(approvalID: completion.approvalID, status: status)))
            } catch {
                return deny(response)
            }
        case .actionDeny(let denyRequest):
            guard let session = await sessions.session(connectionID: peer.connectionID) else {
                return deny(response)
            }
            do {
                let status = try await actionCeremonies.denyActionCeremony(
                    denyRequest, uiConnection: session.uiConnection)
                return answer(
                    response,
                    result: .uiActionStatus(
                        UIActionStatusDTO(approvalID: denyRequest.approvalID, status: status)))
            } catch {
                return deny(response)
            }
        case .actionCancel(let approvalID):
            guard let session = await sessions.session(connectionID: peer.connectionID) else {
                return deny(response)
            }
            do {
                let status = try await actionCeremonies.cancelActionReview(
                    approvalID: approvalID, uiConnection: session.uiConnection)
                return answer(
                    response,
                    result: .uiActionStatus(
                        UIActionStatusDTO(approvalID: approvalID, status: status)))
            } catch {
                return deny(response)
            }
        case .actionStatus(let approvalID):
            guard await sessions.session(connectionID: peer.connectionID) != nil else {
                return deny(response)
            }
            let status = await actionCeremonies.actionStatus(approvalID: approvalID)
            return answer(
                response,
                result: .uiActionStatus(
                    UIActionStatusDTO(approvalID: approvalID, status: status)))
        }
    }

    /// Hook-review reply path. Same gating shape as action (handshake,
    /// non-discovery, authenticated `operatorUI` peer, registered session,
    /// reply-always opaque denial), but a separate request vocabulary and
    /// a separate ceremony: no launch or action challenge, completion, or
    /// status can enter here, and no hook completion can reach those
    /// ceremonies.
    static func hookReply(
        message: xpc_object_t,
        response: xpc_object_t,
        context: AuthenticatedRequestContext,
        handshakeOK: Bool,
        discoveryOnly: Bool,
        sessions: LiveOperatorUISessionRegistry,
        hookCeremonies: HookReviewCeremonyService?
    ) async -> xpc_object_t? {
        guard handshakeOK, !discoveryOnly,
            let peer = context.peer, peer.componentRole == .operatorUI,
            let data = body(message, key: UIBridgeWire.hookRequestKey),
            let request = try? IPCJSON.decode(UIHookBridgeRequest.self, from: data),
            let hookCeremonies
        else {
            return deny(response)
        }
        switch request {
        case .hookList:
            guard await sessions.session(connectionID: peer.connectionID) != nil else {
                return deny(response)
            }
            let list = await hookCeremonies.listHookReviews()
            return answer(response, result: .uiHookReviewList(list))
        case .hookBind(let approvalID):
            guard let session = await sessions.session(connectionID: peer.connectionID) else {
                return deny(response)
            }
            do {
                let (challenge, item) = try await hookCeremonies.bindHookReview(
                    approvalID: approvalID, uiConnection: session.uiConnection)
                return answer(
                    response,
                    result: .uiHookChallengeBundle(
                        UIHookChallengeBundleDTO(challenge: challenge, item: item)))
            } catch {
                return deny(response)
            }
        case .hookComplete(let completion):
            guard let session = await sessions.session(connectionID: peer.connectionID) else {
                return deny(response)
            }
            do {
                let status = try await hookCeremonies.completeHookCeremony(
                    completion, uiConnection: session.uiConnection)
                return answer(
                    response,
                    result: .uiHookStatus(
                        UIHookStatusDTO(approvalID: completion.approvalID, status: status)))
            } catch {
                return deny(response)
            }
        case .hookDeny(let denyRequest):
            guard let session = await sessions.session(connectionID: peer.connectionID) else {
                return deny(response)
            }
            do {
                let status = try await hookCeremonies.denyHookCeremony(
                    denyRequest, uiConnection: session.uiConnection)
                return answer(
                    response,
                    result: .uiHookStatus(
                        UIHookStatusDTO(approvalID: denyRequest.approvalID, status: status)))
            } catch {
                return deny(response)
            }
        case .hookCancel(let approvalID):
            guard let session = await sessions.session(connectionID: peer.connectionID) else {
                return deny(response)
            }
            do {
                let status = try await hookCeremonies.cancelHookReview(
                    approvalID: approvalID, uiConnection: session.uiConnection)
                return answer(
                    response,
                    result: .uiHookStatus(
                        UIHookStatusDTO(approvalID: approvalID, status: status)))
            } catch {
                return deny(response)
            }
        case .hookStatus(let approvalID):
            guard await sessions.session(connectionID: peer.connectionID) != nil else {
                return deny(response)
            }
            let status = await hookCeremonies.hookStatus(approvalID: approvalID)
            return answer(
                response,
                result: .uiHookStatus(
                    UIHookStatusDTO(approvalID: approvalID, status: status)))
        }
    }
}
#endif
