import RVDomain

/// Catalog-only file-tool door. Packs never see file tools. No I/O.
///
/// `pathResolution` is injected by the caller: when a symlink resolves the
/// typed path to a distinct secret path, the resolved spelling gets the same
/// rule matching and exemption treatment. An exemption on the typed spelling
/// never vouches for the resolved one, and vice versa.
public func evaluateFileTool(
    _ action: FileToolAction,
    catalog: SecretPathCatalog = .dayOne,
    allowPaths: SecretAllowPathSet = .empty,
    home: HomePath? = nil,
    pathResolution: SecretPathResolution? = nil
) -> EvaluationResult {
    let path = action.path.rawValue
    let matchingView = MatchingView(path)
    if action.path.isEmpty {
        return pinnedSecretDeny(
            pattern: "empty-path",
            matchedText: path,
            matchingView: matchingView,
            catalogReason: "Access to a sensitive path is not allowed."
        )
    }
    // The resolved spelling is authoritative: a symlinked path IS its
    // target, so the typed spelling participates only when no distinct
    // target exists (resolver declined, identity, or missing path).
    var spelling = path
    if let pathResolution,
       let resolved = pathResolution.resolve(path),
       resolved != path, !resolved.isEmpty
    {
        spelling = resolved
    }
    guard let rule = catalog.firstMatch(of: spelling) else {
        return EvaluationResult(outcome: .plain, matchingView: matchingView)
    }
    if allowPaths.exempts(spelling, rule: rule, home: home) {
        return EvaluationResult(outcome: .plain, matchingView: matchingView)
    }
    return pinnedSecretDeny(
        pattern: rule.pattern,
        matchedText: spelling,
        matchingView: matchingView,
        catalogReason: rule.reason
    )
}

private func pinnedSecretDeny(
    pattern: String,
    matchedText: String,
    matchingView: MatchingView,
    catalogReason: String
) -> EvaluationResult {
    let ruleID = RuleID(pack: .coreSecrets, pattern: pattern)
    let matched = RuleMatch(
        ruleID: ruleID,
        severity: .high,
        reason: catalogReason,
        regex: nil,
        matchedText: matchedText,
        searchText: matchingView.rawValue
    )
    return EvaluationResult(
        outcome: .deny(
            Deny(ruleID: ruleID, reason: catalogReason),
            matched: matched
        ),
        matchingView: matchingView
    )
}
