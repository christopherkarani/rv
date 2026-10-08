import Foundation

/// Executable characteristics an Agent Definition requires of its workload.
///
/// RV-controlled launch facts are checked against these requirements.
/// An executable path alone never satisfies a requirement.
public struct ExecutableRequirement: Hashable, Sendable, Equatable, Codable {
    /// Required SHA-256 content digest as lowercase hex, when pinned.
    public let expectedContentDigestSHA256: String?
    /// Required platform signing Team ID, when signing is required.
    public let requiredTeamID: String?
    /// Required designated/explicit code requirement, when applicable.
    public let requiredCodeRequirement: String?
    /// Whether ad-hoc/unsigned workloads are accepted. Unsigned launches
    /// must opt in here; they never pretend to a signing identity.
    public let allowsUnsigned: Bool

    public init(
        expectedContentDigestSHA256: String? = nil,
        requiredTeamID: String? = nil,
        requiredCodeRequirement: String? = nil,
        allowsUnsigned: Bool = false
    ) {
        // Canonicalize to the lowercase-hex form every digest check
        // requires, so a case-variant pin still matches instead of
        // silently never matching. Form validation stays at the trust
        // boundaries (operator-config load, intent, snapshot).
        self.expectedContentDigestSHA256 = expectedContentDigestSHA256?.lowercased()
        self.requiredTeamID = requiredTeamID
        self.requiredCodeRequirement = requiredCodeRequirement
        self.allowsUnsigned = allowsUnsigned
    }
}

/// Strength of the executable binding RV established for one launch.
///
/// v1 reports only what RV can honestly claim today: either no evidence
/// was established, or RV observed a launch it controls without verifying
/// content or signing. No stronger level exists here; claiming strong
/// attestation without proof is forbidden.
public enum ExecutableAssurance: String, Hashable, Sendable, Equatable, Codable, CaseIterable {
    /// No executable evidence was established.
    case unattested
    /// Weak: RV spawned and observed the launch but verified neither
    /// content nor signing. Policy decides whether that suffices.
    case launchObserved
}

/// Delegable authority snapshot: a set of scope names.
///
/// Canonical form is unique scopes sorted in UTF-8 byte order, so the form
/// is stable across runs and platforms. Narrowing is subset inclusion:
/// `contains(_:)` reports whether `other` fits within this authority.
public struct AgentAuthority: Hashable, Sendable, Equatable, Codable {
    public let scopes: [String]

    public init(scopes: [String]) {
        self.scopes = Array(Set(scopes)).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    public static let none = AgentAuthority(scopes: [])

    /// True when every scope in `other` is also in this authority.
    public func contains(_ other: AgentAuthority) -> Bool {
        let mine = Set(scopes)
        for scope in other.scopes {
            if mine.contains(scope) == false {
                return false
            }
        }
        return true
    }
}

/// Stable operator-controlled description of what RV intends to run.
///
/// The definition is stable across process launches. Security-relevant
/// content feeds `AgentDefinitionRevision`; display-only text does not.
public struct AgentDefinition: Sendable, Equatable, Codable {
    public let id: AgentDefinitionID
    /// Display-only. Excluded from the revision digest.
    public let displayName: String
    /// Display-only. Excluded from the revision digest.
    public let blurb: String
    public let executableRequirement: ExecutableRequirement
    /// Integration identity metadata, not a principal.
    public let hookHost: HookHost?
    /// Integration identity metadata, not a principal.
    public let agentTag: String?
    /// RESOLVED resource-profile state. The revision digests this content,
    /// not just the profile name, so a profile edit changes the revision.
    public let resourceProfile: RuntimeResourceProfile
    /// Permitted credential bindings. Names of bindings only; definitions
    /// carry no secret values, so none can leak into the digest.
    public let credentialBindings: [String]
    public let requiredAssurance: ExecutableAssurance
    /// Delegable authority ceiling for instances of this definition.
    public let authorityCeiling: AgentAuthority

    public init(
        id: AgentDefinitionID,
        displayName: String,
        blurb: String,
        executableRequirement: ExecutableRequirement,
        hookHost: HookHost?,
        agentTag: String?,
        resourceProfile: RuntimeResourceProfile,
        credentialBindings: [String],
        requiredAssurance: ExecutableAssurance,
        authorityCeiling: AgentAuthority
    ) {
        self.id = id
        self.displayName = displayName
        self.blurb = blurb
        self.executableRequirement = executableRequirement
        self.hookHost = hookHost
        self.agentTag = agentTag
        self.resourceProfile = resourceProfile
        self.credentialBindings = credentialBindings
        self.requiredAssurance = requiredAssurance
        self.authorityCeiling = authorityCeiling
    }
}

/// Immutable revision digest over the canonical security projection.
///
/// Any security-relevant definition change produces a different revision.
/// Display-only text and secret values are excluded: display fields never
/// enter the projection, and definitions carry bindings, never secrets.
public struct AgentDefinitionRevision: Hashable, Sendable, Equatable, Codable {
    /// SHA-256 of the canonical projection as 64 lowercase hex digits.
    public let digestHex: String

    /// Names a digest value. `resolve(_:)` is the honest constructor;
    /// naming a digest neither computes one nor grants anything.
    public init(digestHex: String) {
        self.digestHex = digestHex
    }

    public static func resolve(_ definition: AgentDefinition) -> AgentDefinitionRevision {
        AgentDefinitionRevision(digestHex: HTTPDigest.sha256Hex(canonicalProjection(definition)))
    }

    /// Canonical security projection. Explicit fixed field order and
    /// explicit length-prefixed framing; never relies on encoder key
    /// ordering. Field order is part of the contract:
    ///
    /// definition-id, executable (expected-digest, team-id,
    /// code-requirement, allows-unsigned), integration (hook-host,
    /// agent-tag), resource-profile (id, projects, agents,
    /// executable-links, read-files, read-trees, write-trees,
    /// credentials, environment, keychain), credential-bindings,
    /// required-assurance, authority-ceiling.
    ///
    /// Framing: ASCII field name, LF, decimal UTF-8 byte count, LF, raw
    /// bytes. Absent optionals encode as the field name followed by `-`.
    /// Order-insignificant lists sort byte-wise before encoding, with a
    /// leading element count and presence-tagged optionals so empty and
    /// absent values never collide with real ones.
    static func canonicalProjection(_ definition: AgentDefinition) -> [UInt8] {
        var out: [UInt8] = []
        appendField(&out, name: "version", value: "rv-agent-definition-revision/v1")
        appendField(&out, name: "definition-id", value: definition.id.rawValue)
        let exe = definition.executableRequirement
        appendOptional(&out, name: "executable.expected-digest", value: exe.expectedContentDigestSHA256)
        appendOptional(&out, name: "executable.team-id", value: exe.requiredTeamID)
        appendOptional(&out, name: "executable.code-requirement", value: exe.requiredCodeRequirement)
        appendField(&out, name: "executable.allows-unsigned", value: exe.allowsUnsigned ? "1" : "0")
        appendOptional(&out, name: "integration.hook-host", value: definition.hookHost?.rawValue)
        appendOptional(&out, name: "integration.agent-tag", value: definition.agentTag)
        appendField(&out, name: "resource-profile", value: canonicalResourceProfile(definition.resourceProfile))
        appendList(&out, name: "credential-bindings", values: definition.credentialBindings)
        appendField(&out, name: "required-assurance", value: definition.requiredAssurance.rawValue)
        appendList(&out, name: "authority-ceiling", values: definition.authorityCeiling.scopes)
        return out
    }

    static func canonicalResourceProfile(_ profile: RuntimeResourceProfile) -> String {
        var parts: [String] = []
        parts.append("id=" + escape(profile.id))
        parts.append("projects=" + canonicalStrings(profile.projects))
        parts.append("agents=" + canonicalStrings(profile.agents))
        parts.append(
            "executable-links="
                + canonicalStrings(profile.executableLinks.map { escape($0.name) + "\u{0}" + escape($0.target) })
        )
        parts.append("read-files=" + canonicalStrings(profile.readFiles))
        parts.append("read-trees=" + canonicalStrings(profile.readTrees))
        parts.append("write-trees=" + canonicalStrings(profile.writeTrees))
        parts.append(
            "credentials="
                + canonicalStrings(
                    profile.credentials.map {
                        escape($0.source) + "\u{0}" + escape($0.destination) + "\u{0}"
                            + canonicalStrings($0.agents ?? [])
                    }
                )
        )
        parts.append(
            "environment="
                + canonicalStrings(
                    profile.environment.map {
                        escape($0.name) + "\u{0}" + canonicalOptional($0.hostVariable) + "\u{0}"
                            + canonicalOptional($0.literalValue)
                    }
                )
        )
        parts.append(
            "keychain="
                + canonicalStrings(
                    profile.keychain.map {
                        escape($0.service) + "\u{0}" + escape($0.account) + "\u{0}"
                            + canonicalOptional($0.field) + "\u{0}" + escape($0.env) + "\u{0}"
                            + canonicalStrings($0.agents ?? [])
                    }
                )
        )
        return parts.joined(separator: "\n")
    }

    static func canonicalStrings(_ values: [String]) -> String {
        // Element count first: without it an empty list and a list holding
        // one empty string would both encode as "".
        String(values.count) + ":"
            + values.map(escape).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.joined(separator: ",")
    }

    /// Absent optionals encode as "0"; present values as "1:" plus the
    /// escaped value, so nil never collides with a literal value.
    static func canonicalOptional(_ value: String?) -> String {
        value.map { "1:" + escape($0) } ?? "0"
    }

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "=", with: "\\=")
            .replacingOccurrences(of: "\u{0}", with: "\\0")
    }

    static func appendField(_ out: inout [UInt8], name: String, value: String) {
        let bytes = Array(value.utf8)
        out.append(contentsOf: Array(name.utf8))
        out.append(0x0a)
        out.append(contentsOf: Array(String(bytes.count).utf8))
        out.append(0x0a)
        out.append(contentsOf: bytes)
        out.append(0x0a)
    }

    static func appendOptional(_ out: inout [UInt8], name: String, value: String?) {
        if let value {
            appendField(&out, name: name, value: "1\n" + value)
        } else {
            appendField(&out, name: name, value: "-")
        }
    }

    static func appendList(_ out: inout [UInt8], name: String, values: [String]) {
        appendField(&out, name: name, value: canonicalStrings(values))
    }
}
