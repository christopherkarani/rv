#if os(macOS)
import Foundation
import RVDomain
import RVIPC
import RVIsolation
import Synchronization
@preconcurrency import XPC

/// rvd side of the action-approval host RPCs (create / status / consume /
/// cancel). Mirrors `XPCWorkspaceHostBridge`: every authority-bearing
/// receive requires an established handshake, a non-discovery connection,
/// liveness, and a message-authenticated `workspaceHost` peer whose
/// connection matches the session. Mutating failures answer opaque denial
/// (no oracle); failures never create, consume, or resurrect authority.
enum XPCActionApprovalBridge {
    /// Returns true when this message belongs to the approval-RPC protocol,
    /// including malformed or unauthorized messages (which must not fall
    /// through to generic IPC dispatch).
    static func handles(_ message: xpc_object_t) -> Bool {
        xpc_dictionary_get_value(message, HostActionApprovalWire.createKey) != nil
            || xpc_dictionary_get_value(message, HostActionApprovalWire.statusKey) != nil
            || xpc_dictionary_get_value(message, HostActionApprovalWire.consumeKey) != nil
            || xpc_dictionary_get_value(message, HostActionApprovalWire.cancelKey) != nil
    }

    static func handle(
        message: XPCHeld, context: AuthenticatedRequestContext,
        handshakeOK: Bool, discoveryOnly: Bool, liveness: HostBridgeLiveness,
        ceremonies: ActionApprovalCeremonyService
    ) async {
        let event = message.object
        guard let reply = xpc_dictionary_create_reply(event),
              let remote = xpc_dictionary_get_remote_connection(event) else { return }
        var result = IPCResponse(id: UUID(), result: .error(.authorizationDenied))
        guard handshakeOK, !discoveryOnly, liveness.isLive,
              let peer = context.peer, peer.componentRole == .workspaceHost,
              context.connectionID == peer.connectionID else {
            XPCIPCWire.set((try? IPCJSON.encode(result)) ?? Data(), on: reply)
            xpc_connection_send_message(remote, reply)
            return
        }
        let create = body(event, key: HostActionApprovalWire.createKey)
        let status = body(event, key: HostActionApprovalWire.statusKey)
        let consume = body(event, key: HostActionApprovalWire.consumeKey)
        let cancel = body(event, key: HostActionApprovalWire.cancelKey)
        // Exactly one RPC per message. Anything else stays denied.
        let present = [create, status, consume, cancel].compactMap { $0 }
        if present.count == 1 {
            if let create,
               let dto = try? IPCJSON.decode(HostActionApprovalCreateDTO.self, from: create) {
                do {
                    let created = try await ceremonies.requestApproval(dto, hostPeer: peer)
                    result = IPCResponse(
                        id: result.id, result: .hostActionApprovalCreated(created))
                } catch { /* Opaque denial; no oracle. */ }
            } else if let status,
                      let dto = try? IPCJSON.decode(HostActionApprovalStatusDTO.self, from: status) {
                let reply = await ceremonies.approvalStatus(dto, hostPeer: peer)
                result = IPCResponse(
                    id: result.id, result: .hostActionApprovalStatus(reply))
            } else if let consume,
                      let dto = try? IPCJSON.decode(HostActionApprovalConsumeDTO.self, from: consume) {
                let decision = await ceremonies.consumeApproval(dto, hostPeer: peer)
                result = IPCResponse(
                    id: result.id, result: .hostActionApprovalDecision(decision))
            } else if let cancel,
                      let dto = try? IPCJSON.decode(HostActionApprovalCancelDTO.self, from: cancel) {
                let reply = await ceremonies.cancelApproval(dto, hostPeer: peer)
                result = IPCResponse(
                    id: result.id, result: .hostActionApprovalStatus(reply))
            }
        }
        if !liveness.isLive {
            result = IPCResponse(id: result.id, result: .error(.authorizationDenied))
        }
        XPCIPCWire.set((try? IPCJSON.encode(result)) ?? Data(), on: reply)
        xpc_connection_send_message(remote, reply)
    }

    private static func body(_ message: xpc_object_t, key: String) -> Data? {
        var size = 0
        guard let pointer = xpc_dictionary_get_data(message, key, &size),
              size <= HostActionApprovalWire.maxBodyBytes else { return nil }
        return Data(bytes: pointer, count: size)
    }
}
#endif
