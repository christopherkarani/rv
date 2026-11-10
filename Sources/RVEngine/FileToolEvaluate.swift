import RVDomain

/// Catalog-only file-tool door. Packs never see file tools. No I/O.
///
/// The decider's resolution adapter is injected by the caller: when a
/// symlink resolves the typed path to a distinct secret path, the resolved
/// spelling gets the same rule matching and exemption treatment. An
/// exemption on the typed spelling never vouches for the resolved one,
/// and vice versa.
public func evaluateFileTool(
    _ action: FileToolAction,
    secretPaths: SecretPathDecider = .dayOne
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
    guard let hit = secretPaths.filePathHit(path) else {
        return EvaluationResult(outcome: .plain, matchingView: matchingView)
    }
    return pinnedSecretDeny(
        pattern: hit.rule.pattern,
        matchedText: hit.spelling,
        matchingView: matchingView,
        catalogReason: hit.rule.reason
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
