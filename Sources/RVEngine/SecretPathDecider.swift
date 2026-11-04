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

    /// `fold`, plus a second scan of the command's secret-scan view when the
    /// matching view masked operands a search or data-reading command reads
    /// (`grep "k" ".env"`, `jq . .env`). The deny keeps the matching view and
    /// never quotes the unmasked text.
    public func fold(_ result: EvaluationResult, command: ShellCommand) -> EvaluationResult {
        let folded = fold(result)
        guard folded == result, escalatesToAliasPass(result) else { return folded }
        // Command heads are never masked, so the view says whether a second
        // derivation could reveal anything.
        let words = result.matchingView.rawValue.split { " \t\n;|&()".contains($0) }
        guard words.contains(where: { revealsFileOperands(String($0.split(separator: "/").last ?? $0)) }) else {
            return folded
        }
        let revealed = Normalize.secretScanView(of: command)
        guard revealed != result.matchingView, var matched = firstHit(in: revealed) else { return folded }
        matched.searchText = result.matchingView.rawValue
        return EvaluationResult(
            outcome: .deny(Deny(ruleID: matched.ruleID, reason: matched.reason), matched: matched),
            matchingView: result.matchingView
        )
    }

    /// The catalog rule one file-tool path hits, with the spelling that
    /// hit it. The resolved spelling (when the adapter supplies a distinct
    /// target) is checked first, then the typed one: `.env` symlinked to
    /// `config/dev.env` still holds the secret the name promises, and the
    /// shell door already denies `cat .env` on its typed pass. An exemption
    /// on one spelling never vouches for the other. Nil means both clear.
    public func filePathHit(_ path: String) -> (rule: SecretPathRule, spelling: String)? {
        var spellings = [path]
        if let resolution,
           let resolved = resolution.resolve(path),
           resolved != path, !resolved.isEmpty
        {
            spellings.insert(resolved, at: 0)
        }
        for spelling in spellings {
            guard let rule = catalog.firstMatch(of: spelling),
                  allowPaths.exempts(spelling, rule: rule, home: home) == false
            else { continue }
            return (rule, spelling)
        }
        return nil
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
