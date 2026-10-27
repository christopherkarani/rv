import RVDomain

/// The secret-path decision: everything a caller must supply to ask
/// "does this touch a secret path?" in one value.
///
/// Bundles the catalog, the metadata gate, the allow-path exemptions, the
/// home spelling context, and the optional alias-resolution adapter, so
/// callers stop threading five facts — and the invariants that join them —
/// through every evaluation door. `SecretPathGuard` stays the internal
/// candidate scanner behind this interface.
public struct SecretPathDecider: Sendable {
    public var catalog: SecretPathCatalog
    public var includeMetadata: Bool
    public var allowPaths: SecretAllowPathSet
    public var home: HomePath?
    public var resolution: SecretPathResolution?

    public init(
        catalog: SecretPathCatalog = .dayOne,
        safety: SafetyLevel = .normal,
        allowPaths: SecretAllowPathSet = .empty,
        home: HomePath? = nil,
        resolution: SecretPathResolution? = nil
    ) {
        self.catalog = catalog
        self.includeMetadata = safety == .strict
        self.allowPaths = allowPaths
        self.home = home
        self.resolution = resolution
    }

    public static let dayOne = SecretPathDecider()

    /// Same decision context with a different alias-resolution adapter.
    /// The two-pass callers build the typed pass with `resolution: nil`
    /// and derive the alias pass from it, so both passes share one
    /// catalog, exemption set, and home.
    public func withResolution(_ resolution: SecretPathResolution?) -> SecretPathDecider {
        var copy = self
        copy.resolution = resolution
        return copy
    }

    /// First secret-path hit in a command view, or nil. A resolved
    /// spelling is authoritative per candidate; an exemption on one
    /// spelling never vouches for the other.
    public func firstHit(in view: MatchingView) -> RuleMatch? {
        SecretPathGuard.firstHit(
            in: view,
            catalog: catalog,
            includeMetadata: includeMetadata,
            resolution: resolution,
            exempts: { path, rule in allowPaths.exempts(path, rule: rule, home: home) }
        )
    }

    /// Tightens an allow outcome to a secret-path deny when the guard
    /// hits. Deny and indeterminate outcomes are a floor and pass
    /// through untouched.
    public func fold(_ result: EvaluationResult) -> EvaluationResult {
        switch result.outcome {
        case .quickRejected, .plain, .safeOnly, .hit:
            break
        case .deny, .indeterminate:
            return result
        }
        guard let matched = firstHit(in: result.matchingView) else {
            return result
        }
        return EvaluationResult(
            outcome: .deny(
                Deny(ruleID: matched.ruleID, reason: matched.reason),
                matched: matched
            ),
            matchingView: result.matchingView
        )
    }

    /// The catalog rule one file-tool path hits, with the spelling that
    /// hit it (the resolved spelling when the adapter supplies a
    /// distinct target). Nil means the path clears the catalog.
    public func filePathHit(_ path: String) -> (rule: SecretPathRule, spelling: String)? {
        var spelling = path
        if let resolution,
           let resolved = resolution.resolve(path),
           resolved != path, !resolved.isEmpty
        {
            spelling = resolved
        }
        guard let rule = catalog.firstMatch(of: spelling) else { return nil }
        if allowPaths.exempts(spelling, rule: rule, home: home) { return nil }
        return (rule, spelling)
    }

    /// Whether an outcome is an allow the alias pass may still tighten.
    /// Deny and indeterminate settle the command, so resolving aliases
    /// for them would only buy I/O, never a different decision.
    public func escalatesToAliasPass(_ result: EvaluationResult) -> Bool {
        switch result.outcome {
        case .deny, .indeterminate:
            return false
        case .quickRejected, .plain, .safeOnly, .hit:
            return true
        }
    }
}
