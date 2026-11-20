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

/// What an authorized peer may ask the supervisor.
public enum JudgePoolClient: Sendable, Equatable {
    /// rvd: every request.
    case service
    /// `rv-hook-local`, the hook-local evaluator: hello and judge only.
    /// It cannot warm (and so switch) the model or read the pool's status.
    case evaluator
}

#if canImport(XPC)
import Darwin
import Security
@preconcurrency import XPC

public enum JudgePoolTrust {
    /// What `decide` needs to know about one peer, established from the
    /// message's own audit token.
    struct PeerFacts: Sendable, Equatable {
        /// The manifest role its live code satisfies (manifest source only).
        var role: TrustedRVComponentRole?
        var sameUser: Bool
        /// Its live code is the exact on-disk sibling (sibling source only).
        var matchesSibling: Bool
        /// Its live code is the release-signed hook-local evaluator the
        /// manifest's service entry implies (manifest source only).
        var isHookEvaluator = false
    }

    /// Learns the facts about the sender of a message under `trust`,
    /// checking against `siblingPath` when one is given. Nil: the sender
    /// could not be authenticated at all.
    typealias FactFinder = (ProtectedPeerTrustConfiguration, _ siblingPath: String?) -> PeerFacts?

    /// Supervisor side: may the sender of `message` use the pool, and as
    /// which client? `siblingClientPath` is rvd's sibling, and
    /// `siblingEvaluatorPath` rv-hook-local's (sibling pin only).
    public static func authorizeClient(
        message: xpc_object_t, siblingClientPath: String?, siblingEvaluatorPath: String?
    ) -> JudgePoolClient? {
        authorizeClient(
            source: ProtectedPeerTrustConfiguration.hookTrustSource(), siblingClientPath: siblingClientPath,
            siblingEvaluatorPath: siblingEvaluatorPath,
            facts: { facts(of: message, trust: $0, siblingPath: $1) })
    }

    /// rvd side: did the genuine supervisor send `reply`?
    public static func verifySupervisor(reply: xpc_object_t, siblingSupervisorPath: String?) -> Bool {
        verifySupervisor(
            source: ProtectedPeerTrustConfiguration.hookTrustSource(), siblingSupervisorPath: siblingSupervisorPath,
            facts: { facts(of: reply, trust: $0, siblingPath: $1) })
    }

    /// The service role (or rvd's sibling bytes) is the full client; the
    /// hook-local evaluator (derived from the manifest's service entry, or
    /// rv-hook-local's sibling bytes) is the judge-only client.
    static func authorizeClient(
        source: ProtectedPeerTrustConfiguration.HookTrustSource, siblingClientPath: String?,
        siblingEvaluatorPath: String?, facts: FactFinder
    ) -> JudgePoolClient? {
        switch source {
        case .manifest(let trust):
            guard let peer = facts(trust, nil) else { return nil }
            if peer.role == .service { return .service }
            return peer.isHookEvaluator ? .evaluator : nil
        case .siblingPin:
            if decide(source: source, requiredRole: .service, siblingPath: siblingClientPath, facts: facts) {
                return .service
            }
            guard let siblingEvaluatorPath else { return nil }
            return decide(source: source, requiredRole: .service, siblingPath: siblingEvaluatorPath, facts: facts)
                ? .evaluator : nil
        case .invalid:
            return nil
        }
    }

    static func verifySupervisor(
        source: ProtectedPeerTrustConfiguration.HookTrustSource, siblingSupervisorPath: String?, facts: FactFinder
    ) -> Bool {
        decide(source: source, requiredRole: .judge, siblingPath: siblingSupervisorPath, facts: facts)
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

    static func decide(
        source: ProtectedPeerTrustConfiguration.HookTrustSource, requiredRole: TrustedRVComponentRole,
        siblingPath: String?, facts: FactFinder
    ) -> Bool {
        switch source {
        case .manifest(let trust):
            return JudgePoolPeerDecision.allows(
                source: .manifest, peerRole: facts(trust, nil)?.role, requiredRole: requiredRole,
                sameUser: false, matchesSibling: false)
        case .siblingPin:
            guard let siblingPath, let peer = facts(.denyAll, siblingPath) else { return false }
            return JudgePoolPeerDecision.allows(
                source: .siblingPin, peerRole: nil, requiredRole: requiredRole,
                sameUser: peer.sameUser, matchesSibling: peer.matchesSibling)
        case .invalid:
            return false
        }
    }

    /// On-disk sibling code hashes, recomputed only when the file changes.
    static let siblingHashes = CodeHashCache { path in
        (try? MacOSPeerCodeVerifier.staticIdentity(ofPath: path))?.cdHash
    }

    /// The facts about the sender of `message`, from its own audit-bound
    /// code, as `MacOSPeerAuthenticator.capture` establishes them.
    private static func facts(of message: xpc_object_t, trust: ProtectedPeerTrustConfiguration, siblingPath: String?)
        -> PeerFacts? {
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY,
              let connection = xpc_dictionary_get_remote_connection(message) else { return nil }
        var live: SecCode?
        guard SecCodeCreateWithXPCMessage(message, [], &live) == errSecSuccess, let live,
              let evidence = try? MacOSPeerCodeVerifier.capture(
                code: live, processID: xpc_connection_get_pid(connection),
                effectiveUserID: xpc_connection_get_euid(connection), trust: trust)
        else { return nil }
        let code = evidence.codeIdentity
        return PeerFacts(
            role: evidence.componentRole,
            sameUser: evidence.effectiveUserID == geteuid(),
            matchesSibling: siblingPath.map { isSibling(code, at: $0) } ?? false,
            isHookEvaluator: trust.isHookEvaluator(code: live, identity: code))
    }

    /// The live peer is the exact bytes at `path`: same canonical path,
    /// same CDHash (MacOSPeerCodeVerifier.matches, with the on-disk hash
    /// cached by file identity).
    static func isSibling(_ code: PeerCodeIdentity, at path: String) -> Bool {
        guard !code.cdHash.isEmpty,
              let peerPath = canonical(code.executablePath), let expected = canonical(path), peerPath == expected,
              let onDisk = siblingHashes.hash(ofPath: expected) else { return false }
        return code.cdHash == onDisk
    }

    /// The CDHash of the code this process is running, or nil when it
    /// cannot be read.
    public static func runningCodeHash() -> Data? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              let evidence = try? MacOSPeerCodeVerifier.capture(
                code: code, processID: getpid(), effectiveUserID: geteuid())
        else { return nil }
        return evidence.codeIdentity.cdHash.isEmpty ? nil : evidence.codeIdentity.cdHash
    }

    private static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
#endif
