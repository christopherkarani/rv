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

extension ProtectedPeerTrustConfiguration.HookTrustSource {
    /// Would an installed manifest grant `role` to the binary at `path`?
    /// Same rule as `evaluateDaemon(atPath:)`, for any component. Nil when
    /// no valid manifest is installed (the sibling pin only covers rvd, and
    /// an invalid manifest has its own doctor row) or the manifest has no
    /// entry for `role`. Diagnostic only: it never grants or widens trust.
    public func evaluateRole(_ role: TrustedRVComponentRole, atPath path: String) -> DaemonTrustVerdict? {
        guard case .manifest(let trust) = self, trust.configuredRoles.contains(role) else { return nil }
        return trust.evaluate(role: role, atPath: path)
    }
}

extension TrustedRVComponentRole {
    /// The installed executable that holds this role, as messages name it.
    var binaryName: String {
        switch self {
        case .service: "rvd"
        case .cli: "rv-cli"
        case .workspaceHost: "rv-workspace-host"
        case .operatorUI: "rv-operator-ui"
        case .mcpCustodian: "rv-mcp-custodian"
        }
    }
}

extension ProtectedPeerTrustConfiguration {
    func evaluateDaemon(atPath path: String) -> DaemonTrustVerdict {
        guard entries.contains(where: { $0.role == .service }) else {
            return DaemonTrustVerdict(
                source: .manifest, satisfied: false,
                reason: "manifest grants no service role, so hooks reject every rvd")
        }
        return evaluate(role: .service, atPath: path)
    }

    /// The on-disk bytes at `path` against `role`'s entry. The caller
    /// checked the entry exists.
    func evaluate(role: TrustedRVComponentRole, atPath path: String) -> DaemonTrustVerdict {
        func rejected(_ reason: String) -> DaemonTrustVerdict {
            DaemonTrustVerdict(source: .manifest, satisfied: false, reason: reason)
        }
        guard let entry = entries.first(where: { $0.role == role }) else {
            return rejected("manifest grants no \(role.rawValue) role")
        }
        let binary = role.binaryName
        let requires = Self.requirementText(entry, binary: binary)
        // The live peer's executable path is canonical; match it.
        let canonical = posixRealpath(path) ?? path
        var created: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: canonical) as CFURL, [], &created) == errSecSuccess,
              let staticCode = created,
              SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess,
              let identity = try? MacOSPeerCodeVerifier.identity(fromStaticCode: staticCode).identity else {
            return rejected("\(requires); installed \(binary) has no valid code signature")
        }
        // Only this role's entry decides (C `has_service_role` for rvd):
        // another role's entry that also matches must not shadow it.
        if restricted(to: role).role(identity: identity, satisfies: {
            SecStaticCodeCheckValidity(staticCode, [], $0) == errSecSuccess
        }) == role {
            return DaemonTrustVerdict(source: .manifest, satisfied: true, reason: nil)
        }
        return rejected("\(requires); installed \(binary) \(Self.describe(identity, against: entry))")
    }

    private static func requirementText(_ entry: Entry, binary: String) -> String {
        if let hash = entry.developmentCDHash {
            return "manifest pins \(binary) cdhash \(hash.lowercased()) at \(entry.developmentExecutablePath ?? "?")"
        }
        return "manifest requires Developer ID \(entry.requiredIdentifier ?? "?") (team \(entry.requiredTeamIdentifier ?? "?"))"
    }

    /// The facts of `identity` that the entry rejects, most fundamental first.
    private static func describe(_ identity: PeerCodeIdentity, against entry: Entry) -> String {
        var facts: [String] = []
        if entry.developmentCDHash != nil {
            let hash = identity.cdHash.map { String(format: "%02x", $0) }.joined()
            var fact = "is cdhash \(hash) at \(identity.executablePath)"
            // A team-signed build cannot match a cdhash pin; name its
            // signer so the manifest can pin it by Developer ID instead.
            if identity.isAdHoc == false, let team = identity.teamIdentifier {
                fact += " (signed as \(identity.identifier), team \(team))"
            }
            facts.append(fact)
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
