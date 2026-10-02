#if os(macOS)
import Foundation
import RVDomain
import RVIPC
import RVIsolation
import Synchronization
@preconcurrency import XPC

struct HostBridgeRegistration: Codable, Sendable {
    let workspace: UUID
    let host: UUID
    let generation: UUID
}

struct HostBridgeEvaluation: Codable, Sendable {
    let id: UUID
    let reference: AgentPrincipalReference
    let params: EvaluateParams
}

enum HostBridgeWire {
    static let registrationKey = "rv.host-registration"
    static let registrationOKKey = "rv.host-registered"
    static let validityKey = "rv.host-validity"
    static let evaluationKey = "rv.host-evaluate"
    static let prepareKey = "rv.host-prepare"
    static let redeemKey = "rv.host-redeem"
    static let maxPrepareBytes = 1_048_576
    /// Single source of truth: the RVIPC wire contract owns the bound;
    /// this alias keeps the rvd-side enforcement from drifting.
    static let maxRedeemBytes = HostRedeemWire.maxBodyBytes
    /// Redemption covers accept plus contained spawn plus the Seatbelt
    /// handshake; the bound is generous so a slow spawn cannot look like a
    /// lost reply. Firing it records an unknown outcome, never a retry.
    static let redeemTimeoutSeconds = 60

    static func body(_ message: xpc_object_t, key: String) -> Data? {
        var size = 0
        guard let pointer = xpc_dictionary_get_data(message, key, &size),
              size <= 1_048_576 else { return nil }
        return Data(bytes: pointer, count: size)
    }

    static func set(_ data: Data, key: String, on message: xpc_object_t) {
        data.withUnsafeBytes { bytes in
            xpc_dictionary_set_data(message, key, bytes.baseAddress, bytes.count)
        }
    }
}

/// The error handler closes this synchronously, before actor teardown queues.
final class HostBridgeLiveness: Sendable {
    private let live = Mutex(true)
    var isLive: Bool { live.withLock { $0 } }
    func disconnect() { live.withLock { $0 = false } }
}

enum XPCWorkspaceHostBridge {
    /// Returns true when this message belongs to the bridge protocol, including
    /// malformed or unauthorized messages (which must not fall through).
    static func handles(_ message: xpc_object_t) -> Bool {
        xpc_dictionary_get_value(message, HostBridgeWire.registrationKey) != nil ||
            xpc_dictionary_get_value(message, HostBridgeWire.evaluationKey) != nil
    }

    static func handle(
        message: XPCHeld, context: AuthenticatedRequestContext,
        handshakeOK: Bool, discoveryOnly: Bool, liveness: HostBridgeLiveness,
        registry: LiveWorkspaceHostRegistry, runtime: ServiceRuntime
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
        let registration = HostBridgeWire.body(event, key: HostBridgeWire.registrationKey)
        let evaluation = HostBridgeWire.body(event, key: HostBridgeWire.evaluationKey)
        let hasRegistration = xpc_dictionary_get_value(event, HostBridgeWire.registrationKey) != nil
        let hasEvaluation = xpc_dictionary_get_value(event, HostBridgeWire.evaluationKey) != nil
        if let registration, !hasEvaluation,
           let value = try? JSONDecoder().decode(HostBridgeRegistration.self, from: registration) {
            let heldConnection = XPCHeld(remote)
            do {
                try await registry.register(peer: peer,
                    workspace: WorkspaceSessionID(rawValue: value.workspace),
                    host: WorkspaceHostID(rawValue: value.host),
                    generation: WorkspaceHostGeneration(rawValue: value.generation),
                    isConnected: { liveness.isLive },
                    validate: { reference in
                        try await requestValidity(reference, connection: heldConnection,
                            peer: peer, liveness: liveness)
                    },
                    prepare: { request in
                        try await requestPrepare(request, connection: heldConnection,
                            peer: peer, liveness: liveness)
                    },
                    redeem: { request in
                        try await requestRedeem(request, connection: heldConnection,
                            peer: peer, liveness: liveness)
                    })
                if liveness.isLive {
                    xpc_dictionary_set_bool(reply, HostBridgeWire.registrationOKKey, true)
                } else {
                    await registry.disconnect(connectionID: peer.connectionID)
                }
            } catch { /* Every refusal remains authorizationDenied. */ }
        } else if let evaluation, !hasRegistration,
                  let value = try? JSONDecoder().decode(HostBridgeEvaluation.self, from: evaluation) {
            do {
                result = IPCResponse(id: value.id, result: .error(.authorizationDenied))
                let agentContext = try await registry.resolve(value.reference, hostPeer: peer)
                guard liveness.isLive else { throw LiveWorkspaceHostError.disconnected }
                let evaluated = await runtime.evaluateAgent(value.params, requestID: value.id, context: agentContext)
                // Evaluation results are released only after fresh validity.
                _ = try await registry.resolve(value.reference, hostPeer: peer)
                guard liveness.isLive else { throw LiveWorkspaceHostError.disconnected }
                result = IPCResponse(id: result.id, result: .evaluate(evaluated))
            } catch { /* No cached successful operation survives failed validity. */ }
        }
        if !liveness.isLive {
            result = IPCResponse(id: result.id, result: .error(.authorizationDenied))
            xpc_dictionary_set_bool(reply, HostBridgeWire.registrationOKKey, false)
        }
        XPCIPCWire.set((try? IPCJSON.encode(result)) ?? Data(), on: reply)
        xpc_connection_send_message(remote, reply)
    }

    private static func requestValidity(
        _ reference: AgentPrincipalReference, connection: XPCHeld,
        peer: AuthenticatedPeer, liveness: HostBridgeLiveness
    ) async throws -> AgentPrincipalValidity? {
        guard liveness.isLive else { throw LiveWorkspaceHostError.disconnected }
        let bytes = try JSONEncoder().encode(reference)
        return try await withCheckedThrowingContinuation { continuation in
            let pending = HostValidityPending(continuation)
            let request = xpc_dictionary_create_empty()
            HostBridgeWire.set(bytes, key: HostBridgeWire.validityKey, on: request)
            xpc_connection_send_message_with_reply(connection.object, request, nil) { reply in
                let value = Result<AgentPrincipalValidity?, any Error> {
                    guard liveness.isLive else { throw LiveWorkspaceHostError.disconnected }
                    let trust = try ProtectedPeerTrustConfiguration.installed()
                    let current = try MacOSPeerAuthenticator.capture(message: reply,
                        connectionID: peer.connectionID, trust: trust)
                    guard current == peer else { throw LiveWorkspaceHostError.peerMismatch }
                    guard let data = HostBridgeWire.body(reply, key: HostBridgeWire.validityKey) else {
                        throw LiveWorkspaceHostError.validityRPCFailed
                    }
                    return try JSONDecoder().decode(AgentPrincipalValidity.self, from: data)
                }
                pending.finish(value)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                pending.finish(.failure(LiveWorkspaceHostError.validityRPCFailed))
            }
        }
    }

    /// Reverse-RPC asking the registered host to prepare one launch. Mirrors
    /// `requestValidity`: peer re-captured from the reply, bounded wait,
    /// once-resume. Returns the host's refusal (nil description) as data;
    /// transport/peer failures throw.
    static func requestPrepare(
        _ request: HostPrepareRequestDTO, connection: XPCHeld,
        peer: AuthenticatedPeer, liveness: HostBridgeLiveness
    ) async throws -> HostPrepareResponseDTO {
        guard liveness.isLive else { throw LiveWorkspaceHostError.disconnected }
        let bytes = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let pending = HostPreparePending(continuation)
            let message = xpc_dictionary_create_empty()
            HostBridgeWire.set(bytes, key: HostBridgeWire.prepareKey, on: message)
            xpc_connection_send_message_with_reply(connection.object, message, nil) { reply in
                let value = Result<HostPrepareResponseDTO, any Error> {
                    guard liveness.isLive else { throw LiveWorkspaceHostError.disconnected }
                    let trust = try ProtectedPeerTrustConfiguration.installed()
                    let current = try MacOSPeerAuthenticator.capture(message: reply,
                        connectionID: peer.connectionID, trust: trust)
                    guard current == peer else { throw LiveWorkspaceHostError.peerMismatch }
                    guard let data = HostBridgeWire.body(reply, key: HostBridgeWire.prepareKey) else {
                        throw LiveWorkspaceHostError.prepareRPCFailed
                    }
                    return try JSONDecoder().decode(HostPrepareResponseDTO.self, from: data)
                }
                pending.finish(value)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                pending.finish(.failure(LiveWorkspaceHostError.prepareRPCFailed))
            }
        }
    }

    /// Reverse-RPC committing one consumed permit's redemption to the
    /// registered host. Mirrors `requestPrepare`: peer re-captured from the
    /// reply, bounded wait, once-resume — with a longer bound covering the
    /// contained spawn and Seatbelt handshake. Returns the host's outcome
    /// (acceptance, refusal, or launch result) as data; transport/peer
    /// failures throw. Sent at most once per permit; the caller never
    /// retries.
    static func requestRedeem(
        _ request: HostRedeemCommitDTO, connection: XPCHeld,
        peer: AuthenticatedPeer, liveness: HostBridgeLiveness
    ) async throws -> HostRedeemResponseDTO {
        guard liveness.isLive else { throw LiveWorkspaceHostError.disconnected }
        let bytes = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let pending = HostRedeemPending(continuation)
            let message = xpc_dictionary_create_empty()
            HostBridgeWire.set(bytes, key: HostBridgeWire.redeemKey, on: message)
            xpc_connection_send_message_with_reply(connection.object, message, nil) { reply in
                let value = Result<HostRedeemResponseDTO, any Error> {
                    guard liveness.isLive else { throw LiveWorkspaceHostError.disconnected }
                    let trust = try ProtectedPeerTrustConfiguration.installed()
                    let current = try MacOSPeerAuthenticator.capture(message: reply,
                        connectionID: peer.connectionID, trust: trust)
                    guard current == peer else { throw LiveWorkspaceHostError.peerMismatch }
                    guard let data = HostBridgeWire.body(reply, key: HostBridgeWire.redeemKey) else {
                        throw LiveWorkspaceHostError.redeemRPCFailed
                    }
                    return try JSONDecoder().decode(HostRedeemResponseDTO.self, from: data)
                }
                pending.finish(value)
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + Double(HostBridgeWire.redeemTimeoutSeconds)
            ) {
                pending.finish(.failure(LiveWorkspaceHostError.redeemRPCFailed))
            }
        }
    }
}

private final class HostValidityPending: Sendable {
    private let continuation: Mutex<CheckedContinuation<AgentPrincipalValidity?, any Error>?>
    init(_ value: CheckedContinuation<AgentPrincipalValidity?, any Error>) {
        continuation = Mutex(value)
    }
    func finish(_ result: Result<AgentPrincipalValidity?, any Error>) {
        let pending = continuation.withLock { value in
            let current = value
            value = nil
            return current
        }
        pending?.resume(with: result)
    }
}

private final class HostPreparePending: Sendable {
    private let continuation: Mutex<CheckedContinuation<HostPrepareResponseDTO, any Error>?>
    init(_ value: CheckedContinuation<HostPrepareResponseDTO, any Error>) {
        continuation = Mutex(value)
    }
    func finish(_ result: Result<HostPrepareResponseDTO, any Error>) {
        let pending = continuation.withLock { value in
            let current = value
            value = nil
            return current
        }
        pending?.resume(with: result)
    }
}

/// Once-resume guard for the redeem reverse-RPC: whichever of the reply
/// handler or the timeout fires first wins; the loser is dropped. Internal
/// for the resume-once unit test.
final class HostRedeemPending: Sendable {
    private let continuation: Mutex<CheckedContinuation<HostRedeemResponseDTO, any Error>?>
    init(_ value: CheckedContinuation<HostRedeemResponseDTO, any Error>) {
        continuation = Mutex(value)
    }
    func finish(_ result: Result<HostRedeemResponseDTO, any Error>) {
        let pending = continuation.withLock { value in
            let current = value
            value = nil
            return current
        }
        pending?.resume(with: result)
    }
}
#endif
