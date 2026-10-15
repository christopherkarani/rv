#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain

/// Network-plane scope carried alongside a `PolicyDocument` diff.
///
/// Mirrors OpenShell's per-binary rule shape (`endpoint_allowed` +
/// `binary_allowed`): destinations and binary identities are evaluated as
/// separate sets so a destination grant can never silently widen which
/// binaries may use it. `PolicyDocument` carries no network plane yet, so
/// CLI callers pass `.empty` scopes and evaluation covers rules, safety
/// level, and secret exemptions; direct callers supply both scopes.
public struct PolicyNetworkScope: Sendable, Equatable {
    /// Destination strings: `host`, `host:port`, or URL form
    /// `scheme://[userinfo@]host[:port][/path]`.
    public var destinations: [String]
    /// Binary identity paths, e.g. `/usr/bin/git`. Entries containing `*`
    /// are wildcards.
    public var binaries: [String]

    public init(destinations: [String] = [], binaries: [String] = []) {
        self.destinations = destinations
        self.binaries = binaries
    }

    public static let empty = PolicyNetworkScope()
}

public enum PolicyDiffSide: String, Sendable, Equatable {
    case old
    case new
}

public enum PolicyDiffRiskError: Error, Sendable, Equatable {
    /// Either side of a text diff failed to parse. Fails closed: the caller
    /// must not apply or validate the diff.
    case unparseableDiff(side: PolicyDiffSide)
    case blockedByFindings(PolicyDiffRiskReport)
}

public struct PolicyDiffRiskFinding: Sendable, Equatable, Hashable, Comparable {
    public enum Kind: String, Sendable, Equatable, Hashable, CaseIterable {
        case newDestination = "new-destination"
        case sensitiveRange = "sensitive-range"
        case credentialEndpoint = "credential-endpoint"
        case unparseableDestination = "unparseable-destination"
        case binaryAdded = "binary-added"
        case binaryWildcard = "binary-wildcard"
        case safetyDowngrade = "safety-downgrade"
        case newAllowRule = "new-allow-rule"
        case verdictRelaxed = "verdict-relaxed"
        case newSecretExemption = "new-secret-exemption"
    }

    public enum Severity: String, Sendable, Equatable, Hashable {
        case advisory
        case blocking
    }

    public var kind: Kind
    public var severity: Severity
    /// Stable detail. Never carries credential material: credential findings
    /// name the host only.
    public var detail: String

    public init(kind: Kind, severity: Severity, detail: String) {
        self.kind = kind
        self.severity = severity
        self.detail = detail
    }

    public static func < (lhs: PolicyDiffRiskFinding, rhs: PolicyDiffRiskFinding) -> Bool {
        (lhs.kind.rawValue, lhs.detail) < (rhs.kind.rawValue, rhs.detail)
    }

    public var line: String {
        "[\(severity.rawValue)] \(kind.rawValue) \(detail)"
    }
}

public struct PolicyDiffRiskReport: Sendable, Equatable {
    /// Deduplicated and sorted by `(kind, detail)`: evaluation order and
    /// input order never affect the report.
    public var findings: [PolicyDiffRiskFinding]

    public init(findings: [PolicyDiffRiskFinding]) {
        self.findings = Array(Set(findings)).sorted()
    }

    public static let clean = PolicyDiffRiskReport(findings: [])

    public var blockingFindings: [PolicyDiffRiskFinding] {
        findings.filter { $0.severity == .blocking }
    }

    public var advisoryFindings: [PolicyDiffRiskFinding] {
        findings.filter { $0.severity == .advisory }
    }

    public var hasBlockingFindings: Bool {
        findings.contains { $0.severity == .blocking }
    }

    /// Full preview section for `policy apply`, including the clean line so
    /// the operator can see the check ran.
    public var previewLines: [String] {
        if findings.isEmpty {
            return ["risk: none"]
        }
        var lines = [
            "risk: \(blockingFindings.count) blocking, \(advisoryFindings.count) advisory"
        ]
        lines += findingLines
        return lines
    }

    /// Bare finding lines for `policy validate`, which stays silent on
    /// success. Empty when clean.
    public var findingLines: [String] {
        findings.map { "  \($0.line)" }
    }
}

/// Diff-level address verdict (F3): sensitive when any host literal is
/// sensitive, routine otherwise.
public enum PolicyDiffRiskLevel: String, Sendable, Equatable {
    case routine
    case sensitive
}

/// One IP literal parsed to canonical bytes (F3). Classification reads
/// `family` and `bytes` only; the source spelling is never inspected.
public struct PolicyDiffNormalizedAddress: Sendable, Equatable, Hashable {
    public enum Family: String, Sendable, Equatable {
        case ipv4
        case ipv6
    }

    public let family: Family
    public let bytes: [UInt8]
    public let canonical: String

    public init(family: Family, bytes: [UInt8], canonical: String) {
        self.family = family
        self.bytes = bytes
        self.canonical = canonical
    }
}

/// Deterministic risk evaluator over policy diffs.
///
/// Only additions and relaxations are flagged: entries present on both sides
/// are accepted as already reviewed, mirroring OpenShell's TOFU pinning
/// where first use is the decision point. Output is canonical (sorted,
/// deduplicated) like OpenShell's `canonical_rule_bytes`, so identical diffs
/// always produce identical reports.
public enum PolicyDiffRisk {
    public static func evaluate(
        oldDocument: PolicyDocument,
        newDocument: PolicyDocument,
        oldScope: PolicyNetworkScope = .empty,
        newScope: PolicyNetworkScope = .empty
    ) -> PolicyDiffRiskReport {
        var findings: [PolicyDiffRiskFinding] = []
        findings += destinationFindings(
            old: oldScope.destinations,
            new: newScope.destinations
        )
        findings += binaryFindings(old: oldScope.binaries, new: newScope.binaries)
        findings += safetyFindings(old: oldDocument.safetyLevel, new: newDocument.safetyLevel)
        findings += ruleFindings(old: oldDocument.rules, new: newDocument.rules)
        findings += exemptionFindings(old: oldDocument.allowPaths, new: newDocument.allowPaths)
        return PolicyDiffRiskReport(findings: findings)
    }

    /// Overlay (share) semantics for `policy apply` and `policy validate
    /// <file>`: the incoming document is a partial share merged tighten-only
    /// into the layer, so omitted rules are preserved, never removed. Flags
    /// only what the share itself asks for: new allow rules (advisory) and
    /// explicit verdict relaxations on existing predicates (blocking), so a
    /// share that asks to weaken a rule refuses `--save` even though the
    /// merge would neutralize it. Safety level and secret exemptions are the
    /// layer's own — the merge preserves them and ignores the share's — so
    /// they are not evaluated here; a share that merely omits them must not
    /// read as a downgrade.
    public static func evaluateShare(
        existing: PolicyDocument,
        incoming: PolicyDocument
    ) -> PolicyDiffRiskReport {
        PolicyDiffRiskReport(findings: shareRuleFindings(existing: existing.rules, incoming: incoming.rules))
    }

    /// Text entry point. Throws fail-closed when either side is unparseable.
    public static func evaluate(
        oldText: String,
        newText: String,
        oldScope: PolicyNetworkScope = .empty,
        newScope: PolicyNetworkScope = .empty
    ) throws -> PolicyDiffRiskReport {
        let oldDocument: PolicyDocument
        do {
            oldDocument = try PolicyDocumentTOML.parse(oldText)
        } catch {
            throw PolicyDiffRiskError.unparseableDiff(side: .old)
        }
        let newDocument: PolicyDocument
        do {
            newDocument = try PolicyDocumentTOML.parse(newText)
        } catch {
            throw PolicyDiffRiskError.unparseableDiff(side: .new)
        }
        return evaluate(
            oldDocument: oldDocument,
            newDocument: newDocument,
            oldScope: oldScope,
            newScope: newScope
        )
    }

    // MARK: - F3 address normalization
    //
    // A diff that widens network reach must flag sensitive destinations no
    // matter how the literal is spelled. String-prefix checks miss aliases,
    // so every entry point below parses the literal to bytes FIRST and
    // classifies the bytes. Unparseable input fails closed to sensitive.

    /// Normalize one IP literal to canonical bytes.
    ///
    /// Accepts strict dotted-quad IPv4 and RFC 4291 IPv6 (including embedded
    /// IPv4 tails such as `::ffff:1.2.3.4`). Strips one bracket pair
    /// (`[::1]`, `[::1]:443`) and any `%zone` suffix before parsing. Returns
    /// nil for anything else (DNS names, ports on bare literals, octal/hex
    /// quads, truncated forms): callers treat nil as sensitive (fail closed).
    public static func normalize(_ raw: String) -> PolicyDiffNormalizedAddress? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else { return nil }
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let inner = String(text[text.index(after: text.startIndex)..<close])
            guard inner.isEmpty == false else { return nil }
            // Anything after the bracket must be a canonical port suffix;
            // trailing junk is not an address literal.
            let rest = text[text.index(after: close)...]
            if rest.isEmpty == false {
                guard rest.hasPrefix(":"), validPortText(rest.dropFirst()) else { return nil }
            }
            text = inner
        }
        if let zone = text.firstIndex(of: "%") {
            text = String(text[..<zone])
            guard text.isEmpty == false else { return nil }
        }
        if let v4 = parseIPv4(text) {
            return PolicyDiffNormalizedAddress(
                family: .ipv4,
                bytes: v4,
                canonical: "\(v4[0]).\(v4[1]).\(v4[2]).\(v4[3])"
            )
        }
        if let v6 = parseIPv6(text) {
            return PolicyDiffNormalizedAddress(
                family: .ipv6,
                bytes: v6,
                canonical: presentIPv6(v6)
            )
        }
        return nil
    }

    /// True when the literal must hit the sensitive block.
    ///
    /// Normalizes BEFORE classifying. Unparseable input returns true (fail
    /// closed) so an evasive spelling can never skip the block.
    public static func isSensitive(_ literal: String) -> Bool {
        guard let normalized = normalize(literal) else { return true }
        return isSensitive(normalized: normalized)
    }

    /// Byte-level classification. The literal text is never inspected here.
    public static func isSensitive(normalized address: PolicyDiffNormalizedAddress) -> Bool {
        switch address.family {
        case .ipv4:
            return isSensitiveIPv4(address.bytes)
        case .ipv6:
            return isSensitiveIPv6(address.bytes)
        }
    }

    /// Diff-level gate: sensitive when any host literal is sensitive.
    /// Empty host lists are routine; unknown text fails closed via isSensitive.
    public static func assess(hosts: [String]) -> PolicyDiffRiskLevel {
        hosts.contains(where: { isSensitive($0) }) ? .sensitive : .routine
    }

    private static func parseIPv4(_ text: String) -> [UInt8]? {
        // Strict dotted quad, platform-independent: some `inet_pton`
        // implementations accept leading-zero parts as decimal, but
        // resolvers read them as octal (`0177.0.0.1` dials 127.0.0.1),
        // so leading zeros reject here and fail closed instead of
        // classifying under the decimal reading.
        guard isStrictDottedQuad(text) else { return nil }
        var addr = in_addr()
        let result = text.withCString { pointer in
            inet_pton(AF_INET, pointer, &addr)
        }
        guard result == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    private static func isStrictDottedQuad(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard part.count >= 1, part.count <= 3 else { return false }
            guard part.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) else {
                return false
            }
            if part.count > 1, part.hasPrefix("0") { return false }
            guard UInt8(part) != nil else { return false }
        }
        return true
    }

    private static func parseIPv6(_ text: String) -> [UInt8]? {
        // Same strictness for an embedded IPv4 tail (`::ffff:0177.0.0.1`
        // must not normalize where the resolver dials octal 127.0.0.1).
        if text.contains(".") {
            guard let tail = text.split(separator: ":").last.map(String.init),
                isStrictDottedQuad(tail)
            else {
                return nil
            }
        }
        var addr = in6_addr()
        let result = text.withCString { pointer in
            inet_pton(AF_INET6, pointer, &addr)
        }
        guard result == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &addr) { Array($0) }
        guard bytes.count == 16 else { return nil }
        return bytes
    }

    static func isSensitiveIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return true }
        let value = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        if value == 0xFFFF_FFFF { return true }
        let sensitive: [(base: UInt32, bits: Int)] = [
            (0x0000_0000, 8),
            (0x7F00_0000, 8),
            (0x0A00_0000, 8),
            (0xAC10_0000, 12),
            (0xC0A8_0000, 16),
            (0x6440_0000, 10),
            (0xA9FE_0000, 16),
            (0xC000_0000, 24),
            (0xC000_0200, 24),
            (0xC612_0000, 15),
            (0xC633_6400, 24),
            (0xCB00_7100, 24),
            (0xE000_0000, 4),
            (0xF000_0000, 4),
        ]
        for range in sensitive {
            let mask: UInt32 = range.bits == 0 ? 0 : UInt32.max << (32 - range.bits)
            if (value & mask) == (range.base & mask) { return true }
        }
        return false
    }

    static func isSensitiveIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return true }
        if bytes.allSatisfy({ $0 == 0 }) { return true }
        if bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return isSensitiveIPv4(Array(bytes[12...15]))
        }
        if bytes.prefix(12).allSatisfy({ $0 == 0 }) {
            return isSensitiveIPv4(Array(bytes[12...15]))
        }
        if bytes[0] == 0x20, bytes[1] == 0x02 {
            return isSensitiveIPv4(Array(bytes[2...5]))
        }
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return true }
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0xC0 { return true }
        if bytes[0] & 0xFE == 0xFC { return true }
        if bytes[0] == 0xFF { return true }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0D, bytes[3] == 0xB8 { return true }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x00, bytes[3] == 0x00 { return true }
        if bytes[0] == 0x00, bytes[1] == 0x64, bytes[2] == 0xFF, bytes[3] == 0x9B,
            bytes[4] == 0x00, bytes[5] == 0x00, bytes[6] == 0x00,
            bytes[7] == 0x00, bytes[8] == 0x00, bytes[9] == 0x00,
            bytes[10] == 0x00, bytes[11] == 0x00
        {
            return true
        }
        if bytes[0] & 0xE0 == 0x20 { return false }
        return true
    }

    static func presentIPv6(_ bytes: [UInt8]) -> String {
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return "::ffff:\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])"
        }
        var groups = [UInt16]()
        groups.reserveCapacity(8)
        for index in stride(from: 0, to: 16, by: 2) {
            groups.append((UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1]))
        }
        var bestStart = -1
        var bestLength = 0
        var cursor = 0
        while cursor < 8 {
            if groups[cursor] == 0 {
                let start = cursor
                while cursor < 8, groups[cursor] == 0 { cursor += 1 }
                if cursor - start > bestLength {
                    bestStart = start
                    bestLength = cursor - start
                }
            } else {
                cursor += 1
            }
        }
        if bestLength < 2 { bestStart = -1 }
        var text = ""
        var index = 0
        while index < 8 {
            if index == bestStart {
                text += "::"
                index += bestLength
                continue
            }
            if text.isEmpty == false, text.hasSuffix("::") == false { text += ":" }
            text += String(groups[index], radix: 16)
            index += 1
        }
        return text.isEmpty ? "::" : text
    }

    private static func destinationFindings(old: [String], new: [String]) -> [PolicyDiffRiskFinding] {
        let added = Array(Set(new).subtracting(Set(old))).sorted()
        var findings: [PolicyDiffRiskFinding] = []
        for destination in added {
            findings.append(
                PolicyDiffRiskFinding(
                    kind: .newDestination,
                    severity: .advisory,
                    detail: redactedDestination(destination)
                )
            )
            guard let parsed = splitDestination(destination) else {
                findings.append(
                    PolicyDiffRiskFinding(
                        kind: .unparseableDestination,
                        severity: .blocking,
                        detail: redactedDestination(destination)
                    )
                )
                continue
            }
            if parsed.hasCredentials {
                findings.append(
                    PolicyDiffRiskFinding(
                        kind: .credentialEndpoint,
                        severity: .blocking,
                        detail: parsed.host
                    )
                )
            }
            if let range = classify(host: parsed.host) {
                findings.append(
                    PolicyDiffRiskFinding(
                        kind: .sensitiveRange,
                        severity: .blocking,
                        detail: "\(range.rawValue) \(parsed.host)"
                    )
                )
            }
        }
        return findings
    }

    private static func binaryFindings(old: [String], new: [String]) -> [PolicyDiffRiskFinding] {
        let added = Array(Set(new).subtracting(Set(old))).sorted()
        return added.map { binary in
            if binary.contains("*") {
                return PolicyDiffRiskFinding(
                    kind: .binaryWildcard,
                    severity: .blocking,
                    detail: binary
                )
            }
            return PolicyDiffRiskFinding(
                kind: .binaryAdded,
                severity: .advisory,
                detail: binary
            )
        }
    }

    private static func safetyFindings(
        old: SafetyLevel?,
        new: SafetyLevel?
    ) -> [PolicyDiffRiskFinding] {
        guard old == .strict, new != .strict else {
            return []
        }
        return [
            PolicyDiffRiskFinding(
                kind: .safetyDowngrade,
                severity: .blocking,
                detail: "strict -> \(new?.rawValue ?? "unset")"
            )
        ]
    }

    private static func ruleFindings(
        old: [PolicyDocumentRule],
        new: [PolicyDocumentRule]
    ) -> [PolicyDiffRiskFinding] {
        shareRuleFindings(existing: old, incoming: new)
            + removedRuleFindings(old: old, new: new)
    }

    /// Overlay direction: what the incoming side adds or asks to relax.
    /// Omissions are not removals here; the tighten-only merge preserves
    /// whatever the share does not mention.
    private static func shareRuleFindings(
        existing: [PolicyDocumentRule],
        incoming: [PolicyDocumentRule]
    ) -> [PolicyDiffRiskFinding] {
        var findings: [PolicyDiffRiskFinding] = []
        for rule in incoming {
            guard let oldVerdict = existing.first(where: { $0.predicate == rule.predicate })?.verdict else {
                if rule.verdict == .allow {
                    findings.append(
                        PolicyDiffRiskFinding(
                            kind: .newAllowRule,
                            severity: .advisory,
                            detail: rule.id.rawValue
                        )
                    )
                }
                continue
            }
            if restrictionRank(rule.verdict) < restrictionRank(oldVerdict) {
                findings.append(
                    PolicyDiffRiskFinding(
                        kind: .verdictRelaxed,
                        severity: .blocking,
                        detail: "\(rule.id.rawValue) \(oldVerdict.rawValue)->\(rule.verdict.rawValue)"
                    )
                )
            }
        }
        return findings
    }

    /// Replacement direction: a protective rule (deny or ask) whose predicate
    /// vanishes from the new side no longer constrains anything, which widens
    /// exactly like a relaxation to allow. Removed allows are narrowing and
    /// stay silent. Full-document `evaluate` and rollback
    /// (`refuseRelaxingRollback`) use this. `evaluateShare` must not treat a
    /// partial share's omissions as deletes.
    static func removedRuleFindings(
        old: [PolicyDocumentRule],
        new: [PolicyDocumentRule]
    ) -> [PolicyDiffRiskFinding] {
        old.compactMap { rule in
            guard rule.verdict == .deny || rule.verdict == .ask,
                new.contains(where: { $0.predicate == rule.predicate }) == false
            else {
                return nil
            }
            return PolicyDiffRiskFinding(
                kind: .verdictRelaxed,
                severity: .blocking,
                detail: "\(rule.id.rawValue) \(rule.verdict.rawValue)->removed"
            )
        }
    }

    private static func exemptionFindings(old: [String], new: [String]) -> [PolicyDiffRiskFinding] {
        let added = Array(Set(new).subtracting(Set(old))).sorted()
        return added.map {
            PolicyDiffRiskFinding(
                kind: .newSecretExemption,
                severity: .advisory,
                detail: $0
            )
        }
    }

    /// Same ordering as `PolicyDocumentTOML.mergeLayer`: allow < ask < deny.
    private static func restrictionRank(_ verdict: TypedRuleVerdict) -> Int {
        switch verdict {
        case .allow: 0
        case .ask: 1
        case .deny: 2
        }
    }

    private struct ParsedDestination {
        var host: String
        var hasCredentials: Bool
    }

    private enum SensitiveRange: String {
        case metadata
        case loopback
        case linkLocal = "link-local"
        case `private` = "private"
        case unspecified
        case multicast
        case reserved
    }

    private static func splitDestination(_ raw: String) -> ParsedDestination? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else { return nil }
        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
        }
        var authority = String(text.prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" }))
        guard authority.isEmpty == false else { return nil }
        var hasCredentials = false
        if let at = authority.lastIndex(of: "@") {
            hasCredentials = authority[..<at].isEmpty == false
            authority = String(authority[authority.index(after: at)...])
            guard authority.isEmpty == false else { return nil }
        }
        let host: String
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            host = String(authority[authority.index(after: authority.startIndex)..<close])
            let rest = authority[authority.index(after: close)...]
            if rest.isEmpty == false {
                guard rest.hasPrefix(":"), validPortText(rest.dropFirst()) else { return nil }
            }
        } else {
            let colons = authority.filter { $0 == ":" }.count
            if colons > 1 {
                host = authority
            } else if colons == 1, let colon = authority.firstIndex(of: ":") {
                let port = authority[authority.index(after: colon)...]
                guard validPortText(port) else { return nil }
                host = String(authority[..<colon])
            } else {
                host = authority
            }
        }
        var canonical = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if canonical.hasSuffix("."), canonical.count > 1 {
            canonical.removeLast()
        }
        guard canonical.isEmpty == false, canonical.contains(" ") == false else { return nil }
        return ParsedDestination(host: canonical, hasCredentials: hasCredentials)
    }

    /// Canonical port text: ASCII digits only, value in 1...65535.
    /// (`Character.isNumber` also accepts non-ASCII digits.)
    private static func validPortText(_ port: Substring) -> Bool {
        guard port.isEmpty == false,
            port.allSatisfy({ $0.asciiValue.map { $0 >= 48 && $0 <= 57 } ?? false }),
            let value = Int(port), (1...65535).contains(value)
        else { return false }
        return true
    }

    private static func redactedDestination(_ raw: String) -> String {
        // Findings name scheme + authority only: path/query/fragment can
        // carry tokens (webhook URLs), and userinfo is masked below.
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let authorityStart = trimmed.range(of: "://").map(\.upperBound) ?? trimmed.startIndex
        if let cut = trimmed[authorityStart...].firstIndex(where: { "/?#".contains($0) }) {
            trimmed = String(trimmed[..<cut])
        }
        guard let at = trimmed.lastIndex(of: "@") else {
            return trimmed.isEmpty ? "empty entry" : trimmed
        }
        let after = trimmed[trimmed.index(after: at)...]
        let prefix: String
        if let scheme = trimmed.range(of: "://"),
            scheme.upperBound <= at
        {
            prefix = String(trimmed[...scheme.upperBound])
        } else {
            prefix = ""
        }
        return "\(prefix)***@\(after)"
    }

    /// Sensitive-range verdict for one parsed host. F3 normalize-first:
    /// literals that parse to bytes classify from bytes, so alias
    /// spellings (mapped, compatible, 6to4, compressed) inherit the
    /// embedded address's label and cannot slip past string checks.
    /// Anything else (DNS names, `inet_aton` number forms) keeps the
    /// legacy classification.
    private static func classify(host: String) -> SensitiveRange? {
        if let normalized = normalize(host) {
            return classifyNormalized(normalized)
        }
        return classifyLegacy(host: host)
    }

    /// Byte-level labels. Order mirrors the legacy checks (metadata
    /// before loopback before link-local before private); ranges the
    /// legacy labels never covered get `unspecified`, `multicast`, or
    /// `reserved`. Nil exactly when F3 deems the bytes public.
    private static func classifyNormalized(_ address: PolicyDiffNormalizedAddress) -> SensitiveRange? {
        switch address.family {
        case .ipv4:
            return classifyIPv4Bytes(address.bytes)
        case .ipv6:
            return classifyIPv6Bytes(address.bytes)
        }
    }

    private static func classifyIPv4Bytes(_ bytes: [UInt8]) -> SensitiveRange? {
        guard bytes.count == 4 else { return .reserved }
        if bytes == [169, 254, 169, 254] || bytes == [100, 100, 100, 200] {
            return .metadata
        }
        if bytes[0] == 127 {
            return .loopback
        }
        if bytes[0] == 169, bytes[1] == 254 {
            return .linkLocal
        }
        if bytes[0] == 10
            || (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31)
            || (bytes[0] == 192 && bytes[1] == 168)
        {
            return .private
        }
        if bytes[0] == 0 {
            return .unspecified
        }
        if bytes[0] & 0xF0 == 0xE0 {
            return .multicast
        }
        if isSensitiveIPv4(bytes) {
            return .reserved
        }
        return nil
    }

    private static func classifyIPv6Bytes(_ bytes: [UInt8]) -> SensitiveRange? {
        guard bytes.count == 16 else { return .reserved }
        if bytes.allSatisfy({ $0 == 0 }) {
            return .unspecified
        }
        if bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes[15] == 1 {
            return .loopback
        }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return classifyIPv4Bytes(Array(bytes[12...15]))
        }
        if bytes.prefix(12).allSatisfy({ $0 == 0 }) {
            return classifyIPv4Bytes(Array(bytes[12...15]))
        }
        if bytes[0] == 0x20, bytes[1] == 0x02 {
            return classifyIPv4Bytes(Array(bytes[2...5]))
        }
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 {
            return .linkLocal
        }
        if bytes[0] & 0xFE == 0xFC {
            return .private
        }
        if bytes[0] == 0xFF {
            return .multicast
        }
        if isSensitiveIPv6(bytes) {
            return .reserved
        }
        return nil
    }

    private static func classifyLegacy(host: String) -> SensitiveRange? {
        if host == "169.254.169.254"
            || host == "100.100.100.200"
            || host == "metadata.google.internal"
        {
            return .metadata
        }
        if host == "localhost" || host == "::1" {
            return .loopback
        }
        if let octets = ipv4Octets(host) {
            // Octet-based so numeric aliases (2130706433-style words, hex,
            // octal) carry the same label as their dotted-quad spelling.
            if octets == [169, 254, 169, 254] || octets == [100, 100, 100, 200] {
                return .metadata
            }
            if octets[0] == 127 {
                return .loopback
            }
            if octets[0] == 169, octets[1] == 254 {
                return .linkLocal
            }
            if octets[0] == 10
                || (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31)
                || (octets[0] == 192 && octets[1] == 168)
            {
                return .private
            }
            return nil
        }
        if let hextet = ipv6FirstHextet(host) {
            if hextet & 0xFFC0 == 0xFE80 {
                return .linkLocal
            }
            if hextet & 0xFE00 == 0xFC00 {
                return .private
            }
        }
        return nil
    }

    /// `inet_aton` number forms: resolvers accept a 32-bit decimal word
    /// (`2130706433`), `0x` hex, leading-`0` octal, short forms (`127.1`
    /// is `127.0.0.1`), and hex/octal parts inside a quad (`0x7f.0.0.1`),
    /// so decimal quads alone would let loopback/LAN aliases classify as
    /// public. Anything this rejects stays an opaque hostname.
    private static func ipv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var values: [UInt32] = []
        for part in parts {
            guard let value = ipv4PartValue(part) else { return nil }
            values.append(value)
        }
        let words: [UInt32]
        switch values.count {
        case 4:
            guard values.allSatisfy({ $0 <= 0xFF }) else { return nil }
            words = values
        case 3:
            guard values[0] <= 0xFF, values[1] <= 0xFF, values[2] <= 0xFFFF else {
                return nil
            }
            words = [values[0], values[1], values[2] >> 8, values[2] & 0xFF]
        case 2:
            guard values[0] <= 0xFF, values[1] <= 0xFF_FFFF else { return nil }
            words = [
                values[0],
                (values[1] >> 16) & 0xFF,
                (values[1] >> 8) & 0xFF,
                values[1] & 0xFF,
            ]
        case 1:
            words = [
                (values[0] >> 24) & 0xFF,
                (values[0] >> 16) & 0xFF,
                (values[0] >> 8) & 0xFF,
                values[0] & 0xFF,
            ]
        default:
            return nil
        }
        return words.map { UInt8($0) }
    }

    private static func ipv4PartValue(_ part: Substring) -> UInt32? {
        guard part.isEmpty == false else { return nil }
        let text = String(part)
        if text.hasPrefix("0x"), text.count > 2 {
            return UInt32(String(text.dropFirst(2)), radix: 16)
        }
        if text.hasPrefix("0"), text.count > 1 {
            return UInt32(text, radix: 8)
        }
        return UInt32(text, radix: 10)
    }

    private static func ipv6FirstHextet(_ host: String) -> UInt16? {
        guard host.contains(":") else { return nil }
        let first = host.prefix(while: { $0 != ":" })
        guard first.isEmpty == false, first.count <= 4 else { return nil }
        return UInt16(first, radix: 16)
    }
}
