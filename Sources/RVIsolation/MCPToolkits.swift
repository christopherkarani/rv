import Foundation
import RVDomain
import RVPolicy

/// Toolkit slug: `1-63` lowercase letters, numbers, or hyphens, never starting
/// or ending with a hyphen. Ports Executor `slugPattern` +
/// `normalizeSlugEffect` (`server.ts:92-116`): input is trimmed and lowercased
/// before the shape check, so `parse` accepts padded or uppercase spellings of
/// an otherwise valid slug.
public struct MCPToolkitSlug: Sendable, Equatable, Hashable {
    /// Canonical slug text.
    public let rawValue: String

    private init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Normalizes (trim + lowercase) then validates. Fails closed on any shape
    /// violation; the error never echoes the rejected input.
    ///
    /// Identifier validation comes in three styles across the codebase —
    /// throwing parse (here), failable init (`MCPPluginKey`), and boolean
    /// predicate (the policy-file `identifier`) — each fitting its use
    /// (load-time errors, optional drops, predicate filters). New throwing
    /// loads align on this style; the other two stay as they are.
    public static func parse(_ raw: String) throws(MCPToolkitError) -> MCPToolkitSlug {
        let slug = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isValid(slug) else {
            throw MCPToolkitError.invalidSlug
        }
        return MCPToolkitSlug(rawValue: slug)
    }

    /// True exactly for `^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$`.
    public static func isValid(_ slug: String) -> Bool {
        let bytes = Array(slug.utf8)
        guard bytes.count >= 1, bytes.count <= 63 else { return false }
        guard isLowerAlnum(bytes[0]), isLowerAlnum(bytes[bytes.count - 1]) else { return false }
        return bytes.allSatisfy { isLowerAlnum($0) || $0 == 45 }
    }

    /// Executor `slugify` (`server.ts:94-100`): trim, lowercase, every
    /// non-`[a-z0-9]` run becomes one `-`, leading/trailing separators dropped,
    /// capped at 63 characters. The result may still be empty (a name with no
    /// slug characters), which `parse` then rejects.
    public static func slugify(_ name: String) -> String {
        var out = ""
        var pendingSeparator = false
        for scalar in name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().unicodeScalars {
            let code = scalar.value
            if (code >= 97 && code <= 122) || (code >= 48 && code <= 57) {
                if pendingSeparator, out.isEmpty == false {
                    out.append("-")
                }
                pendingSeparator = false
                out.append(Character(scalar))
            } else {
                pendingSeparator = true
            }
        }
        if out.count > 63 {
            out = String(out.prefix(63))
        }
        return out
    }

    private static func isLowerAlnum(_ byte: UInt8) -> Bool {
        (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
    }
}

/// Toolkit management failures. Fixed labels; never ids, slugs, or patterns.
public enum MCPToolkitError: Error, Sendable, Equatable {
    /// The name is empty after trimming.
    case invalidName
    /// The slug violates the slug shape.
    case invalidSlug
    /// Another toolkit already holds the slug. Slugs are global across owners.
    case slugInUse
    /// No toolkit holds the id.
    case toolkitNotFound
    /// The pattern violates the X1-B grammar.
    case invalidPattern
    /// No policy of the toolkit holds the id.
    case policyNotFound
    /// No connection of the toolkit holds the id.
    case connectionNotFound
}

/// One ordered toolkit policy rule: matcher, verdict, and rank position.
/// Ports Executor `ToolkitPolicyRecord` (`server.ts:37-46`); timestamps are
/// dropped (RV rules carry no clock: `ToolPolicy` has none either).
public struct MCPToolkitPolicy: Sendable, Equatable, Hashable {
    /// Stable rule identity.
    public let id: String
    /// Address matcher in X1-B segment form.
    public let pattern: SegmentPattern
    /// Verdict when the pattern matches.
    public let action: PolicyAction
    /// Fractional rank deciding order.
    public let position: FractionalIndex

    /// Assembles one rule from validated parts.
    public init(id: String, pattern: SegmentPattern, action: PolicyAction, position: FractionalIndex) {
        self.id = id
        self.pattern = pattern
        self.action = action
        self.position = position
    }

    /// Canonical raw pattern text. Round-trips through `SegmentPattern.parse`.
    public var rawPattern: String {
        pattern.rawValue
    }
}

/// One ordered toolkit connection grant: matcher plus rank position. Ports
/// Executor `ToolkitConnectionRecord` (`server.ts:48-56`).
public struct MCPToolkitConnection: Sendable, Equatable, Hashable {
    /// Stable grant identity.
    public let id: String
    /// Access matcher in X1-B segment form.
    public let pattern: SegmentPattern
    /// Fractional rank deciding order.
    public let position: FractionalIndex

    /// Assembles one grant from validated parts.
    public init(id: String, pattern: SegmentPattern, position: FractionalIndex) {
        self.id = id
        self.pattern = pattern
        self.position = position
    }

    /// Canonical raw pattern text. Round-trips through `SegmentPattern.parse`.
    public var rawPattern: String {
        pattern.rawValue
    }
}

/// One toolkit: an owner-scoped, slug-addressed bundle of ordered connection
/// grants plus ordered policy rules. Ports Executor `ToolkitRecord` plus its
/// rule collections (`server.ts:28-76`). Rule arrays are always sorted by
/// (`position`, `id`); every constructor re-sorts, so the invariant holds for
/// hand-built values too.
public struct MCPToolkit: Sendable, Equatable, Hashable {
    /// Stable toolkit identity.
    public let id: String
    /// Scope deciding cross-owner precedence and the org personal-tool pin.
    public let owner: PolicyOwner
    /// Globally unique slug addressing this toolkit.
    public let slug: MCPToolkitSlug
    /// Operator display name.
    public let name: String
    /// Ordered policy rules, sorted by (`position`, `id`).
    public let policies: [MCPToolkitPolicy]
    /// Ordered connection grants, sorted by (`position`, `id`).
    public let connections: [MCPToolkitConnection]

    /// Assembles one toolkit, sorting both rule arrays by (`position`, `id`).
    public init(
        id: String,
        owner: PolicyOwner,
        slug: MCPToolkitSlug,
        name: String,
        policies: [MCPToolkitPolicy] = [],
        connections: [MCPToolkitConnection] = []
    ) {
        self.id = id
        self.owner = owner
        self.slug = slug
        self.name = name
        self.policies = policies.sorted { ($0.position, $0.id) < ($1.position, $1.id) }
        self.connections = connections.sorted { ($0.position, $0.id) < ($1.position, $1.id) }
    }

    /// Bridges a file record. Fails when the slug is unparseable or the
    /// record violates the loader's value rules (id charset, canonical slug
    /// shape, name text, nested caps and id uniqueness): the file decode
    /// path rejects those before this runs, so a nil here means a
    /// hand-built record that never saw the loader. Patterns, actions, and
    /// positions are strong types shared with the loader, so no other check
    /// can fail. Wave-2 wiring must chain decode → validate → bridge in
    /// that order and surface each stage's diagnostics, never a bare nil.
    public init?(file: MCPFileToolkit) {
        guard let slug = try? MCPToolkitSlug.parse(file.slug) else {
            return nil
        }
        guard MCPToolkitFile.validateModel(file) == nil else {
            return nil
        }
        self.init(
            id: file.id,
            owner: file.owner,
            slug: slug,
            name: file.name,
            policies: file.policies.map {
                MCPToolkitPolicy(id: $0.id, pattern: $0.pattern, action: $0.action, position: $0.position)
            },
            connections: file.connections.map {
                MCPToolkitConnection(id: $0.id, pattern: $0.pattern, position: $0.position)
            }
        )
    }
}

/// One matched rule inside a toolkit verdict: the rule id plus the toolkit
/// scope it won under. Executor resolutions carry no owner (provider rules
/// are ownerless); RV pairs the match with the toolkit owner so the verdict
/// maps onto `PolicyProvenance.pattern` without inventing scope.
public struct MCPToolkitMatch: Sendable, Equatable, Hashable {
    /// The winning rule id.
    public let id: String
    /// The toolkit scope the rule won under.
    public let owner: PolicyOwner

    /// Pairs one winning rule with its scope.
    public init(id: String, owner: PolicyOwner) {
        self.id = id
        self.owner = owner
    }
}

/// One toolkit resolution: the verdict plus the rule that won, if any. Ports
/// Executor `EffectivePolicy` for the toolkit path (`server.ts:183-201`):
/// a match carries its rule, the allowlist boundary and the plugin default
/// carry none (both map onto `PolicyProvenance.fallback`, distinguished by
/// the action: the boundary always blocks).
public struct MCPToolkitVerdict: Sendable, Equatable, Hashable {
    /// Verdict the invoker must enforce.
    public let action: PolicyAction
    /// The winning rule, or nil for the allowlist boundary / plugin default.
    public let match: MCPToolkitMatch?

    /// Assembles one verdict with its optional match.
    public init(action: PolicyAction, match: MCPToolkitMatch? = nil) {
        self.action = action
        self.match = match
    }

    /// Maps onto the shared verdict shape: a match becomes a pattern win,
    /// anything else the fallback carrying this action.
    public func effectivePolicy() -> EffectivePolicy {
        guard let match else {
            return EffectivePolicy(action: action, provenance: .fallback)
        }
        return EffectivePolicy(action: action, provenance: .pattern(id: match.id, owner: match.owner))
    }
}

extension MCPToolkit {
    /// Resolves one tool-id literal against this toolkit's rules. Ports
    /// Executor `digestToolkitRules` + `resolveToolkitPolicy`
    /// (`server.ts:167-201`): connection grants plus legacy approve rows form
    /// the access set (a miss blocks at the boundary), then the first
    /// matching non-legacy policy in (`position`, `id`) order wins, else the
    /// injected default carries with no match.
    ///
    /// The default arrives as a full `PolicyAction` rather than Executor's
    /// `defaultRequiresApproval` boolean: `approve`/`requireApproval` map the
    /// boolean arms, and `block` lets a store with a block default keep it
    /// instead of weakening to a prompt.
    public func resolve(literal toolID: String, defaultAction: PolicyAction) -> MCPToolkitVerdict {
        let legacyIDs = legacyPolicyIDs()
        let connected = accessPatterns(legacyIDs: legacyIDs).contains { $0.matches(literal: toolID) }
        guard connected else {
            return MCPToolkitVerdict(action: .block)
        }
        for policy in policies where legacyIDs.contains(policy.id) == false {
            if policy.pattern.matches(literal: toolID) {
                return MCPToolkitVerdict(
                    action: policy.action,
                    match: MCPToolkitMatch(id: policy.id, owner: owner)
                )
            }
        }
        return MCPToolkitVerdict(action: defaultAction)
    }

    /// Non-legacy policies as provider rules, in precedence order. Ports
    /// Executor `policyRulesForSlug` (`server.ts:525-542`); the caller filters
    /// by slug before calling.
    public func providerRules() -> [MCPToolPolicyProviderRule] {
        let legacyIDs = legacyPolicyIDs()
        return policies
            .filter { legacyIDs.contains($0.id) == false }
            .map {
                MCPToolPolicyProviderRule(
                    id: $0.id,
                    pattern: $0.pattern,
                    action: $0.action,
                    position: $0.position,
                    owner: owner
                )
            }
    }

    /// The dynamic-tool prefixes this toolkit's access set can reach. Ports
    /// Executor `toolkitDynamicScope` (`server.ts:207-223`): an org toolkit
    /// never reaches personal rows, so unowned prefixes pin to org and
    /// user-only prefixes drop; the per-tool check still enforces the same
    /// rule for anything the prefix cannot express.
    public func dynamicScope() -> [MCPDynamicToolScope] {
        var scopes: [MCPDynamicToolScope] = []
        for pattern in accessPatterns(legacyIDs: legacyPolicyIDs()) {
            guard let scope = MCPDynamicToolScope.forPattern(pattern) else {
                continue
            }
            if owner == .user {
                scopes.append(scope)
                continue
            }
            if scope.owner == "user" {
                continue
            }
            if scope.owner == nil {
                scopes.append(
                    MCPDynamicToolScope(
                        integration: scope.integration,
                        owner: "org",
                        connection: scope.connection
                    )
                )
            } else {
                scopes.append(scope)
            }
        }
        return scopes
    }

    /// Access matchers: connection grants plus legacy approve rows. Ports the
    /// `accessPatterns` half of `digestToolkitRules` (`server.ts:170-176`).
    private func accessPatterns(legacyIDs: Set<String>) -> [SegmentPattern] {
        connections.map(\.pattern)
            + policies.filter { legacyIDs.contains($0.id) }.map(\.pattern)
    }

    /// Ids of legacy connection-approve rows: `approve` rows at a
    /// connection-root shape that no connection grant already covers. Ports
    /// Executor `legacyConnectionPolicyIds` + `isLegacyConnectionPolicy`
    /// (`server.ts:150-154`, `server.ts:225-238`).
    ///
    /// RV adaptation: Executor counts segments of a prefix-less tool id, so a
    /// connection root is 3-4 parts; RV literals carry the `tools.` root, so
    /// the same shapes read 3-4 parts after stripping it. Patterns without
    /// the root keep their raw count, exactly as in the Executor.
    private func legacyPolicyIDs() -> Set<String> {
        Set(
            policies
                .filter { Self.isLegacyConnectionPolicy($0) }
                .filter { policy in
                    connections.contains { policy.pattern.matches(literal: $0.rawPattern) } == false
                }
                .map(\.id)
        )
    }

    private static func isLegacyConnectionPolicy(_ policy: MCPToolkitPolicy) -> Bool {
        guard policy.action == .approve else { return false }
        let parts = strippedSegments(policy.rawPattern)
        return parts.last == "*" && (parts.count == 3 || parts.count == 4)
    }

    /// Splits a raw pattern, dropping the `tools.` root when present so the
    /// remainder counts like an Executor tool id.
    fileprivate static func strippedSegments(_ raw: String) -> [String] {
        var parts = raw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.first == "tools" {
            parts.removeFirst()
        }
        return parts
    }

    /// True when the literal names a personal (`user`-owned) dynamic tool.
    /// Ports Executor `isPersonalDynamicToolId` (`server.ts:240`) with the
    /// same `tools.`-root adaptation as `strippedSegments`.
    fileprivate static func isPersonalToolID(_ toolID: String) -> Bool {
        let parts = strippedSegments(toolID)
        return parts.count >= 2 && parts[1] == "user"
    }
}

/// One reachable prefix of a dynamic tool id
/// `tools.<integration>.<owner>.<connection>.<tool>`. Ports Executor
/// `DynamicToolScope` (`policies.ts:130-136`): nil in a position means any
/// value, all three nil means unbounded.
public struct MCPDynamicToolScope: Sendable, Equatable, Hashable {
    /// Required integration, or any when nil.
    public let integration: String?
    /// Required owner, or any when nil.
    public let owner: String?
    /// Required connection, or any when nil.
    public let connection: String?

    /// Assembles one reachable prefix.
    public init(integration: String?, owner: String?, connection: String?) {
        self.integration = integration
        self.owner = owner
        self.connection = connection
    }

    /// True when every position is nil: the scope reaches every dynamic tool.
    /// Ports Executor `isUnboundedDynamicToolScope` (`policies.ts:138-139`).
    public var isUnbounded: Bool {
        integration == nil && owner == nil && connection == nil
    }

    /// True when the address sits under this prefix.
    public func contains(_ address: MCPToolAddress) -> Bool {
        (integration == nil || integration == address.integration)
            && (owner == nil || owner == address.owner)
            && (connection == nil || connection == address.connection)
    }

    /// Scope-narrowed allow check over one operation's scopes. Ports the
    /// core read-side contract (`plugin.ts: PreparedToolPolicy.dynamicScope`):
    /// nil scopes mean the source is not an allowlist (unrestricted read),
    /// an empty array means no dynamic tool is reachable, otherwise the
    /// address must sit under at least one prefix.
    public static func allows(_ address: MCPToolAddress, scopes: [MCPDynamicToolScope]?) -> Bool {
        guard let scopes else { return true }
        return scopes.contains { $0.contains(address) }
    }

    /// Builds the discovery `isBlocked` predicate for these scopes, so
    /// toolkit scoping plugs into `MCPRegistry` search/list/describe
    /// without hand-translation: nil scopes block nothing (unrestricted
    /// read), an empty array blocks everything, otherwise an address is
    /// blocked unless it sits under at least one prefix.
    public static func blockedPredicate(
        scopes: [MCPDynamicToolScope]?
    ) -> @Sendable (MCPToolAddress) -> Bool {
        { address in allows(address, scopes: scopes) == false }
    }

    /// The prefix of dynamic tool ids a pattern can match, or nil when it can
    /// match none. Ports Executor `dynamicToolScopeForPattern`
    /// (`policies.ts:147-164`): a dynamic tool id has at least four
    /// `tools.`-rooted segments, so an exact pattern shorter than that reaches
    /// only static tools; a trailing `*` covers every deeper segment while a
    /// mid-pattern `*` covers exactly its own position (also "any value" for
    /// that position); a literal owner outside `org`/`user` names a static
    /// namespace. The universal pattern is unbounded. The one adaptation is
    /// the `tools.` root: patterns matching RV addresses carry it, so it is
    /// stripped before counting; patterns without it keep Executor counting
    /// verbatim (they match nothing, but the scope stays a safe
    /// over-approximation because resolution still gates per tool).
    public static func forPattern(_ pattern: SegmentPattern) -> MCPDynamicToolScope? {
        switch pattern {
        case .any:
            return MCPDynamicToolScope(integration: nil, owner: nil, connection: nil)
        case .exact(let segments):
            return scope(segments: segments.map { Optional($0) }, subtree: false)
        case .wildcard(let segments, let subtree):
            return scope(
                segments: segments.map { segment in
                    if case .literal(let text) = segment {
                        return text
                    }
                    return nil
                },
                subtree: subtree
            )
        }
    }

    private static func scope(segments: [String?], subtree: Bool) -> MCPDynamicToolScope? {
        var parts = segments
        if let first = parts.first, first == "tools" {
            parts.removeFirst()
        }
        if subtree == false, parts.count < 4 {
            return nil
        }
        let owner = at(parts, 1)
        if owner != nil, owner != "org", owner != "user" {
            return nil
        }
        return MCPDynamicToolScope(integration: at(parts, 0), owner: owner, connection: at(parts, 2))
    }

    private static func at(_ parts: [String?], _ index: Int) -> String? {
        guard index < parts.count else { return nil }
        return parts[index]
    }
}

/// One policy-shaped row from an alternate rule source. Ports Executor
/// `ToolPolicyProviderRule` (`plugin.ts:109-114`); the `owner` is RV's
/// addition (provider rules are ownerless in the Executor) so a provider
/// win keeps `PolicyProvenance.pattern` scope instead of inventing it.
public struct MCPToolPolicyProviderRule: Sendable, Equatable, Hashable {
    /// Stable rule identity.
    public let id: String
    /// Address matcher in X1-B segment form.
    public let pattern: SegmentPattern
    /// Verdict when the pattern matches.
    public let action: PolicyAction
    /// Fractional rank deciding order.
    public let position: FractionalIndex
    /// Scope the rule wins under.
    public let owner: PolicyOwner

    /// Assembles one provider rule from validated parts.
    public init(
        id: String,
        pattern: SegmentPattern,
        action: PolicyAction,
        position: FractionalIndex,
        owner: PolicyOwner
    ) {
        self.id = id
        self.pattern = pattern
        self.action = action
        self.position = position
        self.owner = owner
    }
}

/// Alternate rule source for one policy store. Ports Executor
/// `ToolPolicyProvider` (`plugin.ts:116-141`): core still owns enforcement,
/// the provider owns where the policy-shaped rows live. Only `list` is
/// required; `resolve`/`prepare` default to nil (unimplemented) and the
/// consumer falls through. Precedence is prepared, then resolve, then list
/// (Executor `listActivePolicyRuleSet`, `executor.ts:5461-5489`).
///
/// Snapshot rule: providers hold values, so a provider created from a store
/// freezes that store's rules; rebuilding the store requires re-creating the
/// provider. In particular `prepare` snapshots once per operation and must
/// not be memoized across operations (Executor `plugin.ts:129-139`).
public protocol MCPToolPolicyProvider: Sendable {
    /// Every rule of this source, unsorted; the consumer orders them.
    func list() -> [MCPToolPolicyProviderRule]
    /// Direct resolution, or nil when unimplemented (fall through to `list`).
    func resolve(_ address: MCPToolAddress, defaultAction: PolicyAction) -> EffectivePolicy?
    /// Batched per-operation snapshot, or nil when unimplemented.
    func prepare() -> MCPPreparedToolPolicy?
}

extension MCPToolPolicyProvider {
    /// Default: direct resolution unimplemented; the consumer uses `list`.
    public func resolve(_ address: MCPToolAddress, defaultAction: PolicyAction) -> EffectivePolicy? {
        nil
    }

    /// Default: batched snapshots unimplemented; the consumer uses `resolve`.
    public func prepare() -> MCPPreparedToolPolicy? {
        nil
    }
}

/// What `MCPToolPolicyProvider.prepare` hands the consumer for one operation.
/// Ports Executor `PreparedToolPolicy` (`plugin.ts:144-164`): a pure resolver
/// over the snapshot `prepare` fetched, plus the dynamic-tool prefixes this
/// source can ever approve (nil when the source is not an allowlist, so the
/// consumer keeps the unrestricted read; empty when nothing is reachable).
public struct MCPPreparedToolPolicy: Sendable {
    /// Pure resolver over the snapshot. Takes the tool address plus the
    /// ambient default for unmatched-but-connected tools.
    public let resolve: @Sendable (MCPToolAddress, PolicyAction) -> EffectivePolicy
    /// Reachable dynamic-tool prefixes, or nil for an unrestricted source.
    public let dynamicScope: [MCPDynamicToolScope]?

    /// Assembles one prepared snapshot.
    public init(
        resolve: @escaping @Sendable (MCPToolAddress, PolicyAction) -> EffectivePolicy,
        dynamicScope: [MCPDynamicToolScope]?
    ) {
        self.resolve = resolve
        self.dynamicScope = dynamicScope
    }
}

/// The policy provider for one toolkit slug. Ports Executor
/// `makePolicyProvider` (`server.ts:717-730`): `list` serves the slug's
/// non-legacy rules, `resolve` enforces the full access-set-plus-rules
/// resolution, and `prepare` snapshots both plus the dynamic scope. An
/// unknown slug resolves every tool to the allowlist boundary block.
/// Snapshots the store at creation; see `MCPToolPolicyProvider`.
public struct MCPToolkitPolicyProvider: MCPToolPolicyProvider, Sendable {
    private let store: MCPToolkitStore
    private let slug: String

    /// Binds one slug of one store snapshot.
    public init(store: MCPToolkitStore, slug: String) {
        self.store = store
        self.slug = slug
    }

    /// The slug's non-legacy rules, in precedence order.
    public func list() -> [MCPToolPolicyProviderRule] {
        store.policyRulesForSlug(slug)
    }

    /// Full toolkit resolution for one address.
    public func resolve(_ address: MCPToolAddress, defaultAction: PolicyAction) -> EffectivePolicy? {
        store.resolvePolicyForSlug(slug, toolID: address.literal, defaultAction: defaultAction)
            .effectivePolicy()
    }

    /// Snapshots rules plus dynamic scope for one operation.
    public func prepare() -> MCPPreparedToolPolicy? {
        store.preparePolicyResolverForSlug(slug)
    }
}

/// Immutable toolkit store: slug-addressed toolkits with ordered connection
/// grants and ordered policy rules. Ports the Executor toolkits extension
/// (`server.ts:276-608`) as values: every mutation returns the next store
/// plus the affected record, so callers thread state functionally. The
/// eleven Executor endpoints map onto `list`/`create`/`update`/`remove`,
/// `listPolicies`/`createPolicy`/`updatePolicy`/`removePolicy`, and
/// `listConnections`/`createConnection`/`removeConnection` (`shared.ts:86-166`).
public struct MCPToolkitStore: Sendable, Equatable {
    private let toolkits: [MCPToolkit]

    /// Builds a store over these toolkits.
    public init(toolkits: [MCPToolkit] = []) {
        self.toolkits = toolkits
    }

    /// Bridges validated file records. Fails when any record violates the
    /// loader's value rules, or when two records share an id or a slug
    /// (the file decode path rejects those before this runs, so a nil here
    /// means hand-built records that never saw the loader). Wave-2 wiring
    /// must surface decode/validate diagnostics, never this bare nil.
    public init?(fileToolkits: [MCPFileToolkit]) {
        var bridged: [MCPToolkit] = []
        var seenIDs = Set<String>()
        var seenSlugs = Set<String>()
        for file in fileToolkits {
            guard let toolkit = MCPToolkit(file: file) else {
                return nil
            }
            guard seenIDs.insert(toolkit.id).inserted else {
                return nil
            }
            guard seenSlugs.insert(toolkit.slug.rawValue).inserted else {
                return nil
            }
            bridged.append(toolkit)
        }
        self.init(toolkits: bridged)
    }

    /// Every toolkit: org first, then name, then slug. Ports the extension
    /// `list` ordering (`server.ts:279-293`). Ordering is deterministic byte
    /// order, not locale order (Executor `localeCompare`); the org-first and
    /// slug-tiebreak tiers match exactly.
    public func list() -> [MCPToolkit] {
        toolkits.sorted {
            if $0.owner != $1.owner {
                return $0.owner == .org
            }
            if $0.name != $1.name {
                return $0.name < $1.name
            }
            return $0.slug.rawValue < $1.slug.rawValue
        }
    }

    /// Creates one toolkit. Ports the extension `create` (`server.ts:351-369`):
    /// the name must be non-empty after trimming, the slug defaults to the
    /// slugified name, and slugs are unique across owners.
    public func create(
        owner: PolicyOwner,
        name: String,
        slug rawSlug: String? = nil
    ) -> Result<(MCPToolkitStore, MCPToolkit), MCPToolkitError> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return .failure(.invalidName)
        }
        guard let slug = try? MCPToolkitSlug.parse(rawSlug ?? MCPToolkitSlug.slugify(trimmed)) else {
            return .failure(.invalidSlug)
        }
        guard toolkits.contains(where: { $0.slug == slug }) == false else {
            return .failure(.slugInUse)
        }
        let toolkit = MCPToolkit(id: Self.nextID(prefix: "tk"), owner: owner, slug: slug, name: trimmed)
        return .success((MCPToolkitStore(toolkits: toolkits + [toolkit]), toolkit))
    }

    /// Renames and/or re-slugs one toolkit. Ports the extension `update`
    /// (`server.ts:371-387`): absent fields keep their values, an explicit
    /// slug re-normalizes, and the slug check ignores the toolkit itself.
    public func update(
        _ id: String,
        name: String? = nil,
        slug rawSlug: String? = nil
    ) -> Result<(MCPToolkitStore, MCPToolkit), MCPToolkitError> {
        guard let index = toolkits.firstIndex(where: { $0.id == id }) else {
            return .failure(.toolkitNotFound)
        }
        let existing = toolkits[index]
        let renamed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? existing.name
        guard renamed.isEmpty == false else {
            return .failure(.invalidName)
        }
        let slug: MCPToolkitSlug
        if let rawSlug {
            guard let parsed = try? MCPToolkitSlug.parse(rawSlug) else {
                return .failure(.invalidSlug)
            }
            slug = parsed
        } else {
            slug = existing.slug
        }
        let collision = toolkits.contains { $0.slug == slug && $0.id != id }
        guard collision == false else {
            return .failure(.slugInUse)
        }
        let updated = MCPToolkit(
            id: existing.id,
            owner: existing.owner,
            slug: slug,
            name: renamed,
            policies: existing.policies,
            connections: existing.connections
        )
        var next = toolkits
        next[index] = updated
        return .success((MCPToolkitStore(toolkits: next), updated))
    }

    /// Removes one toolkit with all its rules. Ports the extension `remove`
    /// cascade (`server.ts:389-408`): value removal drops the rules with the
    /// toolkit, so no orphan sweep exists.
    public func remove(_ id: String) -> Result<MCPToolkitStore, MCPToolkitError> {
        guard toolkits.contains(where: { $0.id == id }) else {
            return .failure(.toolkitNotFound)
        }
        return .success(MCPToolkitStore(toolkits: toolkits.filter { $0.id != id }))
    }

    /// One toolkit's ordered policies. Ports the extension `listPolicies`
    /// (`server.ts:410-411`).
    public func listPolicies(_ toolkitID: String) -> Result<[MCPToolkitPolicy], MCPToolkitError> {
        guard let toolkit = toolkit(id: toolkitID) else {
            return .failure(.toolkitNotFound)
        }
        return .success(toolkit.policies)
    }

    /// Appends one policy rule. Ports the extension `createPolicy`
    /// (`server.ts:413-445`): the pattern must parse, and an absent position
    /// lands above the current minimum (top of the list, highest precedence).
    public func createPolicy(
        _ toolkitID: String,
        pattern rawPattern: String,
        action: PolicyAction,
        position: FractionalIndex? = nil
    ) -> Result<(MCPToolkitStore, MCPToolkitPolicy), MCPToolkitError> {
        guard let parsed = try? SegmentPattern.parse(rawPattern) else {
            return .failure(.invalidPattern)
        }
        guard let index = toolkits.firstIndex(where: { $0.id == toolkitID }) else {
            return .failure(.toolkitNotFound)
        }
        let existing = toolkits[index]
        let policy = MCPToolkitPolicy(
            id: Self.nextID(prefix: "tkpol"),
            pattern: parsed,
            action: action,
            position: position ?? Self.topPosition(below: existing.policies.map(\.position))
        )
        return .success((replacing(index, policies: existing.policies + [policy]), policy))
    }

    /// Mutates one policy rule in place. Ports the extension `updatePolicy`
    /// (`server.ts:447-472`): absent fields keep their values, an explicit
    /// pattern re-validates.
    public func updatePolicy(
        _ toolkitID: String,
        _ policyID: String,
        pattern rawPattern: String? = nil,
        action: PolicyAction? = nil,
        position: FractionalIndex? = nil
    ) -> Result<(MCPToolkitStore, MCPToolkitPolicy), MCPToolkitError> {
        let parsed: SegmentPattern?
        if let rawPattern {
            guard let reparsed = try? SegmentPattern.parse(rawPattern) else {
                return .failure(.invalidPattern)
            }
            parsed = reparsed
        } else {
            parsed = nil
        }
        guard let index = toolkits.firstIndex(where: { $0.id == toolkitID }) else {
            return .failure(.toolkitNotFound)
        }
        let existing = toolkits[index]
        guard let policyIndex = existing.policies.firstIndex(where: { $0.id == policyID }) else {
            return .failure(.policyNotFound)
        }
        let current = existing.policies[policyIndex]
        var next = existing.policies
        let updated = MCPToolkitPolicy(
            id: current.id,
            pattern: parsed ?? current.pattern,
            action: action ?? current.action,
            position: position ?? current.position
        )
        next[policyIndex] = updated
        return .success((replacing(index, policies: next), updated))
    }

    /// Drops one policy rule. Ports the extension `removePolicy`
    /// (`server.ts:474-479`).
    public func removePolicy(
        _ toolkitID: String,
        _ policyID: String
    ) -> Result<MCPToolkitStore, MCPToolkitError> {
        guard let index = toolkits.firstIndex(where: { $0.id == toolkitID }) else {
            return .failure(.toolkitNotFound)
        }
        let existing = toolkits[index]
        guard existing.policies.contains(where: { $0.id == policyID }) else {
            return .failure(.policyNotFound)
        }
        return .success(replacing(index, policies: existing.policies.filter { $0.id != policyID }))
    }

    /// One toolkit's ordered connection grants. Ports the extension
    /// `listConnections` (`server.ts:481-482`).
    public func listConnections(_ toolkitID: String) -> Result<[MCPToolkitConnection], MCPToolkitError> {
        guard let toolkit = toolkit(id: toolkitID) else {
            return .failure(.toolkitNotFound)
        }
        return .success(toolkit.connections)
    }

    /// Appends one connection grant. Ports the extension `createConnection`
    /// (`server.ts:484-516`): the pattern must parse, an absent position
    /// lands above the current minimum, and a duplicate pattern returns the
    /// existing grant instead of minting a second row.
    public func createConnection(
        _ toolkitID: String,
        pattern rawPattern: String,
        position: FractionalIndex? = nil
    ) -> Result<(MCPToolkitStore, MCPToolkitConnection), MCPToolkitError> {
        guard let parsed = try? SegmentPattern.parse(rawPattern) else {
            return .failure(.invalidPattern)
        }
        guard let index = toolkits.firstIndex(where: { $0.id == toolkitID }) else {
            return .failure(.toolkitNotFound)
        }
        let existing = toolkits[index]
        if let duplicate = existing.connections.first(where: { $0.pattern == parsed }) {
            return .success((self, duplicate))
        }
        let connection = MCPToolkitConnection(
            id: Self.nextID(prefix: "tkconn"),
            pattern: parsed,
            position: position ?? Self.topPosition(below: existing.connections.map(\.position))
        )
        var next = toolkits
        next[index] = MCPToolkit(
            id: existing.id,
            owner: existing.owner,
            slug: existing.slug,
            name: existing.name,
            policies: existing.policies,
            connections: existing.connections + [connection]
        )
        return .success((MCPToolkitStore(toolkits: next), connection))
    }

    /// Drops one connection grant. Ports the extension `removeConnection`
    /// (`server.ts:518-523`).
    public func removeConnection(
        _ toolkitID: String,
        _ connectionID: String
    ) -> Result<MCPToolkitStore, MCPToolkitError> {
        guard let index = toolkits.firstIndex(where: { $0.id == toolkitID }) else {
            return .failure(.toolkitNotFound)
        }
        let existing = toolkits[index]
        guard existing.connections.contains(where: { $0.id == connectionID }) else {
            return .failure(.connectionNotFound)
        }
        var next = toolkits
        next[index] = MCPToolkit(
            id: existing.id,
            owner: existing.owner,
            slug: existing.slug,
            name: existing.name,
            policies: existing.policies,
            connections: existing.connections.filter { $0.id != connectionID }
        )
        return .success(MCPToolkitStore(toolkits: next))
    }

    /// One slug's non-legacy rules in precedence order, or empty for an
    /// unknown slug. Ports the extension `policyRulesForSlug`
    /// (`server.ts:525-542`).
    public func policyRulesForSlug(_ rawSlug: String) -> [MCPToolPolicyProviderRule] {
        guard let toolkit = toolkit(slug: rawSlug) else {
            return []
        }
        return toolkit.providerRules()
    }

    /// Resolves one tool-id literal against one slug's rules. Ports the
    /// extension `resolvePolicyForSlug` (`server.ts:544-560`): an unknown
    /// slug blocks, an org toolkit blocks personal tools before consulting
    /// any rule, otherwise the toolkit resolves with the injected default.
    public func resolvePolicyForSlug(
        _ rawSlug: String,
        toolID: String,
        defaultAction: PolicyAction
    ) -> MCPToolkitVerdict {
        guard let toolkit = toolkit(slug: rawSlug) else {
            return MCPToolkitVerdict(action: .block)
        }
        if toolkit.owner == .org, MCPToolkit.isPersonalToolID(toolID) {
            return MCPToolkitVerdict(action: .block)
        }
        return toolkit.resolve(literal: toolID, defaultAction: defaultAction)
    }

    /// Snapshots one slug's rules plus dynamic scope for one operation. Ports
    /// the extension `preparePolicyResolverForSlug` (`server.ts:569-586`):
    /// the toolkit, its policies, and its connections are read once, then the
    /// pure resolver serves every tool of the operation. An unknown slug
    /// prepares an always-block resolver with an empty scope (nothing
    /// reachable). The same resolution as `resolvePolicyForSlug`, hoisted out
    /// of the per-tool loop.
    public func preparePolicyResolverForSlug(_ rawSlug: String) -> MCPPreparedToolPolicy {
        guard let toolkit = toolkit(slug: rawSlug) else {
            return MCPPreparedToolPolicy(
                resolve: { _, _ in EffectivePolicy(action: .block, provenance: .fallback) },
                dynamicScope: []
            )
        }
        let scopes = toolkit.dynamicScope()
        let isOrg = toolkit.owner == .org
        return MCPPreparedToolPolicy(
            resolve: { address, defaultAction in
                if isOrg, MCPToolkit.isPersonalToolID(address.literal) {
                    return EffectivePolicy(action: .block, provenance: .fallback)
                }
                return toolkit.resolve(literal: address.literal, defaultAction: defaultAction)
                    .effectivePolicy()
            },
            dynamicScope: scopes
        )
    }

    private func toolkit(id: String) -> MCPToolkit? {
        toolkits.first { $0.id == id }
    }

    /// Slug lookup preferring the org toolkit. Ports `getBySlugEntry`
    /// (`server.ts:297-304`); slugs are globally unique, so the preference
    /// only matters for hand-built stores.
    private func toolkit(slug rawSlug: String) -> MCPToolkit? {
        let normalized = rawSlug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = toolkits.filter { $0.slug.rawValue == normalized }
        return matches.first { $0.owner == .org } ?? matches.first
    }

    private func replacing(_ index: Int, policies: [MCPToolkitPolicy]) -> MCPToolkitStore {
        var next = toolkits
        let existing = next[index]
        next[index] = MCPToolkit(
            id: existing.id,
            owner: existing.owner,
            slug: existing.slug,
            name: existing.name,
            policies: policies,
            connections: existing.connections
        )
        return MCPToolkitStore(toolkits: next)
    }

    /// Default position above the current minimum (top of the list). The
    /// `Double` analog of Executor `generateKeyBetween(null, minPosition)`.
    private static func topPosition(below positions: [FractionalIndex]) -> FractionalIndex {
        guard let minimum = positions.min() else {
            return FractionalIndex(value: 0)
        }
        return FractionalIndex(value: minimum.value - 1)
    }

    private static func nextID(prefix: String) -> String {
        "\(prefix)_\(UUID().uuidString)"
    }
}

extension ToolPolicy {
    /// Bridges a validated file policy. Fails when the id violates the
    /// loader's value rules (charset, length) or the position is not
    /// finite: the file decode path rejects those before this runs, so a
    /// nil here means a hand-built policy that never saw the loader. The
    /// pattern, owner, and action are strong types shared with the loader,
    /// so no other check can fail. Wave-2 wiring must surface
    /// decode/validate diagnostics, never this bare nil.
    public init?(filePolicy: MCPFilePolicy) {
        guard MCPToolPolicyFile.validateModel(filePolicy) == nil else {
            return nil
        }
        self.init(
            id: filePolicy.id,
            owner: filePolicy.owner,
            pattern: .segments(filePolicy.pattern),
            action: filePolicy.action,
            position: filePolicy.position
        )
    }
}
