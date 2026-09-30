import Foundation
import RVIsolation

/// Platform evidence remains distinct from agent binding and owner authorization.
public struct AuthenticatedPeer: Sendable, Equatable {
    public let evidence: PlatformPeerEvidence
    public let connectionID: UUID
    public var componentRole: TrustedRVComponentRole? { evidence.componentRole }

    init(evidence: PlatformPeerEvidence, connectionID: UUID) {
        self.evidence = evidence
        self.connectionID = connectionID
    }
}
