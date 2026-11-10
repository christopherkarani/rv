#if os(macOS)
import Foundation
import Security

/// Would the hooks trust the `rvd` at a path? Evaluated on its on-disk bytes
/// with the exact rule the hook-consult client applies to the live daemon,
/// so setup and doctor can say why before every tool call is denied.
/// Diagnostic only: it never grants or widens trust.
public struct DaemonTrustVerdict: Sendable, Equatable {
    public enum Source: String, Sendable {
        case manifest
        case siblingPin = "sibling-pin"
        case invalid
    }

    public let source: Source
    public let satisfied: Bool
    /// Why the hooks would reject this rvd; nil when satisfied.
    public let reason: String?

    public init(source: Source, satisfied: Bool, reason: String?) {
        self.source = source
        self.satisfied = satisfied
        self.reason = reason
    }
}

extension ProtectedPeerTrustConfiguration.HookTrustSource {
    public func evaluateDaemon(atPath path: String) -> DaemonTrustVerdict {
        switch self {
        case .manifest(let trust):
            return trust.evaluateDaemon(atPath: path)
        case .siblingPin:
            // The live daemon must be these exact bytes; any valid signature
            // gives them a CDHash to pin.
            if let identity = try? MacOSPeerCodeVerifier.staticIdentity(ofPath: path), !identity.cdHash.isEmpty {
                return DaemonTrustVerdict(source: .siblingPin, satisfied: true, reason: nil)
            }
            return DaemonTrustVerdict(
                source: .siblingPin, satisfied: false,
                reason: "installed rvd has no valid code signature, so hooks cannot pin it")
        case .invalid:
            return DaemonTrustVerdict(
                source: .invalid, satisfied: false,
                reason: "trust manifest is present but rejected, so hooks reject every rvd")
        }
    }
}

extension ProtectedPeerTrustConfiguration {
    func evaluateDaemon(atPath path: String) -> DaemonTrustVerdict {
        func rejected(_ reason: String) -> DaemonTrustVerdict {
            DaemonTrustVerdict(source: .manifest, satisfied: false, reason: reason)
        }
        guard let entry = entries.first(where: { $0.role == .service }) else {
            return rejected("manifest grants no service role, so hooks reject every rvd")
        }
        let requires = Self.requirementText(entry)
        // The live daemon's executable path is canonical; match it.
        let canonical = posixRealpath(path) ?? path
        var created: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: canonical) as CFURL, [], &created) == errSecSuccess,
              let staticCode = created,
              SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess,
              let identity = try? MacOSPeerCodeVerifier.identity(fromStaticCode: staticCode).identity else {
            return rejected("\(requires); installed rvd has no valid code signature")
        }
        // Only the service entry decides (C `has_service_role`): another
        // role's entry that also matches must not shadow it.
        let role = restricted(to: .service).role(identity: identity) {
            SecStaticCodeCheckValidity(staticCode, [], $0) == errSecSuccess
        }
        if role == .service {
            return DaemonTrustVerdict(source: .manifest, satisfied: true, reason: nil)
        }
        return rejected("\(requires); installed rvd \(Self.describe(identity, against: entry))")
    }

    private static func requirementText(_ entry: Entry) -> String {
        if let hash = entry.developmentCDHash {
            return "manifest pins rvd cdhash \(hash.lowercased()) at \(entry.developmentExecutablePath ?? "?")"
        }
        return "manifest requires Developer ID \(entry.requiredIdentifier ?? "?") (team \(entry.requiredTeamIdentifier ?? "?"))"
    }

    /// The facts of `identity` that the entry rejects, most fundamental first.
    private static func describe(_ identity: PeerCodeIdentity, against entry: Entry) -> String {
        var facts: [String] = []
        if entry.developmentCDHash != nil {
            let hash = identity.cdHash.map { String(format: "%02x", $0) }.joined()
            facts.append("is cdhash \(hash) at \(identity.executablePath)")
        } else if identity.isAdHoc {
            facts.append("is ad-hoc signed")
        } else if identity.identifier != entry.requiredIdentifier || identity.teamIdentifier != entry.requiredTeamIdentifier {
            facts.append("is signed as \(identity.identifier) (team \(identity.teamIdentifier ?? "none"))")
        }
        if !identity.hardenedRuntime {
            facts.append("without hardened runtime")
        }
        if !identity.injectionExceptions.isEmpty {
            facts.append("with injection entitlements \(identity.injectionExceptions.sorted().joined(separator: ", "))")
        }
        guard let first = facts.first else { return "does not satisfy the manifest requirement" }
        let sentence = facts.joined(separator: ", ")
        return first.hasPrefix("is ") ? sentence : "is signed " + sentence
    }
}
#endif
