import Foundation
@testable import RVIsolation
@testable import RVService

/// Kernel-attested-peer fixture for consult dispatch. Role is nil on
/// purpose: one-click installs have no admin trust manifest, and consult
/// confers no authority, so the gate needs peer presence only.
func peerHookContext() -> AuthenticatedRequestContext {
    let code = PeerCodeIdentity(
        identifier: "peer-hook-fixture",
        teamIdentifier: nil,
        cdHash: Data([7]),
        executablePath: "/peer-hook-fixture",
        isAdHoc: true,
        hardenedRuntime: true,
        injectionExceptions: []
    )
    let peer = AuthenticatedPeer(
        evidence: PlatformPeerEvidence(
            processID: 4242,
            effectiveUserID: 501,
            auditToken: Data([7]),
            codeIdentity: code,
            componentRole: nil
        ),
        connectionID: UUID()
    )
    return .captured(peer: peer, connectionID: UUID())
}

/// Pinned genuine-CLI peer for TTY attestation dispatch. The role is the
/// trust anchor the daemon's matrix requires for `attestTTYRedemption`.
func peerCliContext() -> AuthenticatedRequestContext {
    let code = PeerCodeIdentity(
        identifier: "peer-cli-fixture",
        teamIdentifier: nil,
        cdHash: Data([12]),
        executablePath: "/peer-cli-fixture",
        isAdHoc: true,
        hardenedRuntime: true,
        injectionExceptions: []
    )
    let peer = AuthenticatedPeer(
        evidence: PlatformPeerEvidence(
            processID: 4244,
            effectiveUserID: 501,
            auditToken: Data([12]),
            codeIdentity: code,
            componentRole: .cli
        ),
        connectionID: UUID()
    )
    return .captured(peer: peer, connectionID: UUID())
}

/// Operator-UI peer: even the trusted UI cannot mint TTY attestations.
func peerOperatorUIContext() -> AuthenticatedRequestContext {
    let code = PeerCodeIdentity(
        identifier: "peer-ui-fixture",
        teamIdentifier: nil,
        cdHash: Data([13]),
        executablePath: "/peer-ui-fixture",
        isAdHoc: true,
        hardenedRuntime: true,
        injectionExceptions: []
    )
    let peer = AuthenticatedPeer(
        evidence: PlatformPeerEvidence(
            processID: 4245,
            effectiveUserID: 501,
            auditToken: Data([13]),
            codeIdentity: code,
            componentRole: .operatorUI
        ),
        connectionID: UUID()
    )
    return .captured(peer: peer, connectionID: UUID())
}

/// Service-role peer for control-read dispatch (`pendingList`,
/// `pendingWatch`, `rulePreview`).
func peerServiceContext() -> AuthenticatedRequestContext {
    let code = PeerCodeIdentity(
        identifier: "peer-service-fixture",
        teamIdentifier: nil,
        cdHash: Data([9]),
        executablePath: "/peer-service-fixture",
        isAdHoc: true,
        hardenedRuntime: true,
        injectionExceptions: []
    )
    let peer = AuthenticatedPeer(
        evidence: PlatformPeerEvidence(
            processID: 4243,
            effectiveUserID: 501,
            auditToken: Data([9]),
            codeIdentity: code,
            componentRole: .service
        ),
        connectionID: UUID()
    )
    return .captured(peer: peer, connectionID: UUID())
}
