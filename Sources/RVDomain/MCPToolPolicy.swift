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

/// Address matcher: exact, universal, trailing-`*`, or one mid-`*`.
public enum ToolPattern: Sendable, Equatable, Hashable, Codable {
    /// Matches one validated address.
    case exact(MCPToolAddress)
    /// Matches every address.
    case any
    /// Matches literals starting with this prefix at a segment boundary: the
    /// prefix must consume the whole literal, end in a dot, or stop before a
    /// dot, so `…conn.read` never approves `…conn.readAdminKeys`.
    case trailingPrefix(String)
    /// Matches literals starting with `prefix` and ending with `suffix` around a non-empty middle.
    case singleMid(prefix: String, suffix: String)

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
        }
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
