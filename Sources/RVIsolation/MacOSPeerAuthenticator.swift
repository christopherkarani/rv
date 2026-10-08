#if os(macOS)
import Foundation
import Security
@preconcurrency import XPC

public enum MacOSPeerAuthenticator {
    /// Call synchronously on each received message, before crossing a Task boundary.
    /// Role validation uses the message's audit-bound SecCode, never a PID lookup.
    public static func capture(
        message: xpc_object_t, connectionID: UUID,
        trust: ProtectedPeerTrustConfiguration = .denyAll
    ) throws -> AuthenticatedPeer {
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY,
              let connection = xpc_dictionary_get_remote_connection(message) else {
            throw PeerAuthenticationError.missingPeerEvidence
        }
        var code: SecCode?
        let result = SecCodeCreateWithXPCMessage(message, [], &code)
        guard result == errSecSuccess, let code else { throw PeerAuthenticationError.codeLookup(result) }
        // Connection PID/EUID are diagnostic labels; only the message-derived code
        // participates in component-role checks. No principal is derived from them.
        let evidence = try MacOSPeerCodeVerifier.capture(code: code,
            processID: xpc_connection_get_pid(connection),
            effectiveUserID: xpc_connection_get_euid(connection), trust: trust)
        return AuthenticatedPeer(evidence: evidence, connectionID: connectionID)
    }
}
#endif
