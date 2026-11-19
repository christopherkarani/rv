import Foundation
import RVIsolation

/// Who may talk to whom on `dev.rv.judge`, with the exact mechanisms rvd's
/// hook-consult path uses (`XPCEvaluateClient.verifyDaemon`):
///
/// - An installed peer-trust manifest always wins. The supervisor accepts
///   only a peer holding the manifest `service` role (rvd); rvd accepts only
///   a supervisor holding the `judge` role. A manifest WITHOUT a `judge`
///   entry therefore leaves rvd unable to verify any supervisor: the judge
///   is unreachable and every judged call goes to review (fail closed),
///   never to an unjudged allow. `rv doctor` reports it.
/// - No manifest (one-click install): each side pins the other to the
///   exact on-disk sibling bytes (same canonical path, same CDHash) and the
///   same effective uid — `rvd` next to `rv-judge`, and the reverse.
/// - A manifest that exists but fails validation is tamper evidence:
///   reject everything.
public enum JudgePoolPeerDecision {
    public enum Source: Sendable, Equatable {
        case manifest
        case siblingPin
        case invalid
    }

    /// The decision, with every fact about the peer already established.
    /// `role` is the manifest role the peer's live code satisfies (only
    /// meaningful for `.manifest`).
    public static func allows(
        source: Source,
        peerRole: TrustedRVComponentRole?,
        requiredRole: TrustedRVComponentRole,
        sameUser: Bool,
        matchesSibling: Bool
    ) -> Bool {
        switch source {
        case .manifest: peerRole == requiredRole
        case .siblingPin: sameUser && matchesSibling
        case .invalid: false
        }
    }
}

#if canImport(XPC)
import Darwin
@preconcurrency import XPC

public enum JudgePoolTrust {
    /// Supervisor side: may the sender of `message` use the pool?
    public static func authorizeClient(message: xpc_object_t, siblingClientPath: String?) -> Bool {
        verify(message, requiredRole: .service, siblingPath: siblingClientPath)
    }

    /// rvd side: did the genuine supervisor send `reply`?
    public static func verifySupervisor(reply: xpc_object_t, siblingSupervisorPath: String?) -> Bool {
        verify(reply, requiredRole: .judge, siblingPath: siblingSupervisorPath)
    }

    /// `name` beside the running executable (install layout), or nil.
    public static func siblingPath(_ name: String) -> String? {
        var capacity = UInt32(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: Int(capacity))
        guard _NSGetExecutablePath(&buffer, &capacity) == 0 else { return nil }
        let directory = (String(cString: buffer) as NSString).deletingLastPathComponent
        guard !directory.isEmpty else { return nil }
        return (directory as NSString).appendingPathComponent(name)
    }

    private static func verify(
        _ message: xpc_object_t, requiredRole: TrustedRVComponentRole, siblingPath: String?
    ) -> Bool {
        switch ProtectedPeerTrustConfiguration.hookTrustSource() {
        case .manifest(let trust):
            let peer = try? MacOSPeerAuthenticator.capture(message: message, connectionID: UUID(), trust: trust)
            return JudgePoolPeerDecision.allows(
                source: .manifest, peerRole: peer?.componentRole, requiredRole: requiredRole,
                sameUser: false, matchesSibling: false)
        case .siblingPin:
            guard let siblingPath,
                  let peer = try? MacOSPeerAuthenticator.capture(message: message, connectionID: UUID(), trust: .denyAll)
            else { return false }
            return JudgePoolPeerDecision.allows(
                source: .siblingPin, peerRole: nil, requiredRole: requiredRole,
                sameUser: peer.evidence.effectiveUserID == geteuid(),
                matchesSibling: MacOSPeerCodeVerifier.matches(peer: peer.evidence.codeIdentity, path: siblingPath))
        case .invalid:
            return false
        }
    }
}
#endif
