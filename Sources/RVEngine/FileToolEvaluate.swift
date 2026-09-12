import RVDomain

/// Catalog-only file-tool door. Packs never see file tools. No I/O.
public func evaluateFileTool(
    _ action: FileToolAction,
    catalog: SecretPathCatalog = .dayOne,
    allowPaths: SecretAllowPathSet = .empty,
    home: String? = nil
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
    guard let rule = catalog.firstMatch(of: path) else {
        return EvaluationResult(outcome: .plain, matchingView: matchingView)
    }
    if allowPaths.exempts(path, rule: rule, home: home) {
        return EvaluationResult(outcome: .plain, matchingView: matchingView)
    }
    return pinnedSecretDeny(
        pattern: rule.pattern,
        matchedText: path,
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
        packID: .coreSecrets,
        patternName: pattern,
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
