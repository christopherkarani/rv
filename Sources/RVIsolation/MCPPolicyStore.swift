import Foundation
import RVDomain

/// Provenance of one resolved verdict: exactly one of the three tiers,
/// most specific first. The previous two-optional encoding had a fourth,
/// impossible combo (nil id with a non-nil owner) that `resolve` never
/// produced; the enum makes it inexpressible.
public enum PolicyProvenance: Sendable, Equatable, Hashable {
    /// A pattern rule won: its id plus its scope.
    case pattern(id: String, owner: PolicyOwner)
    /// A static pin won: the address canonical literal (pins are ownerless).
    case staticPin(literal: String)
    /// No rule or pin matched; `action` is the ambient default (the injected
    /// plugin default, or block at an active provider's allowlist boundary).
    case fallback
}

/// Winning verdict for one tool address after owner ranking and most-restrictive-wins reduction.
///
/// The Codable wire shape keeps the historical `matchedPolicyId`/`owner`
/// keys: a pattern win encodes both, a static pin encodes the literal with
/// no owner, and the fallback encodes neither (matching the previous
/// synthesized `encodeIfPresent` omission for nils). Decoding the
/// impossible combo (owner without id) fails closed.
public struct EffectivePolicy: Sendable, Equatable, Hashable, Codable {
    /// Verdict the invoker must enforce.
    public let action: PolicyAction
    /// Which tier won and what it matched.
    public let provenance: PolicyProvenance

    /// Assembles a resolved verdict with its provenance.
    public init(action: PolicyAction, provenance: PolicyProvenance) {
        self.action = action
        self.provenance = provenance
    }

    /// True when no rule or pin matched and `action` is the injected plugin default.
    public var isFallback: Bool {
        provenance == .fallback
    }

    private enum CodingKeys: String, CodingKey {
        case action
        case matchedPolicyId
        case owner
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let action = try container.decode(PolicyAction.self, forKey: .action)
        let matched = try container.decodeIfPresent(String.self, forKey: .matchedPolicyId)
        let owner = try container.decodeIfPresent(PolicyOwner.self, forKey: .owner)
        let provenance: PolicyProvenance
        switch (matched, owner) {
        case (let id?, let owner?):
            provenance = .pattern(id: id, owner: owner)
        case (let literal?, nil):
            provenance = .staticPin(literal: literal)
        case (nil, nil):
            provenance = .fallback
        case (nil, _?):
            throw DecodingError.dataCorruptedError(
                forKey: .owner,
                in: container,
                debugDescription: "owner without matchedPolicyId"
            )
        }
        self.init(action: action, provenance: provenance)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        switch provenance {
        case .pattern(let id, let owner):
            try container.encode(id, forKey: .matchedPolicyId)
            try container.encode(owner, forKey: .owner)
        case .staticPin(let literal):
            try container.encode(literal, forKey: .matchedPolicyId)
        case .fallback:
            break
        }
    }
}

/// One pinned exact verdict that bypasses pattern matching.
///
/// A pin matches exactly one validated address. On a hit the store returns the pinned
/// action without consulting any pattern, so pinning `approve` overrides even an org
/// `block`. Pins are fixed at init with no mutation API; the caller protects the pin
/// list with the same storage ACL as policy documents.
public struct StaticFqidPin: Sendable, Equatable, Hashable, Codable {
    /// The single address this pin matches.
    public let address: MCPToolAddress
    /// Verdict returned on an exact hit.
    public let action: PolicyAction

    /// Pins one exact address to one verdict.
    public init(address: MCPToolAddress, action: PolicyAction) {
        self.address = address
        self.action = action
    }
}

/// Immutable owner-scoped policy store: first-match-per-owner, then most-restrictive-wins.
///
/// Resolution for one validated address runs three tiers in order:
/// 1. Static tier: an exact pin hit returns the pinned action immediately; patterns are never consulted.
/// 2. Pattern tier: each owner contributes its first matching rule ordered by
///    (`position`, `id`); the most restrictive contribution wins, with action ties
///    resolving to the higher-ranked owner (org over user). An active
///    `provider` replaces this tier wholesale with its own rules (allowlist
///    semantics); the static tier still wins first.
/// 3. Fallback: the init-injected `pluginDefault` with nil provenance.
///
/// Mutations return the next store plus the affected rule, so callers thread
/// state functionally; pins stay fixed at init.
public struct MCPPolicyStore: Sendable {
    /// Fallback verdict when neither a static pin nor any pattern matches.
    public let pluginDefault: PolicyAction

    private let orgPolicies: [ToolPolicy]
    private let userPolicies: [ToolPolicy]
    private let staticActions: [MCPToolAddress: PolicyAction]
    private let provider: (any MCPToolPolicyProvider)?

    /// Builds an immutable store with pre-ranked policies and pins.
    ///
    /// - Parameters:
    ///   - policies: Rules ranked per owner by (`position`, `id`). Exact ties on
    ///     owner, position, and id keep init order (stable sort).
    ///   - staticFqids: Exact pins checked before any pattern. Later pins win on
    ///     duplicate addresses.
    ///   - pluginDefault: Required fallback; the caller must choose it explicitly.
    ///   - provider: Alternate rule source replacing the pattern tier. Ports
    ///     Executor `activeToolPolicyProvider` (`executor.ts:2041`): when set,
    ///     only the provider's rules apply (scoping enforcement); the store's
    ///     own rows are ignored. Snapshots at init; see `MCPToolPolicyProvider`.
    public init(
        policies: [ToolPolicy] = [],
        staticFqids: [StaticFqidPin] = [],
        pluginDefault: PolicyAction,
        provider: (any MCPToolPolicyProvider)? = nil
    ) {
        self.pluginDefault = pluginDefault
        self.orgPolicies = Self.ranked(policies, owner: .org)
        self.userPolicies = Self.ranked(policies, owner: .user)
        self.staticActions = Dictionary(
            staticFqids.map { ($0.address, $0.action) },
            uniquingKeysWith: { _, last in last }
        )
        self.provider = provider
    }

    /// Resolves the effective verdict for one validated address. Pure; no IO.
    public func resolve(_ address: MCPToolAddress) -> EffectivePolicy {
        resolveWithPrepared(address, prepared: provider?.prepare())
    }

    /// Snapshots this store for a batch of resolutions. Captures the
    /// provider's prepared resolver once (when the provider implements
    /// `prepare`), so a multi-tool operation pays one snapshot instead of one
    /// per tool. Ports the prepared arm of `listActivePolicyRuleSet`
    /// (`executor.ts:5461-5489`).
    public func prepared() -> MCPPreparedPolicy {
        MCPPreparedPolicy(store: self, prepared: provider?.prepare())
    }

    /// Every rule: user rows first, then org rows, each ranked by
    /// (`position`, `id`). Ports Executor `policiesList`
    /// (`executor.ts:6050-6059`).
    public func list() -> [ToolPolicy] {
        (userPolicies + orgPolicies).sorted {
            if $0.owner != $1.owner {
                return $0.owner == .user
            }
            return ($0.position, $0.id) < ($1.position, $1.id)
        }
    }

    /// Appends one rule. Ports Executor `policiesCreate`
    /// (`executor.ts:6061-6109`): the pattern must satisfy the X1-B grammar
    /// (new rules are always segment patterns; legacy cases are frozen), and
    /// an absent position lands just below every more-specific committed rule
    /// of the same owner, so a fresh broad rule never shadows a leaf rule.
    public func create(
        owner: PolicyOwner,
        pattern rawPattern: String,
        action: PolicyAction,
        position: FractionalIndex? = nil
    ) -> Result<(MCPPolicyStore, ToolPolicy), MCPToolPolicyMutationError> {
        guard let parsed = try? SegmentPattern.parse(rawPattern) else {
            return .failure(.invalidPattern)
        }
        let rows = rows(for: owner).map { ($0.id, $0.pattern, $0.position) }
        let policy = ToolPolicy(
            id: UUID().uuidString,
            owner: owner,
            pattern: .segments(parsed),
            action: action,
            position: position ?? SegmentPattern.positionForNewPattern(parsed, rows: rows)
        )
        return .success((MCPPolicyStore(rebasing: self, policies: allPolicies + [policy]), policy))
    }

    /// Mutates one rule in place. Ports Executor `policiesUpdate`
    /// (`executor.ts:6111-6145`): an explicit pattern re-validates (before
    /// the lookup, so a bad pattern wins over a missing id), the lookup is
    /// owner-scoped, and a vanished row fails instead of writing.
    public func update(
        id: String,
        owner: PolicyOwner,
        pattern rawPattern: String? = nil,
        action: PolicyAction? = nil,
        position: FractionalIndex? = nil
    ) -> Result<(MCPPolicyStore, ToolPolicy), MCPToolPolicyMutationError> {
        let parsed: SegmentPattern?
        if let rawPattern {
            guard let reparsed = try? SegmentPattern.parse(rawPattern) else {
                return .failure(.invalidPattern)
            }
            parsed = reparsed
        } else {
            parsed = nil
        }
        var all = allPolicies
        guard let index = all.firstIndex(where: { $0.id == id && $0.owner == owner }) else {
            return .failure(.policyNotFound)
        }
        let current = all[index]
        all[index] = ToolPolicy(
            id: current.id,
            owner: current.owner,
            pattern: parsed.map(ToolPattern.segments) ?? current.pattern,
            action: action ?? current.action,
            position: position ?? current.position
        )
        return .success((MCPPolicyStore(rebasing: self, policies: all), all[index]))
    }

    /// Drops one rule. Ports Executor `policiesRemove`
    /// (`executor.ts:6147-6156`): owner-scoped and idempotent, so removing a
    /// missing row still succeeds.
    public func remove(id: String, owner: PolicyOwner) -> MCPPolicyStore {
        MCPPolicyStore(
            rebasing: self,
            policies: allPolicies.filter { $0.id != id || $0.owner != owner }
        )
    }

    fileprivate func resolveWithPrepared(
        _ address: MCPToolAddress,
        prepared: MCPPreparedToolPolicy?
    ) -> EffectivePolicy {
        if let pinned = staticActions[address] {
            return EffectivePolicy(action: pinned, provenance: .staticPin(literal: address.literal))
        }
        if let provider {
            return Self.resolveWithProvider(
                provider, address: address, defaultAction: pluginDefault, prepared: prepared
            )
        }
        let winners = [orgPolicies, userPolicies].compactMap { ranked in
            ranked.first { $0.pattern.matches(address) }
        }
        guard let best = winners.max(by: { ($0.action, $0.owner) < ($1.action, $1.owner) }) else {
            return EffectivePolicy(action: pluginDefault, provenance: .fallback)
        }
        return EffectivePolicy(action: best.action, provenance: .pattern(id: best.id, owner: best.owner))
    }

    /// Provider-tier resolution. Ports `resolvePolicyFromRuleSet`
    /// (`executor.ts:5490-5508`): a prepared snapshot wins, then the
    /// provider's direct resolve, then first-match over the listed rules in
    /// (`position`, `id`) order. Providers are capability allowlists: no
    /// matching listed rule blocks at the boundary (`executor.ts:5454-5456`).
    private static func resolveWithProvider(
        _ provider: any MCPToolPolicyProvider,
        address: MCPToolAddress,
        defaultAction: PolicyAction,
        prepared: MCPPreparedToolPolicy?
    ) -> EffectivePolicy {
        if let prepared {
            return prepared.resolve(address, defaultAction)
        }
        if let direct = provider.resolve(address, defaultAction: defaultAction) {
            return direct
        }
        let rules = provider.list().sorted { ($0.position, $0.id) < ($1.position, $1.id) }
        for rule in rules where rule.pattern.matches(address) {
            return EffectivePolicy(
                action: rule.action,
                provenance: .pattern(id: rule.id, owner: rule.owner)
            )
        }
        return EffectivePolicy(action: .block, provenance: .fallback)
    }

    /// Rebuilds this store's configuration around a new rule set: pins,
    /// fallback, and provider carry over unchanged.
    private init(rebasing other: MCPPolicyStore, policies: [ToolPolicy]) {
        self.init(
            policies: policies,
            staticFqids: other.staticActions.map { StaticFqidPin(address: $0.key, action: $0.value) },
            pluginDefault: other.pluginDefault,
            provider: other.provider
        )
    }

    private var allPolicies: [ToolPolicy] {
        orgPolicies + userPolicies
    }

    private func rows(for owner: PolicyOwner) -> [ToolPolicy] {
        owner == .org ? orgPolicies : userPolicies
    }

    private static func ranked(_ policies: [ToolPolicy], owner: PolicyOwner) -> [ToolPolicy] {
        policies
            .filter { $0.owner == owner }
            .sorted { ($0.position, $0.id) < ($1.position, $1.id) }
    }
}

/// Policy mutation failures. Fixed labels; never ids or patterns.
public enum MCPToolPolicyMutationError: Error, Sendable, Equatable {
    /// The pattern violates the X1-B grammar.
    case invalidPattern
    /// No rule of that owner holds the id.
    case policyNotFound
}

/// One store snapshot for a batch of resolutions. Holds the store plus the
/// provider snapshot `prepared()` captured, so every `resolve` in the batch
/// reuses it instead of re-snapshotting.
public struct MCPPreparedPolicy: Sendable {
    private let store: MCPPolicyStore
    private let prepared: MCPPreparedToolPolicy?

    fileprivate init(store: MCPPolicyStore, prepared: MCPPreparedToolPolicy?) {
        self.store = store
        self.prepared = prepared
    }

    /// Resolves one address against the snapshot. Pure; no IO.
    public func resolve(_ address: MCPToolAddress) -> EffectivePolicy {
        store.resolveWithPrepared(address, prepared: prepared)
    }
}
