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
            && xpc_dictionary_get_value(message, UIBridgeWire.requestKey) != nil
    }

    static func handle(
        message: XPCHeld,
        context: AuthenticatedRequestContext,
        handshakeOK: Bool,
        discoveryOnly: Bool,
        sessions: LiveOperatorUISessionRegistry,
        ceremonies: WorkspaceOperatorCeremonyService
    ) async {
        guard let response = await reply(
            message: message.object,
            context: context,
            handshakeOK: handshakeOK,
            discoveryOnly: discoveryOnly,
            sessions: sessions,
            ceremonies: ceremonies
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
        ceremonies: WorkspaceOperatorCeremonyService
    ) async -> xpc_object_t? {
        guard handshakeOK, !discoveryOnly,
            let peer = context.peer, peer.componentRole == .operatorUI,
            let data = body(message, key: UIBridgeWire.requestKey),
            let request = try? IPCJSON.decode(UIBridgeRequest.self, from: data),
            let response = xpc_dictionary_create_reply(message) else {
            return nil
        }
        switch request {
        case .register:
            let uiConnection = try? await sessions.register(peer: peer)
            guard let uiConnection else { return nil }
            await ceremonies.uiSessionAuthenticated()
            xpc_dictionary_set_string(
                response, UIBridgeWire.uiConnectionKey, uiConnection.rawValue.uuidString)
            xpc_dictionary_set_bool(response, UIBridgeWire.registeredKey, true)
            return response
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
}
#endif
