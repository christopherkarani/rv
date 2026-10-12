import Foundation
import RVDomain
import RVFileStore

/// MCP policy/toolkit file failures. Fixed labels; never paths or contents.
public enum MCPToolPolicyFileError: Error, Sendable, Equatable {
    /// The directory or file failed the owner-only checks.
    case unsafeLocation
    /// The file could not be read.
    case unreadable
    /// The file exceeds the size cap.
    case oversized
    /// The document is malformed or violates a value rule.
    case invalidDocument
    /// The document version is not 1.
    case unsupportedVersion
}

/// One global policy rule loaded from `mcp-policies.json`. Plain data: every
/// field validates at the decode choke point (`MCPToolPolicyFile.decode`),
/// and `encode` plus the store bridges re-validate through
/// `validateModel`, so every consumer fails closed however the value was
/// built. Ids match the sibling stores' identifier charset.
public struct MCPFilePolicy: Sendable, Equatable, Hashable {
    /// Stable rule identity.
    public let id: String
    /// Scope deciding cross-owner precedence.
    public let owner: PolicyOwner
    /// Address matcher in X1-B segment form.
    public let pattern: SegmentPattern
    /// Verdict when the pattern matches.
    public let action: PolicyAction
    /// Fractional rank deciding same-owner order.
    public let position: FractionalIndex

    /// Assembles one rule. The loader validates through
    /// `MCPToolPolicyFile.validateModel`.
    public init(
        id: String,
        owner: PolicyOwner,
        pattern: SegmentPattern,
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

/// One toolkit policy rule loaded from `mcp-toolkits.json`. See
/// `MCPFilePolicy` for the validation contract.
public struct MCPFileToolkitPolicy: Sendable, Equatable, Hashable {
    /// Stable rule identity.
    public let id: String
    /// Address matcher in X1-B segment form.
    public let pattern: SegmentPattern
    /// Verdict when the pattern matches.
    public let action: PolicyAction
    /// Fractional rank deciding order.
    public let position: FractionalIndex

    /// Assembles one rule. The loader validates through
    /// `MCPToolkitFile.validateModel`.
    public init(id: String, pattern: SegmentPattern, action: PolicyAction, position: FractionalIndex) {
        self.id = id
        self.pattern = pattern
        self.action = action
        self.position = position
    }
}

/// One toolkit connection grant loaded from `mcp-toolkits.json`. See
/// `MCPFilePolicy` for the validation contract.
public struct MCPFileToolkitConnection: Sendable, Equatable, Hashable {
    /// Stable grant identity.
    public let id: String
    /// Access matcher in X1-B segment form.
    public let pattern: SegmentPattern
    /// Fractional rank deciding order.
    public let position: FractionalIndex

    /// Assembles one grant. The loader validates through
    /// `MCPToolkitFile.validateModel`.
    public init(id: String, pattern: SegmentPattern, position: FractionalIndex) {
        self.id = id
        self.pattern = pattern
        self.position = position
    }
}

/// One toolkit loaded from `mcp-toolkits.json`. See `MCPFilePolicy` for the
/// validation contract.
public struct MCPFileToolkit: Sendable, Equatable, Hashable {
    /// Stable toolkit identity.
    public let id: String
    /// Scope deciding cross-owner precedence.
    public let owner: PolicyOwner
    /// Globally unique slug.
    public let slug: String
    /// Operator display name.
    public let name: String
    /// Ordered policy rules.
    public let policies: [MCPFileToolkitPolicy]
    /// Ordered connection grants.
    public let connections: [MCPFileToolkitConnection]

    /// Assembles one toolkit. The loader validates through
    /// `MCPToolkitFile.validateModel`.
    public init(
        id: String,
        owner: PolicyOwner,
        slug: String,
        name: String,
        policies: [MCPFileToolkitPolicy],
        connections: [MCPFileToolkitConnection]
    ) {
        self.id = id
        self.owner = owner
        self.slug = slug
        self.name = name
        self.policies = policies
        self.connections = connections
    }
}

/// Loads trusted operator global policy rules from `mcp-policies.json`.
///
/// Rules come ONLY from this operator config file, under the same owner-only,
/// no-symlink, 64KB discipline as the sibling stores
/// (`OwnerOnlyFile.loadBytes`). The document is versioned
/// (`{"version": 1, "policies": [...]}`) with closed key sets at every level:
/// unknown fields fail closed. Every field of every rule is required —
/// positions included, so file order never silently means precedence — and
/// patterns must satisfy the X1-B grammar. Ids match the sibling stores'
/// identifier charset (letters, digits, `-`, `.`, `_`). A missing file
/// loads the empty rule set; every other failure mode fails closed.
public enum MCPToolPolicyFile {
    /// File name under the config directory.
    public static let fileName = "mcp-policies.json"
    /// Read cap shared with the sibling stores.
    public static let maximumBytes = 65_536
    /// Per-file rule cap. The byte cap binds first for realistic rules.
    public static let maximumPolicies = 256
    /// Id byte cap.
    public static let maximumIDBytes = 128

    /// Loads the rule set, or empty when the file is missing.
    public static func load(from configDirectory: URL) -> Result<[MCPFilePolicy], MCPToolPolicyFileError> {
        switch OwnerOnlyFile.loadBytes(
            fileName: fileName, from: configDirectory, maximumBytes: maximumBytes
        ) {
        case .success(let data):
            return decode(data)
        case .failure(let error):
            return mapLoadFailure(error)
        }
    }

    /// Maps a file-read failure onto the store outcome. Split out so every
    /// arm is directly testable: `.unreadable` has no filesystem trigger,
    /// only a unit one. Delegates to the shared `MCPLoadFailure.map`.
    static func mapLoadFailure(_ error: OwnerOnlyFileError) -> Result<[MCPFilePolicy], MCPToolPolicyFileError> {
        MCPLoadFailure.map(
            error, missing: [], unsafeLocation: .unsafeLocation,
            unreadable: .unreadable, oversized: .oversized
        )
    }

    /// Decodes one document. Fails closed on any shape or value violation.
    public static func decode(_ data: Data) -> Result<[MCPFilePolicy], MCPToolPolicyFileError> {
        guard data.count <= maximumBytes else { return .failure(.oversized) }
        guard let document = try? JSONDecoder().decode(PolicyListDocumentDTO.self, from: data) else {
            return .failure(.invalidDocument)
        }
        guard document.version == 1 else { return .failure(.unsupportedVersion) }
        guard document.policies.count <= maximumPolicies else { return .failure(.invalidDocument) }
        var seen = Set<String>()
        var policies: [MCPFilePolicy] = []
        for dto in document.policies {
            guard let policy = resolve(dto) else { return .failure(.invalidDocument) }
            guard seen.insert(policy.id).inserted else { return .failure(.invalidDocument) }
            policies.append(policy)
        }
        return .success(policies)
    }

    /// Canonical bytes for these rules: compact JSON, sorted keys, unescaped
    /// slashes. Re-validates every rule first, so hand-built values that
    /// never saw `decode` fail closed instead of persisting; fails
    /// `.oversized` when the encoding exceeds the read cap. Duplicate ids
    /// fail closed like in `decode`, so encoded bytes always decode.
    public static func encode(_ policies: [MCPFilePolicy]) -> Result<Data, MCPToolPolicyFileError> {
        guard policies.count <= maximumPolicies else { return .failure(.invalidDocument) }
        guard policies.allSatisfy({ validateModel($0) == nil }) else {
            return .failure(.invalidDocument)
        }
        var seen = Set<String>()
        for policy in policies {
            guard seen.insert(policy.id).inserted else { return .failure(.invalidDocument) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let bytes = try? encoder.encode(PolicyListDocument(policies: policies)),
            bytes.count <= maximumBytes
        else { return .failure(.oversized) }
        return .success(bytes)
    }

    /// Per-rule diagnostics for `data`: one `(index, reason)` per problem,
    /// document-level problems at index `-1`. Empty means `decode` succeeds.
    /// Reasons are field labels (`"owner"`, `"pattern"`, `"duplicateID"`),
    /// never values.
    public static func validate(_ data: Data) -> [(index: Int, reason: String)] {
        guard data.count <= maximumBytes else { return [(index: -1, reason: "oversized")] }
        guard let document = try? JSONDecoder().decode(PolicyListDocumentDTO.self, from: data) else {
            return [(index: -1, reason: "invalidDocument")]
        }
        guard document.version == 1 else { return [(index: -1, reason: "unsupportedVersion")] }
        guard document.policies.count <= maximumPolicies else {
            return [(index: -1, reason: "tooManyPolicies")]
        }
        var seen = Set<String>()
        var problems: [(index: Int, reason: String)] = []
        for (index, dto) in document.policies.enumerated() {
            switch resolveOutcome(dto) {
            case .valid(let policy):
                if seen.insert(policy.id).inserted == false {
                    problems.append((index: index, reason: "duplicateID"))
                }
            case .invalid(let reason):
                problems.append((index: index, reason: reason))
            }
        }
        return problems
    }

    /// The value-rule choke point for hand-built models: `encode` and the
    /// store bridges judge through here, since their inputs never saw
    /// `decode`. Nil means valid, otherwise the failing field label (never
    /// the value). The decode path judges the same predicates on the DTO
    /// fields directly (wire shapes need their own labels), so both entries
    /// share `identifier` and the finiteness rule rather than one function.
    public static func validateModel(_ policy: MCPFilePolicy) -> String? {
        guard mcpToolPolicyIdentifier(policy.id, maxBytes: maximumIDBytes) else { return "id" }
        guard policy.position.value.isFinite else { return "position" }
        return nil
    }

    private static func resolve(_ dto: PolicyDTO) -> MCPFilePolicy? {
        resolveOutcome(dto).value
    }

    /// Single DTO-to-model judgment: the model, or the failing field label.
    /// Parses each field exactly once; `decode` takes the model, `validate`
    /// takes the reason.
    private static func resolveOutcome(_ dto: PolicyDTO) -> MCPFileResolveOutcome<MCPFilePolicy> {
        guard mcpToolPolicyIdentifier(dto.id, maxBytes: maximumIDBytes) else { return .invalid(reason: "id") }
        guard let owner = PolicyOwner(rawValue: dto.owner) else { return .invalid(reason: "owner") }
        guard let pattern = try? SegmentPattern.parse(dto.pattern) else {
            return .invalid(reason: "pattern")
        }
        guard let action = PolicyAction(rawValue: dto.action) else { return .invalid(reason: "action") }
        // Decoded Doubles are finite or the DTO decode throws (overflow and
        // non-numeric tokens throw; NaN is unrepresentable in JSON numbers),
        // so `FractionalIndex(value:)` cannot trap here. Infinities stay
        // orderable downstream; only `encode` rejects them (unencodable).
        return .valid(
            MCPFilePolicy(
                id: dto.id, owner: owner, pattern: pattern, action: action,
                position: FractionalIndex(value: dto.position)
            )
        )
    }

}

/// Loads trusted operator toolkits from `mcp-toolkits.json`.
///
/// Same owner-only, no-symlink, 64KB discipline and closed key sets as
/// `MCPToolPolicyFile`. The document is
/// `{"version": 1, "toolkits": [{id, owner, slug, name, policies, connections}]}`.
/// Slugs are globally unique across owners (mirroring the store's
/// `slugInUse` rule); rule ids share one namespace per toolkit across its
/// policies and connections, which is stricter than the store's separate
/// collections and keeps file-authored ids unambiguous. Toolkit, rule, and
/// grant ids match the sibling stores' identifier charset. A missing file
/// loads the empty set; every other failure mode fails closed.
public enum MCPToolkitFile {
    /// File name under the config directory.
    public static let fileName = "mcp-toolkits.json"
    /// Read cap shared with the sibling stores.
    public static let maximumBytes = 65_536
    /// Per-file toolkit cap.
    public static let maximumToolkits = 64
    /// Per-toolkit policy-rule cap.
    public static let maximumPolicies = 256
    /// Per-toolkit connection-grant cap.
    public static let maximumConnections = 256
    /// Id byte cap.
    public static let maximumIDBytes = 128
    /// Name byte cap.
    public static let maximumNameBytes = 256

    /// Loads the toolkit set, or empty when the file is missing.
    public static func load(from configDirectory: URL) -> Result<[MCPFileToolkit], MCPToolPolicyFileError> {
        switch OwnerOnlyFile.loadBytes(
            fileName: fileName, from: configDirectory, maximumBytes: maximumBytes
        ) {
        case .success(let data):
            return decode(data)
        case .failure(let error):
            return mapLoadFailure(error)
        }
    }

    /// Maps a file-read failure onto the store outcome. Split out so every
    /// arm is directly testable: `.unreadable` has no filesystem trigger,
    /// only a unit one. Delegates to the shared `MCPLoadFailure.map`.
    static func mapLoadFailure(_ error: OwnerOnlyFileError) -> Result<[MCPFileToolkit], MCPToolPolicyFileError> {
        MCPLoadFailure.map(
            error, missing: [], unsafeLocation: .unsafeLocation,
            unreadable: .unreadable, oversized: .oversized
        )
    }

    /// Decodes one document. Fails closed on any shape or value violation.
    public static func decode(_ data: Data) -> Result<[MCPFileToolkit], MCPToolPolicyFileError> {
        guard data.count <= maximumBytes else { return .failure(.oversized) }
        guard let document = try? JSONDecoder().decode(ToolkitListDocumentDTO.self, from: data) else {
            return .failure(.invalidDocument)
        }
        guard document.version == 1 else { return .failure(.unsupportedVersion) }
        guard document.toolkits.count <= maximumToolkits else { return .failure(.invalidDocument) }
        var seenIDs = Set<String>()
        var seenSlugs = Set<String>()
        var toolkits: [MCPFileToolkit] = []
        for dto in document.toolkits {
            guard let toolkit = resolve(dto) else { return .failure(.invalidDocument) }
            guard seenIDs.insert(toolkit.id).inserted else { return .failure(.invalidDocument) }
            guard seenSlugs.insert(toolkit.slug).inserted else { return .failure(.invalidDocument) }
            toolkits.append(toolkit)
        }
        return .success(toolkits)
    }

    /// Canonical bytes for these toolkits: compact JSON, sorted keys,
    /// unescaped slashes. Re-validates every record first (see
    /// `MCPToolPolicyFile.encode`); fails `.oversized` when the encoding
    /// exceeds the read cap.
    public static func encode(_ toolkits: [MCPFileToolkit]) -> Result<Data, MCPToolPolicyFileError> {
        guard toolkits.count <= maximumToolkits else { return .failure(.invalidDocument) }
        guard toolkits.allSatisfy({ validateModel($0) == nil }) else {
            return .failure(.invalidDocument)
        }
        var seenIDs = Set<String>()
        var seenSlugs = Set<String>()
        for toolkit in toolkits {
            guard seenIDs.insert(toolkit.id).inserted else { return .failure(.invalidDocument) }
            guard seenSlugs.insert(toolkit.slug).inserted else { return .failure(.invalidDocument) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let bytes = try? encoder.encode(ToolkitListDocument(toolkits: toolkits)),
            bytes.count <= maximumBytes
        else { return .failure(.oversized) }
        return .success(bytes)
    }

    /// Per-toolkit diagnostics for `data`: one `(index, reason)` per problem,
    /// document-level problems at index `-1`. Empty means `decode` succeeds.
    /// Reasons are field paths (`"slug"`, `"policies[2].pattern"`,
    /// `"duplicateSlug"`), never values.
    public static func validate(_ data: Data) -> [(index: Int, reason: String)] {
        guard data.count <= maximumBytes else { return [(index: -1, reason: "oversized")] }
        guard let document = try? JSONDecoder().decode(ToolkitListDocumentDTO.self, from: data) else {
            return [(index: -1, reason: "invalidDocument")]
        }
        guard document.version == 1 else { return [(index: -1, reason: "unsupportedVersion")] }
        guard document.toolkits.count <= maximumToolkits else {
            return [(index: -1, reason: "tooManyToolkits")]
        }
        var seenIDs = Set<String>()
        var seenSlugs = Set<String>()
        var problems: [(index: Int, reason: String)] = []
        for (index, dto) in document.toolkits.enumerated() {
            switch resolveOutcome(dto) {
            case .valid(let toolkit):
                if seenIDs.insert(toolkit.id).inserted == false {
                    problems.append((index: index, reason: "duplicateID"))
                }
                if seenSlugs.insert(toolkit.slug).inserted == false {
                    problems.append((index: index, reason: "duplicateSlug"))
                }
            case .invalid(let reason):
                problems.append((index: index, reason: reason))
            }
        }
        return problems
    }

    /// The value-rule choke point for hand-built models: `encode` and the
    /// store bridges judge through here, since their inputs never saw
    /// `decode`. Nil means valid, otherwise the failing field path (never
    /// the value). The decode path judges the same predicates on the DTO
    /// fields directly (see `MCPToolPolicyFile.validateModel`). File-level
    /// uniqueness (ids, slugs across toolkits) stays with the callers, which
    /// see the whole document.
    public static func validateModel(_ toolkit: MCPFileToolkit) -> String? {
        guard mcpToolPolicyIdentifier(toolkit.id, maxBytes: maximumIDBytes) else { return "id" }
        guard isValidSlug(toolkit.slug) else { return "slug" }
        guard boundedText(toolkit.name, maxBytes: maximumNameBytes) else { return "name" }
        guard toolkit.policies.count <= maximumPolicies else { return "policies" }
        guard toolkit.connections.count <= maximumConnections else { return "connections" }
        var seen = Set<String>()
        for (offset, policy) in toolkit.policies.enumerated() {
            if let reason = validateRule(id: policy.id, position: policy.position) {
                return "policies[\(offset)].\(reason)"
            }
            if seen.insert(policy.id).inserted == false {
                return "policies[\(offset)].duplicateID"
            }
        }
        for (offset, connection) in toolkit.connections.enumerated() {
            if let reason = validateRule(id: connection.id, position: connection.position) {
                return "connections[\(offset)].\(reason)"
            }
            if seen.insert(connection.id).inserted == false {
                return "connections[\(offset)].duplicateID"
            }
        }
        return nil
    }

    private static func validateRule(id: String, position: FractionalIndex) -> String? {
        guard mcpToolPolicyIdentifier(id, maxBytes: maximumIDBytes) else { return "id" }
        guard position.value.isFinite else { return "position" }
        return nil
    }

    private static func resolve(_ dto: ToolkitDTO) -> MCPFileToolkit? {
        resolveOutcome(dto).value
    }

    /// Single DTO-to-model judgment: the model, or the failing field path.
    /// Parses each field exactly once; `decode` takes the model, `validate`
    /// takes the reason. Duplicate rule ids share one namespace per toolkit
    /// across policies and connections: the first repeat wins, policies first.
    private static func resolveOutcome(_ dto: ToolkitDTO) -> MCPFileResolveOutcome<MCPFileToolkit> {
        guard mcpToolPolicyIdentifier(dto.id, maxBytes: maximumIDBytes) else { return .invalid(reason: "id") }
        guard let owner = PolicyOwner(rawValue: dto.owner) else { return .invalid(reason: "owner") }
        guard isValidSlug(dto.slug) else { return .invalid(reason: "slug") }
        guard boundedText(dto.name, maxBytes: maximumNameBytes) else { return .invalid(reason: "name") }
        guard dto.policies.count <= maximumPolicies else { return .invalid(reason: "policies") }
        guard dto.connections.count <= maximumConnections else {
            return .invalid(reason: "connections")
        }
        var seen = Set<String>()
        var policies: [MCPFileToolkitPolicy] = []
        for (offset, rule) in dto.policies.enumerated() {
            switch resolvePolicy(rule) {
            case .valid(let policy):
                if seen.insert(policy.id).inserted == false {
                    return .invalid(reason: "policies[\(offset)].duplicateID")
                }
                policies.append(policy)
            case .invalid(let reason):
                return .invalid(reason: "policies[\(offset)].\(reason)")
            }
        }
        var connections: [MCPFileToolkitConnection] = []
        for (offset, grant) in dto.connections.enumerated() {
            switch resolveConnection(grant) {
            case .valid(let connection):
                if seen.insert(connection.id).inserted == false {
                    return .invalid(reason: "connections[\(offset)].duplicateID")
                }
                connections.append(connection)
            case .invalid(let reason):
                return .invalid(reason: "connections[\(offset)].\(reason)")
            }
        }
        return .valid(
            MCPFileToolkit(
                id: dto.id, owner: owner, slug: dto.slug, name: dto.name,
                policies: policies, connections: connections
            )
        )
    }

    private static func resolvePolicy(_ dto: ToolkitPolicyDTO) -> MCPFileResolveOutcome<MCPFileToolkitPolicy> {
        guard mcpToolPolicyIdentifier(dto.id, maxBytes: maximumIDBytes) else { return .invalid(reason: "id") }
        guard let pattern = try? SegmentPattern.parse(dto.pattern) else {
            return .invalid(reason: "pattern")
        }
        guard let action = PolicyAction(rawValue: dto.action) else { return .invalid(reason: "action") }
        // Decoded Doubles are finite or the DTO decode throws (see
        // `MCPToolPolicyFile.resolveOutcome`); `FractionalIndex(value:)`
        // cannot trap here.
        return .valid(
            MCPFileToolkitPolicy(
                id: dto.id, pattern: pattern, action: action,
                position: FractionalIndex(value: dto.position)
            )
        )
    }

    private static func resolveConnection(_ dto: ToolkitConnectionDTO) -> MCPFileResolveOutcome<MCPFileToolkitConnection> {
        guard mcpToolPolicyIdentifier(dto.id, maxBytes: maximumIDBytes) else { return .invalid(reason: "id") }
        guard let pattern = try? SegmentPattern.parse(dto.pattern) else {
            return .invalid(reason: "pattern")
        }
        // Decoded Doubles are finite or the DTO decode throws (see
        // `MCPToolPolicyFile.resolveOutcome`); `FractionalIndex(value:)`
        // cannot trap here.
        return .valid(
            MCPFileToolkitConnection(
                id: dto.id, pattern: pattern, position: FractionalIndex(value: dto.position)
            )
        )
    }

    /// Executor toolkit slug shape `^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$`
    /// (`server.ts:92`): byte-exact with `MCPToolkitSlug.isValid`, which
    /// RVPolicy cannot import (it lives in RVIsolation). No normalization
    /// here — files must carry the canonical lowercase form.
    private static func isValidSlug(_ slug: String) -> Bool {
        let bytes = Array(slug.utf8)
        guard bytes.count >= 1, bytes.count <= 63 else { return false }
        guard isLowerAlnum(bytes[0]), isLowerAlnum(bytes[bytes.count - 1]) else { return false }
        return bytes.allSatisfy { isLowerAlnum($0) || $0 == 45 }
    }

    private static func isLowerAlnum(_ byte: UInt8) -> Bool {
        (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
    }

    /// Non-empty bounded operator text (toolkit display names). Delegates
    /// the character rule to `OperatorText`: controls, invisible format
    /// characters, and line/paragraph separators all fail closed.
    private static func boundedText(_ value: String, maxBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maxBytes
            && OperatorText.containsDisallowedTextScalar(value) == false
    }

}

/// Short portable machine identifiers (rule, toolkit, and grant ids),
/// matching the sibling stores' charset: ASCII letters, digits, `-`,
/// `.`, `_`. Display names stay with `boundedText`; ids are lookup keys
/// and provenance labels, sometimes embedded in tooling outside this
/// file, and the allow-list keeps them out of every adjacent namespace
/// (paths, approvals fingerprints, shell words). One copy serves both
/// loaders in this file.
private func mcpToolPolicyIdentifier(_ value: String, maxBytes: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maxBytes && value.utf8.allSatisfy {
        ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
            || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 || $0 == 95
    }
}

/// One resolve outcome: the model, or the failing field label (never the
/// value). A `Result` cannot carry a `String` failure, hence the enum.
private enum MCPFileResolveOutcome<Value> {
    case valid(Value)
    case invalid(reason: String)

    var value: Value? {
        if case .valid(let value) = self { return value }
        return nil
    }
}

/// Wire shape `{"version": 1, "policies": [...]}`. Closed keys: unknown
/// members fail closed.
private struct PolicyListDocumentDTO: Decodable {
    let version: Int
    let policies: [PolicyDTO]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(container, allowed: ["version", "policies"])
        version = try container.decode(Int.self, forKey: StrictJSONKey("version"))
        policies = try container.decode([PolicyDTO].self, forKey: StrictJSONKey("policies"))
    }
}

/// One wire rule. Closed keys; every field required (an explicit null fails
/// closed, since only a missing key could read as absent and none is
/// optional). `position` decodes as `Double`: overflow and non-numeric
/// tokens throw, and NaN is unrepresentable in JSON numbers, so the
/// `FractionalIndex(value:)` trap on NaN is unreachable from this path.
private struct PolicyDTO: Decodable {
    let id: String
    let owner: String
    let pattern: String
    let action: String
    let position: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(container, allowed: ["id", "owner", "pattern", "action", "position"])
        id = try container.decode(String.self, forKey: StrictJSONKey("id"))
        owner = try container.decode(String.self, forKey: StrictJSONKey("owner"))
        pattern = try container.decode(String.self, forKey: StrictJSONKey("pattern"))
        action = try container.decode(String.self, forKey: StrictJSONKey("action"))
        position = try container.decode(Double.self, forKey: StrictJSONKey("position"))
    }
}

/// Canonical encoding of a policy list. The encoder writes sorted keys, so
/// member order here is irrelevant.
private struct PolicyListDocument: Encodable {
    let policies: [MCPFilePolicy]

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        try container.encode(1, forKey: StrictJSONKey("version"))
        try container.encode(policies.map(PolicyDocumentEntry.init), forKey: StrictJSONKey("policies"))
    }
}

/// Canonical encoding of one file policy.
private struct PolicyDocumentEntry: Encodable {
    let policy: MCPFilePolicy

    init(_ policy: MCPFilePolicy) {
        self.policy = policy
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        try container.encode(policy.id, forKey: StrictJSONKey("id"))
        try container.encode(policy.owner.rawValue, forKey: StrictJSONKey("owner"))
        try container.encode(policy.pattern.rawValue, forKey: StrictJSONKey("pattern"))
        try container.encode(policy.action.rawValue, forKey: StrictJSONKey("action"))
        try container.encode(policy.position.value, forKey: StrictJSONKey("position"))
    }
}

/// Wire shape `{"version": 1, "toolkits": [...]}`. Closed keys: unknown
/// members fail closed.
private struct ToolkitListDocumentDTO: Decodable {
    let version: Int
    let toolkits: [ToolkitDTO]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(container, allowed: ["version", "toolkits"])
        version = try container.decode(Int.self, forKey: StrictJSONKey("version"))
        toolkits = try container.decode([ToolkitDTO].self, forKey: StrictJSONKey("toolkits"))
    }
}

/// One wire toolkit. Closed keys; `policies` and `connections` are required
/// but may be empty, so file order never silently means precedence.
private struct ToolkitDTO: Decodable {
    let id: String
    let owner: String
    let slug: String
    let name: String
    let policies: [ToolkitPolicyDTO]
    let connections: [ToolkitConnectionDTO]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(
            container,
            allowed: ["id", "owner", "slug", "name", "policies", "connections"]
        )
        id = try container.decode(String.self, forKey: StrictJSONKey("id"))
        owner = try container.decode(String.self, forKey: StrictJSONKey("owner"))
        slug = try container.decode(String.self, forKey: StrictJSONKey("slug"))
        name = try container.decode(String.self, forKey: StrictJSONKey("name"))
        policies = try container.decode([ToolkitPolicyDTO].self, forKey: StrictJSONKey("policies"))
        connections = try container.decode(
            [ToolkitConnectionDTO].self, forKey: StrictJSONKey("connections")
        )
    }
}

/// One wire toolkit rule. Closed keys; every field required.
private struct ToolkitPolicyDTO: Decodable {
    let id: String
    let pattern: String
    let action: String
    let position: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(container, allowed: ["id", "pattern", "action", "position"])
        id = try container.decode(String.self, forKey: StrictJSONKey("id"))
        pattern = try container.decode(String.self, forKey: StrictJSONKey("pattern"))
        action = try container.decode(String.self, forKey: StrictJSONKey("action"))
        position = try container.decode(Double.self, forKey: StrictJSONKey("position"))
    }
}

/// One wire connection grant. Closed keys; every field required.
private struct ToolkitConnectionDTO: Decodable {
    let id: String
    let pattern: String
    let position: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(container, allowed: ["id", "pattern", "position"])
        id = try container.decode(String.self, forKey: StrictJSONKey("id"))
        pattern = try container.decode(String.self, forKey: StrictJSONKey("pattern"))
        position = try container.decode(Double.self, forKey: StrictJSONKey("position"))
    }
}

/// Canonical encoding of a toolkit list.
private struct ToolkitListDocument: Encodable {
    let toolkits: [MCPFileToolkit]

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        try container.encode(1, forKey: StrictJSONKey("version"))
        try container.encode(toolkits.map(ToolkitDocumentEntry.init), forKey: StrictJSONKey("toolkits"))
    }
}

/// Canonical encoding of one file toolkit.
private struct ToolkitDocumentEntry: Encodable {
    let toolkit: MCPFileToolkit

    init(_ toolkit: MCPFileToolkit) {
        self.toolkit = toolkit
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        try container.encode(toolkit.id, forKey: StrictJSONKey("id"))
        try container.encode(toolkit.owner.rawValue, forKey: StrictJSONKey("owner"))
        try container.encode(toolkit.slug, forKey: StrictJSONKey("slug"))
        try container.encode(toolkit.name, forKey: StrictJSONKey("name"))
        try container.encode(
            toolkit.policies.map(ToolkitPolicyDocumentEntry.init), forKey: StrictJSONKey("policies")
        )
        try container.encode(
            toolkit.connections.map(ToolkitConnectionDocumentEntry.init),
            forKey: StrictJSONKey("connections")
        )
    }
}

/// Canonical encoding of one file toolkit rule.
private struct ToolkitPolicyDocumentEntry: Encodable {
    let policy: MCPFileToolkitPolicy

    init(_ policy: MCPFileToolkitPolicy) {
        self.policy = policy
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        try container.encode(policy.id, forKey: StrictJSONKey("id"))
        try container.encode(policy.pattern.rawValue, forKey: StrictJSONKey("pattern"))
        try container.encode(policy.action.rawValue, forKey: StrictJSONKey("action"))
        try container.encode(policy.position.value, forKey: StrictJSONKey("position"))
    }
}

/// Canonical encoding of one file connection grant.
private struct ToolkitConnectionDocumentEntry: Encodable {
    let connection: MCPFileToolkitConnection

    init(_ connection: MCPFileToolkitConnection) {
        self.connection = connection
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        try container.encode(connection.id, forKey: StrictJSONKey("id"))
        try container.encode(connection.pattern.rawValue, forKey: StrictJSONKey("pattern"))
        try container.encode(connection.position.value, forKey: StrictJSONKey("position"))
    }
}
