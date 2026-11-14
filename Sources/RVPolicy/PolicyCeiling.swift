import Foundation
import RVDomain

public enum PolicyCeilingError: Error, Sendable, Equatable {
    /// `ceiling.toml` exists but cannot be read or parsed. Every check
    /// against it is refused (fail closed), never skipped.
    case invalidFile
    /// A policy layer or document states a weaker verdict than the ceiling.
    case exceeds(PolicyContainmentWitness)
    /// Containment could not be decided; treated as exceeding.
    case indeterminate(String)
    /// An egress approval names a host the ceiling does not allow.
    case egressExceeds(PolicyCeilingEgressWitness)

    /// One line for refusal messages. Untrusted text is display-escaped.
    public var refusal: String {
        switch self {
        case .invalidFile:
            return "the policy ceiling (ceiling.toml) is invalid"
        case .exceeds(let witness):
            return PolicyCeiling.describe(witness)
        case .indeterminate(let reason):
            return "containment in the policy ceiling is indeterminate: \(DisplayedText.field(reason))"
        case .egressExceeds(let witness):
            return "\(witness.command) exceeds the policy ceiling (egress.hosts does not allow \(DisplayedText.field(witness.host)))"
        }
    }
}

/// A concrete connection the ceiling forbids.
public struct PolicyCeilingEgressWitness: Sendable, Equatable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    public var command: String {
        "CONNECT \(DisplayedText.field(host)):\(port)"
    }
}

/// The owner's never-exceed bound, kept in `~/.config/rv/ceiling.toml`.
///
/// Rules are `deny` or `ask` typed rules in the `policy.toml` dialect: no
/// policy layer, shared document, or saved draft may state a weaker verdict
/// on any action they match (`PolicyContainment`). `egress.hosts`, when
/// present, is the most egress approvals may ever add: an approval for a
/// host outside it is refused. Absent, the ceiling does not bound egress;
/// present and empty, it allows no egress approval at all.
public struct PolicyCeiling: Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let maximumBytes = 256 * 1024

    public var rules: [PolicyDocumentRule]
    /// Exact hosts (`github.com`) or one-level-or-deeper subdomain
    /// wildcards (`*.github.com`, which does not match `github.com`).
    /// Canonical lowercase. Nil when the ceiling does not bound egress.
    public var egressHosts: [String]?

    public init(rules: [PolicyDocumentRule] = [], egressHosts: [String]? = nil) {
        self.rules = rules
        self.egressHosts = egressHosts
    }

    public var typedRules: [TypedRule] {
        rules.map { $0.typedRule(origin: .machine) }
    }

    /// Containment of one layer's rules. Statements only: rules the
    /// document leaves out never exceed.
    public func check(_ document: PolicyDocument) -> PolicyContainmentResult {
        PolicyContainment.check(candidate: document.typedRules(origin: .repo), ceiling: typedRules)
    }

    /// Throws `exceeds` or `indeterminate` unless `document` is contained.
    public func requireContained(_ document: PolicyDocument) throws {
        switch check(document) {
        case .contained:
            return
        case .exceeds(let witness):
            throw PolicyCeilingError.exceeds(witness)
        case .indeterminate(let reason):
            throw PolicyCeilingError.indeterminate(reason)
        }
    }

    /// Nil when the connection is within the ceiling.
    public func egressWitness(host: String, port: Int) -> PolicyCeilingEgressWitness? {
        guard let egressHosts else { return nil }
        let witness = PolicyCeilingEgressWitness(host: host, port: port)
        // A host that does not canonicalize can match no pattern: refuse.
        guard let canonical = LiveNetworkRule(host: host, port: port)?.host else { return witness }
        let allowed = egressHosts.contains { pattern in
            if pattern.hasPrefix("*.") {
                return canonical.hasSuffix(String(pattern.dropFirst()))
            }
            return canonical == pattern
        }
        return allowed ? nil : PolicyCeilingEgressWitness(host: canonical, port: port)
    }

    /// Throws `egressExceeds` unless the connection is within the ceiling.
    public func requireEgress(host: String, port: Int) throws {
        if let witness = egressWitness(host: host, port: port) {
            throw PolicyCeilingError.egressExceeds(witness)
        }
    }

    public static func describe(_ witness: PolicyContainmentWitness) -> String {
        "\(witness.command) exceeds the policy ceiling: rule \(DisplayedText.field(witness.candidateRule.rawValue))"
            + " says \(witness.candidateVerdict.rawValue), ceiling rule"
            + " \(DisplayedText.field(witness.ceilingRule.rawValue)) says \(witness.ceilingVerdict.rawValue)"
    }
}

/// `ceiling.toml`: `schema_version`, optional `egress.hosts`, then
/// `[[rule]]` blocks parsed by `PolicyDocumentTOML`. Strict: unknown keys,
/// `allow` rules, `safety.level`, and `secret.allow_paths` are errors, so a
/// typo cannot silently widen the bound.
public enum PolicyCeilingTOML {
    public static func parse(_ text: String) throws -> PolicyCeiling {
        var preamble: [Substring] = []
        var body: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if body.isEmpty, line.trimmingCharacters(in: .whitespaces) != "[[rule]]" {
                preamble.append(line)
            } else {
                body.append(line)
            }
        }
        var schemaVersion: Int?
        var egressHosts: [String]?
        for line in preamble {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { throw PolicyCeilingError.invalidFile }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            let raw = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "schema_version":
                guard schemaVersion == nil, Int(parseTOMLString(raw)) == PolicyCeiling.currentSchemaVersion else {
                    throw PolicyCeilingError.invalidFile
                }
                schemaVersion = PolicyCeiling.currentSchemaVersion
            case "egress.hosts":
                guard egressHosts == nil else { throw PolicyCeilingError.invalidFile }
                guard let values = try? PolicyDocumentTOML.parseTOMLStringArray(raw) else {
                    throw PolicyCeilingError.invalidFile
                }
                egressHosts = try values.map(canonicalHostPattern)
            default:
                throw PolicyCeilingError.invalidFile
            }
        }
        guard schemaVersion != nil else { throw PolicyCeilingError.invalidFile }
        let document: PolicyDocument
        do {
            document = try PolicyDocumentTOML.parse(
                "schema_version = \(PolicyCeiling.currentSchemaVersion)\n" + body.joined(separator: "\n"))
        } catch {
            throw PolicyCeilingError.invalidFile
        }
        guard document.rules.allSatisfy({ $0.verdict != .allow }) else { throw PolicyCeilingError.invalidFile }
        return PolicyCeiling(rules: document.rules, egressHosts: egressHosts)
    }

    public static func render(_ ceiling: PolicyCeiling) -> String {
        var lines = ["schema_version = \(PolicyCeiling.currentSchemaVersion)"]
        if let hosts = ceiling.egressHosts {
            lines.append("egress.hosts = [\(hosts.map { "\"\(escapeTOMLDisplayed($0))\"" }.joined(separator: ", "))]")
        }
        let rules = PolicyDocumentTOML.render(PolicyDocument(rules: ceiling.rules))
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropFirst()
        return lines.joined(separator: "\n") + "\n" + rules.joined(separator: "\n")
    }

    /// `host` or `*.host`, canonicalized like a live network rule. Anything
    /// else (`*`, `*github.com`, IP literals, ports) is invalid.
    static func canonicalHostPattern(_ raw: String) throws -> String {
        let wildcard = raw.hasPrefix("*.")
        let host = wildcard ? String(raw.dropFirst(2)) : raw
        guard let canonical = LiveNetworkRule(host: host, port: 443)?.host else {
            throw PolicyCeilingError.invalidFile
        }
        return wildcard ? "*." + canonical : canonical
    }
}

/// Load and save of `ceiling.toml` in one config directory.
public struct PolicyCeilingStore: Sendable {
    public var configDirectory: URL

    public init(configDirectory: URL) {
        self.configDirectory = configDirectory
    }

    public var fileURL: URL {
        RVPolicyPaths.policyCeilingFile(inConfigDir: configDirectory)
    }

    /// Nil when no ceiling is set. A file that exists but cannot be read or
    /// parsed throws `invalidFile`: callers refuse, never skip the check.
    public func load() throws -> PolicyCeiling? {
        let path = fileURL.path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let data = try? Data(contentsOf: fileURL), data.count <= PolicyCeiling.maximumBytes,
            let text = String(data: data, encoding: .utf8)
        else {
            throw PolicyCeilingError.invalidFile
        }
        return try PolicyCeilingTOML.parse(text)
    }

    /// Owner-only atomic replace. Callers confirm the device owner first,
    /// the same gate as a machine `policy.toml` save.
    public func save(_ ceiling: PolicyCeiling) throws {
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configDirectory.path)
        let data = Data(PolicyCeilingTOML.render(ceiling).utf8)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
