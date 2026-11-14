#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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
    /// `ceiling set` could not save. The reason says what is on disk.
    case writeFailed(String)

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
        case .writeFailed(let reason):
            return "could not save the policy ceiling: \(reason)"
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
/// Rules are `deny` or `ask` typed rules in the `policy.toml` dialect.
/// Evaluation overlays them last, restrict-only (`TypedRuleStore.merge`),
/// so they hold even where every layer is silent. Saves refuse a layer
/// that asks where the ceiling denies (`check`); a layer `allow` is a no-op
/// at evaluation, so one under the ceiling is only advisory (`advisory`).
/// `egress.hosts`, when
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

    /// Containment of the rules evaluation enforces (`deny`, `ask`) in one
    /// layer. Rules the document leaves out, and its `allow` rules (a no-op
    /// at evaluation), never exceed.
    public func check(_ document: PolicyDocument) -> PolicyContainmentResult {
        let enforced = document.typedRules(origin: .repo).filter { $0.verdict != .allow }
        return PolicyContainment.check(candidate: enforced, ceiling: typedRules)
    }

    /// The layer's `allow` rules against the ceiling. An exceeding witness
    /// here is advisory: evaluation ignores the allow and the ceiling holds.
    public func advisory(_ document: PolicyDocument) -> PolicyContainmentResult {
        let allows = document.typedRules(origin: .repo).filter { $0.verdict == .allow }
        return PolicyContainment.check(candidate: allows, ceiling: typedRules)
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
            + " (check: \(witness.checkCommand))"
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

/// What replacing one ceiling with another loosens, shown to the owner
/// before they confirm. Rules match by predicate, like the layer merge.
/// Loosening is the owner's call: this informs, it never refuses.
public enum PolicyCeilingDiff {
    public static func loosenings(from old: PolicyCeiling, to new: PolicyCeiling) -> [String] {
        var lines: [String] = []
        for rule in old.rules {
            let predicate = DisplayedText.field(PolicyRevisionIdentity.canonicalPredicate(rule.predicate))
            let id = DisplayedText.field(rule.id.rawValue)
            guard let kept = new.rules.first(where: { $0.predicate == rule.predicate }) else {
                lines.append("drops \(rule.verdict.rawValue) rule \(id) (\(predicate))")
                continue
            }
            if PolicyDiffRisk.restrictionRank(kept.verdict) < PolicyDiffRisk.restrictionRank(rule.verdict) {
                lines.append("downgrades rule \(id) (\(predicate)) from \(rule.verdict.rawValue) to \(kept.verdict.rawValue)")
            }
        }
        switch (old.egressHosts, new.egressHosts) {
        case (.some, nil):
            lines.append("removes egress.hosts: egress approvals become unbounded")
        case (let before?, let after?):
            for host in after where before.contains(host) == false {
                lines.append("adds egress host \(DisplayedText.field(host))")
            }
        case (nil, _):
            break
        }
        return lines
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

    public var revisionsURL: URL {
        RVPolicyPaths.policyCeilingRevisionsFile(inConfigDir: configDirectory)
    }

    /// Nil only when `ceiling.toml` does not exist (ENOENT). Anything else
    /// that is not a readable regular file within the size cap (a symlink,
    /// dangling or not, a FIFO, a directory, EACCES, an oversized or
    /// unparseable file) throws `invalidFile`: callers refuse, never skip.
    public func load() throws -> PolicyCeiling? {
        guard let text = try Self.readText(at: fileURL, followSymlinks: false) else { return nil }
        return try PolicyCeilingTOML.parse(text)
    }

    /// A UTF-8 regular file of at most `PolicyCeiling.maximumBytes`, read
    /// without blocking on a FIFO and without reading past the cap. Nil
    /// only for ENOENT; anything else throws `invalidFile`.
    public static func readText(at url: URL, followSymlinks: Bool) throws -> String? {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | (followSymlinks ? 0 : O_NOFOLLOW))
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw PolicyCeilingError.invalidFile
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            info.st_size >= 0, Int(info.st_size) <= PolicyCeiling.maximumBytes
        else {
            throw PolicyCeilingError.invalidFile
        }
        var bytes = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw PolicyCeilingError.invalidFile }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
            guard bytes.count <= PolicyCeiling.maximumBytes else { throw PolicyCeilingError.invalidFile }
        }
        guard let text = String(validating: bytes, as: UTF8.self) else {
            throw PolicyCeilingError.invalidFile
        }
        return text
    }

    /// Appends one line to `ceiling-revisions.jsonl`, then renames a fresh
    /// 0600 `ceiling.toml` into place, so every ceiling that goes live has
    /// a revision line. Callers hold the machine policy locks and have
    /// confirmed the owner: `PolicyWorkspace.replaceCeiling` is the one
    /// caller. Every failure throws `writeFailed`; a failed rename after
    /// the append leaves one line for a ceiling that never took effect.
    func commitLocked(_ ceiling: PolicyCeiling, recordedAt: Date) throws {
        let text = PolicyCeilingTOML.render(ceiling)
        guard text.utf8.count <= PolicyCeiling.maximumBytes else {
            throw PolicyCeilingError.writeFailed("ceiling.toml would be larger than 256 KiB; nothing was written")
        }
        let line: String
        do {
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configDirectory.path)
            line = try Self.revisionLine(text: text, recordedAt: recordedAt)
        } catch {
            throw PolicyCeilingError.writeFailed("cannot prepare the config directory; nothing was written")
        }
        let temp = fileURL.appendingPathExtension("tmp")
        unlink(temp.path)
        guard Self.writeOwnerOnly(Array(text.utf8), to: temp, flags: O_CREAT | O_EXCL) else {
            unlink(temp.path)
            throw PolicyCeilingError.writeFailed("cannot write ceiling.toml; nothing was written")
        }
        guard Self.writeOwnerOnly(Array(line.utf8), to: revisionsURL, flags: O_CREAT | O_APPEND) else {
            unlink(temp.path)
            throw PolicyCeilingError.writeFailed(
                "cannot append to ceiling-revisions.jsonl; ceiling.toml is unchanged")
        }
        guard rename(temp.path, fileURL.path) == 0 else {
            unlink(temp.path)
            throw PolicyCeilingError.writeFailed(
                "cannot replace ceiling.toml; ceiling-revisions.jsonl has a line for a ceiling that never took effect")
        }
    }

    /// `{"recorded_at_ms":…,"sha256":"…","toml":"…"}` plus a newline.
    static func revisionLine(text: String, recordedAt: Date) throws -> String {
        struct Line: Encodable {
            var recorded_at_ms: Int64
            var sha256: String
            var toml: String
        }
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let record = Line(
            recorded_at_ms: Int64((recordedAt.timeIntervalSince1970 * 1000).rounded(.down)),
            sha256: digest,
            toml: text
        )
        guard let json = String(data: try encoder.encode(record), encoding: .utf8) else {
            throw PolicyCeilingError.invalidFile
        }
        return json + "\n"
    }

    /// Opens with `O_NOFOLLOW` and mode 0600 and requires a regular file,
    /// so the file is never readable by others and never a link target.
    private static func writeOwnerOnly(_ bytes: [UInt8], to url: URL, flags: Int32) -> Bool {
        let fd = open(url.path, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | flags, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, fchmod(fd, 0o600) == 0 else {
            return false
        }
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return false }
            offset += written
        }
        return fsync(fd) == 0
    }
}
