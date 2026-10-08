import Foundation

/// Platform evidence remains distinct from agent binding and owner authorization.
public struct AuthenticatedPeer: Sendable, Equatable {
    public let evidence: PlatformPeerEvidence
    public let connectionID: UUID
    public var componentRole: TrustedRVComponentRole? { evidence.componentRole }

    init(evidence: PlatformPeerEvidence, connectionID: UUID) {
        self.evidence = evidence
        self.connectionID = connectionID
    }

    /// Role-less peer for a kernel-attested same-user socket connection
    /// (Linux SO_PEERCRED). Mirrors `MacOSPeerAuthenticator.capture` minus
    /// code identity: hook consult works, role-gated methods stay denied.
    public static func socketPeer(
        processID: Int32, effectiveUserID: UInt32, connectionID: UUID
    ) -> AuthenticatedPeer {
        AuthenticatedPeer(
            evidence: .socketPeer(processID: processID, effectiveUserID: effectiveUserID),
            connectionID: connectionID
        )
    }
}
