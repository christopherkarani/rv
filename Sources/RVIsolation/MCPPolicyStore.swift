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
    /// No rule or pin matched; `action` is the injected plugin default.
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
///    resolving to the higher-ranked owner (org over user).
/// 3. Fallback: the init-injected `pluginDefault` with nil provenance.
///
/// All configuration is fixed at init. There is no mutation API: policies and pins are
/// pre-ranked once, and `resolve` is a pure function of the address.
public struct MCPPolicyStore: Sendable {
    /// Fallback verdict when neither a static pin nor any pattern matches.
    public let pluginDefault: PolicyAction

    private let orgPolicies: [ToolPolicy]
    private let userPolicies: [ToolPolicy]
    private let staticActions: [MCPToolAddress: PolicyAction]

    /// Builds an immutable store with pre-ranked policies and pins.
    ///
    /// - Parameters:
    ///   - policies: Rules ranked per owner by (`position`, `id`). Exact ties on
    ///     owner, position, and id keep init order (stable sort).
    ///   - staticFqids: Exact pins checked before any pattern. Later pins win on
    ///     duplicate addresses.
    ///   - pluginDefault: Required fallback; the caller must choose it explicitly.
    public init(
        policies: [ToolPolicy] = [],
        staticFqids: [StaticFqidPin] = [],
        pluginDefault: PolicyAction
    ) {
        self.pluginDefault = pluginDefault
        self.orgPolicies = Self.ranked(policies, owner: .org)
        self.userPolicies = Self.ranked(policies, owner: .user)
        self.staticActions = Dictionary(
            staticFqids.map { ($0.address, $0.action) },
            uniquingKeysWith: { _, last in last }
        )
    }

    /// Resolves the effective verdict for one validated address. Pure; no IO.
    public func resolve(_ address: MCPToolAddress) -> EffectivePolicy {
        if let pinned = staticActions[address] {
            return EffectivePolicy(action: pinned, provenance: .staticPin(literal: address.literal))
        }
        let winners = [orgPolicies, userPolicies].compactMap { ranked in
            ranked.first { $0.pattern.matches(address) }
        }
        guard let best = winners.max(by: { ($0.action, $0.owner) < ($1.action, $1.owner) }) else {
            return EffectivePolicy(action: pluginDefault, provenance: .fallback)
        }
        return EffectivePolicy(action: best.action, provenance: .pattern(id: best.id, owner: best.owner))
    }

    private static func ranked(_ policies: [ToolPolicy], owner: PolicyOwner) -> [ToolPolicy] {
        policies
            .filter { $0.owner == owner }
            .sorted { ($0.position, $0.id) < ($1.position, $1.id) }
    }
}
