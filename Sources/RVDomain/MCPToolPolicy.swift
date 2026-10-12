/// MCP tool addresses and policy vocabulary. Pure values; no IO.
public struct MCPToolAddress: Sendable, Equatable, Hashable {
    /// Open-ended integration segment (dot-free).
    public let integration: String
    /// Open-ended owner segment (dot-free).
    public let owner: String
    /// Open-ended connection segment (dot-free).
    public let connection: String
    /// Dot-tolerant tool segment (no empty dot-separated part).
    public let tool: String

    /// Validates segments: non-empty, at most 128 chars, no whitespace/control/invisible-format, no dots outside `tool`.
    public init(integration: String, owner: String, connection: String, tool: String) throws {
        try Self.validate(segment: integration, allowDots: false)
        try Self.validate(segment: owner, allowDots: false)
        try Self.validate(segment: connection, allowDots: false)
        try Self.validate(segment: tool, allowDots: true)
        self.integration = integration
        self.owner = owner
        self.connection = connection
        self.tool = tool
    }

    /// Canonical literal: `tools.<integration>.<owner>.<connection>.<tool>`.
    public var literal: String {
        "tools.\(integration).\(owner).\(connection).\(tool)"
    }

    /// Parses a canonical literal; trailing dot-separated parts all belong to `tool`.
    public static func parse(_ literal: String) throws -> MCPToolAddress {
        guard literal.hasPrefix("tools.") else {
            throw MCPToolAddressError.missingToolsPrefix
        }
        let rest = literal.dropFirst("tools.".count)
        let parts = rest.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4 else {
            throw MCPToolAddressError.tooFewSegments
        }
        let tool = parts[3...].joined(separator: ".")
        return try MCPToolAddress(
            integration: parts[0],
            owner: parts[1],
            connection: parts[2],
            tool: tool
        )
    }

    private static func validate(segment: String, allowDots: Bool) throws {
        guard segment.isEmpty == false else {
            throw MCPToolAddressError.emptySegment
        }
        guard segment.count <= Self.maxSegmentLength else {
            throw MCPToolAddressError.segmentTooLong
        }
        let hasWhitespace = segment.contains(where: { $0.isWhitespace || $0.isNewline })
        let hasControl = segment.unicodeScalars.contains(where: {
            $0.value < 0x20 || (0x7F...0x9F).contains($0.value)
        })
        let hasInvisibleFormat = segment.unicodeScalars.contains(where: {
            $0.properties.generalCategory == .format
        })
        let hasDot = allowDots == false && segment.contains(".")
        let disallowed = hasWhitespace || hasControl || hasInvisibleFormat || hasDot
        guard disallowed == false else {
            throw MCPToolAddressError.invalidCharacter
        }
        if allowDots {
            let hasEmptyPart = segment.split(separator: ".", omittingEmptySubsequences: false).contains {
                $0.isEmpty
            }
            guard hasEmptyPart == false else {
                throw MCPToolAddressError.emptySegment
            }
        }
    }

    private static let maxSegmentLength = 128
}

/// Malformed-address failures. Never echoes the offending literal.
public enum MCPToolAddressError: Error, Sendable, Equatable {
    /// Literal does not start with `tools.`.
    case missingToolsPrefix
    /// Fewer than four dot-separated parts after `tools.`.
    case tooFewSegments
    /// An empty segment or an empty dot-separated part inside `tool`.
    case emptySegment
    /// A segment exceeds 128 characters.
    case segmentTooLong
    /// A segment holds whitespace, a control character, an invisible format character, or a misplaced dot.
    case invalidCharacter
}

extension MCPToolAddress: Codable {
    /// Encodes the canonical literal as a single string.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(literal)
    }

    /// Decodes by parsing; malformed literals throw.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = try Self.parse(try container.decode(String.self))
    }
}

/// Address matcher: exact, universal, trailing-`*`, one substring mid-`*`
/// (`singleMid`, legacy), or a segment-anchored Executor-grammar pattern
/// (`segments`, canonical for every raw string `parse` accepts).
///
/// Pattern-story rule: the legacy cases (`exact`, `any`, `trailingPrefix`,
/// `singleMid`) are frozen for stored rules and keep their behavior
/// byte-for-byte. `singleMid` is substring-based — its middle may span
/// segments — so it is NOT interchangeable with a mid-`*` in `segments`,
/// where each `*` consumes exactly one whole segment. New rules parse raw
/// strings via `parse`, which always yields `segments`; no raw string ever
/// aliases a legacy case, and no lossy cross-conversion exists.
public enum ToolPattern: Sendable, Equatable, Hashable, Codable {
    /// Matches one validated address.
    case exact(MCPToolAddress)
    /// Matches every address.
    case any
    /// Matches literals starting with this prefix at a segment boundary: the
    /// prefix must consume the whole literal, end in a dot, or stop before a
    /// dot, so `…conn.read` never approves `…conn.readAdminKeys`.
    case trailingPrefix(String)
    /// Legacy substring matcher: literals starting with `prefix` and ending
    /// with `suffix` around a non-empty middle, which may span segments.
    /// Retained for stored rules; unreachable from `parse`. New patterns use
    /// `segments`, where mid-`*` is one whole segment.
    case singleMid(prefix: String, suffix: String)
    /// Matches per Executor `matchPattern` over dot-separated segments: each
    /// mid-`*` consumes exactly one segment and may repeat, trailing `*` is a
    /// subtree. Canonical for new rules; `MCPPolicyStore.resolve` consumes it
    /// through `matches` like every other case.
    case segments(SegmentPattern)

    /// True when the address literal satisfies this pattern.
    public func matches(_ address: MCPToolAddress) -> Bool {
        switch self {
        case .exact(let expected):
            return address == expected
        case .any:
            return true
        case .trailingPrefix(let prefix):
            let literal = address.literal
            guard literal.hasPrefix(prefix) else { return false }
            if literal.count == prefix.count || prefix.isEmpty { return true }
            if prefix.hasSuffix(".") { return true }
            return literal.dropFirst(prefix.count).first == "."
        case .singleMid(let prefix, let suffix):
            let literal = address.literal
            return literal.count > prefix.count + suffix.count
                && literal.hasPrefix(prefix)
                && literal.hasSuffix(suffix)
        case .segments(let pattern):
            return pattern.matches(address)
        }
    }

    /// Parses a raw pattern string into the canonical segment-anchored form.
    /// Accepts exactly what Executor `isValidPattern` accepts; every success
    /// yields `segments`, so parsed patterns never alias the legacy cases.
    public static func parse(_ raw: String) throws -> ToolPattern {
        .segments(try SegmentPattern.parse(raw))
    }

    /// True exactly when `parse` succeeds.
    public static func isValid(_ raw: String) -> Bool {
        SegmentPattern.isValid(raw)
    }
}

/// Policy scope. Comparison ranks org above user.
public enum PolicyOwner: String, Sendable, Equatable, Hashable, Comparable, Codable {
    /// Per-user rule, outranked by org.
    case user
    /// Org rule, outranks user.
    case org

    /// Rank order with org above user.
    public static func < (lhs: PolicyOwner, rhs: PolicyOwner) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .user: 0
        case .org: 1
        }
    }
}

/// Policy verdict. Comparison ranks restrictiveness: block > requireApproval > approve.
public enum PolicyAction: String, Sendable, Equatable, Hashable, Comparable, Codable {
    /// Least restrictive: run without prompting.
    case approve
    /// Mid restrictive: prompt before running.
    case requireApproval = "require_approval"
    /// Most restrictive: deny.
    case block

    /// Restrictiveness order: approve < requireApproval < block.
    public static func < (lhs: PolicyAction, rhs: PolicyAction) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .approve: 0
        case .requireApproval: 1
        case .block: 2
        }
    }
}

/// One policy rule: identity, scope, matcher, verdict, and rank position.
public struct ToolPolicy: Sendable, Equatable, Hashable, Codable {
    /// Stable rule identity.
    public let id: String
    /// Scope deciding cross-owner precedence.
    public let owner: PolicyOwner
    /// Address matcher.
    public let pattern: ToolPattern
    /// Verdict when the pattern matches.
    public let action: PolicyAction
    /// Fractional rank deciding same-owner order.
    public let position: FractionalIndex

    /// Assembles one rule from validated parts.
    public init(
        id: String,
        owner: PolicyOwner,
        pattern: ToolPattern,
        action: PolicyAction,
        position: FractionalIndex
    ) {
        self.id = id
        self.owner = owner
        self.pattern = pattern
        self.action = action
        self.position = position
    }
}

/// Dense rank over doubles. Comparison orders positions.
public struct FractionalIndex: Sendable, Equatable, Hashable, Comparable, Codable {
    /// Rank value; smaller sorts earlier. Never NaN: NaN breaks the Comparable ordering.
    public let value: Double

    /// Wraps a rank value. Traps on NaN, which would poison ordering; infinities stay orderable.
    public init(value: Double) {
        precondition(value.isNaN == false, "FractionalIndex value must not be NaN")
        self.value = value
    }

    /// Order-agnostic midpoint of two positions for between-placement. Falls back to `first` when the midpoint is NaN (opposite infinities), so this function never traps.
    public static func between(_ first: FractionalIndex, _ second: FractionalIndex) -> FractionalIndex {
        let mid = (first.value + second.value) / 2
        guard mid.isNaN == false else { return first }
        return FractionalIndex(value: mid)
    }

    /// Value order; smaller sorts earlier.
    public static func < (lhs: FractionalIndex, rhs: FractionalIndex) -> Bool {
        lhs.value < rhs.value
    }

    private enum CodingKeys: String, CodingKey {
        case value
    }

    /// Decodes the rank value; throws on NaN for the same reason `init(value:)` traps.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(Double.self, forKey: .value)
        guard value.isNaN == false else {
            throw DecodingError.dataCorruptedError(forKey: .value, in: container, debugDescription: "FractionalIndex value must not be NaN")
        }
        self.value = value
    }
}

/// One dot-separated segment of a parsed `SegmentPattern`: a literal or a whole-segment wildcard.
public enum PatternSegment: Sendable, Equatable, Hashable, Codable {
    /// Matches exactly this segment text. Case-sensitive, like every Executor comparison.
    case literal(String)
    /// Matches exactly one segment of any text: one mid-pattern `*`.
    case wildcard
}

/// Raw-string pattern grammar failures. Cases carry no payload, so a thrown
/// error never echoes the rejected pattern.
public enum ToolPatternError: Error, Sendable, Equatable {
    /// The pattern is empty.
    case emptyPattern
    /// The pattern starts with a dot.
    case leadingDot
    /// The pattern ends with a dot.
    case trailingDot
    /// The pattern holds an empty segment (`..`).
    case emptySegment
    /// The pattern starts with `*` but is not the universal `*`.
    case leadingWildcard
    /// A `*` shares its segment with other text (`me*`).
    case partialWildcard
}

/// Segment-anchored address pattern: the Executor `matchPattern` grammar
/// (`policies.ts:86`) with mid-`*` matching exactly one segment and allowed to
/// repeat (`vercel.*.*.dns.create`). Unlike `ToolPattern.singleMid`, which is
/// substring-based, every wildcard here is one whole dot-separated segment and
/// a trailing `*` is a subtree. `parse` accepts exactly what Executor
/// `isValidPattern` (`policies.ts:106`) accepts, including the same check
/// order, so a pattern valid in one engine is valid in the other; in
/// particular there are no per-segment character or length checks, and a
/// literal no valid address can contain simply never matches.
public enum SegmentPattern: Sendable, Equatable, Hashable, Codable {
    /// Matches every address: the universal `*`.
    case any
    /// Matches one dot-joined segment list exactly. No wildcards.
    case exact(segments: [String])
    /// Matches segment-wise: each `.wildcard` consumes exactly one address
    /// segment; `subtree` (a trailing `*`) additionally matches the prefix
    /// itself and anything deeper.
    case wildcard(segments: [PatternSegment], subtree: Bool)

    /// Canonical raw string. Round-trips: `parse(rawValue) == self` for every value `parse` produces.
    public var rawValue: String {
        switch self {
        case .any:
            return "*"
        case .exact(let segments):
            return segments.joined(separator: ".")
        case .wildcard(let segments, let subtree):
            let head = segments.map { segment -> String in
                switch segment {
                case .wildcard:
                    return "*"
                case .literal(let text):
                    return text
                }
            }.joined(separator: ".")
            if subtree {
                return head + ".*"
            }
            return head
        }
    }

    /// Parses a raw pattern string. Guards run in Executor `isValidPattern`
    /// order, so the first failure wins identically in both engines.
    public static func parse(_ raw: String) throws -> SegmentPattern {
        guard raw.isEmpty == false else {
            throw ToolPatternError.emptyPattern
        }
        if raw == "*" {
            return .any
        }
        guard raw.hasPrefix(".") == false else {
            throw ToolPatternError.leadingDot
        }
        guard raw.hasSuffix(".") == false else {
            throw ToolPatternError.trailingDot
        }
        guard raw.contains("..") == false else {
            throw ToolPatternError.emptySegment
        }
        guard raw.hasPrefix("*") == false else {
            throw ToolPatternError.leadingWildcard
        }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        for part in parts {
            guard part.contains("*") == false || part == "*" else {
                throw ToolPatternError.partialWildcard
            }
        }
        var head = parts
        var subtree = false
        if head.last == "*" {
            subtree = true
            head.removeLast()
        }
        let segments = head.map { part -> PatternSegment in
            if part == "*" {
                return .wildcard
            }
            return .literal(part)
        }
        if subtree == false && segments.contains(.wildcard) == false {
            return .exact(segments: head)
        }
        return .wildcard(segments: segments, subtree: subtree)
    }

    /// True exactly when `parse` succeeds. Mirrors Executor `isValidPattern` accept/reject on every input.
    public static func isValid(_ raw: String) -> Bool {
        (try? parse(raw)) != nil
    }

    /// True when the address literal satisfies this pattern.
    public func matches(_ address: MCPToolAddress) -> Bool {
        matches(literal: address.literal)
    }

    /// Raw-string entry: Executor `matchPattern(pattern, toolId)` semantics
    /// verbatim. The literal is split without validation, so Executor
    /// fixtures without a `tools.` prefix evaluate here directly.
    public func matches(literal toolId: String) -> Bool {
        switch self {
        case .any:
            return true
        case .exact(let segments):
            return toolId.split(separator: ".", omittingEmptySubsequences: false).map(String.init) == segments
        case .wildcard(let segments, let subtree):
            let address = toolId.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            for (index, segment) in segments.enumerated() {
                switch segment {
                case .wildcard:
                    guard index < address.count else { return false }
                case .literal(let expected):
                    guard index < address.count, address[index] == expected else { return false }
                }
            }
            if subtree {
                return address.count >= segments.count
            }
            return address.count == segments.count
        }
    }

    /// Specificity score: Executor `patternSpecificity` formula
    /// (`policies.ts:195`): `*` is 0, otherwise the head-segment count —
    /// mid-`*` counts as one segment, the trailing `*` is excluded — times
    /// two, plus one unless trailing-`*`.
    public var specificity: Int {
        switch self {
        case .any:
            return 0
        case .exact(let segments):
            return segments.count * 2 + 1
        case .wildcard(let segments, let subtree):
            return segments.count * 2 + (subtree ? 0 : 1)
        }
    }

    /// Default fractional position for a new rule among an owner's committed
    /// rules: just below every more-specific rule and above everything equally
    /// or less specific, so a fresh group rule never shadows a leaf rule.
    /// Mirrors Executor `positionForNewPattern` (`policies.ts:213`): rows sort
    /// by (position, id), the insertion index is the first row whose
    /// specificity is at most the new score, and the key lands between its
    /// neighbours via `FractionalIndex.between`. Double analogue of
    /// `generateKeyBetween`: one step below the minimum (or above the
    /// maximum) at the edges, `0` when there are no rows. Infinities saturate
    /// like `between` (below `-inf`/above `+inf` is inexpressible in `Double`,
    /// so the edge key ties the extreme row and id order breaks the tie);
    /// this function never traps.
    public static func positionForNewPattern(
        _ pattern: SegmentPattern,
        rows: [(id: String, pattern: SegmentPattern, position: FractionalIndex)]
    ) -> FractionalIndex {
        let committed = rows.sorted { ($0.position, $0.id) < ($1.position, $1.id) }
        let score = pattern.specificity
        let index = committed.firstIndex { $0.pattern.specificity <= score } ?? committed.count
        if index == 0 {
            guard let first = committed.first else {
                return FractionalIndex(value: 0)
            }
            return FractionalIndex(value: first.position.value - 1)
        }
        if index == committed.count {
            return FractionalIndex(value: committed[index - 1].position.value + 1)
        }
        return FractionalIndex.between(committed[index - 1].position, committed[index].position)
    }
}
