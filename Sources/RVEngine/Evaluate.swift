import Foundation
import RVDomain

public let commandByteCap = 65_536

public func evaluate<E: PatternEngine>(
    _ request: EvaluationRequest,
    packs: [PackSnapshot],
    secrets: SecretPathCatalog = .dayOne,
    patterns: E,
    compiled: CompiledPacks<E.Compiled>
) -> EvaluationResult {
    let raw = request.command.rawValue
    if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return EvaluationResult(outcome: .plain, matchingView: MatchingView(""))
    }
    if raw.utf8.count > commandByteCap {
        return EvaluationResult(
            outcome: .indeterminate(.commandTooLarge),
            matchingView: MatchingView(raw)
        )
    }
    if !corePacksAreReady(snapshots: packs, compiled: compiled) {
        return EvaluationResult(
            outcome: .indeterminate(.corePacksUnavailable),
            matchingView: MatchingView(raw)
        )
    }

    let matchingView = Normalize.matchingView(of: raw)
    let enabledSnapshots = enabledPacks(from: packs, enabledIDs: request.enabledPacks)
    if QuickReject.shouldSkip(matchingView: matchingView, enabled: enabledSnapshots) {
        return foldSecretPathIfAllow(
            EvaluationResult(outcome: .quickRejected, matchingView: matchingView),
            catalog: secrets
        )
    }

    var attempts = 0
    let budget = request.budget?.maxPatternAttempts
    let compiledEnabled = enabledCompiled(from: compiled, enabledIDs: request.enabledPacks)

    let segments = splitSegments(matchingView.rawValue)
    if segments.count > 1 {
        for segment in segments {
            let result = evaluateSingle(
                segment,
                compiled: compiledEnabled,
                patterns: patterns,
                attempts: &attempts,
                budget: budget
            )
            if let result, isTerminal(result.outcome) {
                return withMatchingView(result, matchingView)
            }
        }
    }

    if let result = evaluateSingle(
        matchingView.rawValue,
        compiled: compiledEnabled,
        patterns: patterns,
        attempts: &attempts,
        budget: budget
    ) {
        let viewed = withMatchingView(result, matchingView)
        if isTerminal(result.outcome) {
            return viewed
        }
        return foldSecretPathIfAllow(viewed, catalog: secrets)
    }
    return foldSecretPathIfAllow(
        EvaluationResult(outcome: .plain, matchingView: matchingView),
        catalog: secrets
    )
}

private func foldSecretPathIfAllow(
    _ result: EvaluationResult,
    catalog: SecretPathCatalog
) -> EvaluationResult {
    switch result.outcome {
    case .quickRejected, .plain, .safeOnly, .hit:
        break
    case .deny, .indeterminate:
        return result
    }
    guard !catalog.rules.isEmpty else { return result }
    guard let matched = SecretPathGuard.firstHit(in: result.matchingView, catalog: catalog) else {
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

private func withMatchingView(_ result: EvaluationResult, _ matchingView: MatchingView) -> EvaluationResult {
    var copy = result
    copy.matchingView = matchingView
    return copy
}

/// Returns whether `core.git` and `core.filesystem` snapshots are present and whether each required compiled rule is present in `compiled` when that rule exists on a snapshot.
public func corePacksAreReady<Compiled: Sendable>(
    snapshots: [PackSnapshot],
    compiled: CompiledPacks<Compiled>
) -> Bool {
    guard corePacksArePresent(snapshots) else { return false }
    return requiredRulesAreCompiled(snapshots: snapshots, compiled: compiled)
}

private func corePacksArePresent(_ packs: [PackSnapshot]) -> Bool {
    func usable(_ id: PackID) -> Bool {
        guard let pack = packs.first(where: { $0.id == id }) else { return false }
        return !pack.safe.isEmpty || !pack.destructive.isEmpty
    }
    return usable(.coreGit) && usable(.coreFilesystem)
}

let requiredCompiledRules: Set<RuleID> = [
    RuleID(pack: .coreGit, pattern: "reset-hard"),
    RuleID(pack: .coreFilesystem, pattern: "fork-bomb"),
]

private func requiredRulesAreCompiled<Compiled: Sendable>(
    snapshots: [PackSnapshot],
    compiled: CompiledPacks<Compiled>
) -> Bool {
    for ruleID in requiredCompiledRules {
        let snapshotHasRule = snapshots.contains { pack in
            pack.id == ruleID.pack && pack.destructive.contains { $0.name == ruleID.pattern }
        }
        guard snapshotHasRule else { continue }
        let compiledHasRule = compiled.packs.contains { pack in
            pack.snapshot.id == ruleID.pack && pack.destructive.contains { $0.rule.name == ruleID.pattern }
        }
        if !compiledHasRule {
            return false
        }
    }
    return true
}

private func enabledPacks(from packs: [PackSnapshot], enabledIDs: [PackID]) -> [PackSnapshot] {
    let byID = Dictionary(uniqueKeysWithValues: packs.map { ($0.id, $0) })
    return enabledIDs.compactMap { byID[$0] }
}

private func enabledCompiled<Compiled: Sendable>(
    from compiled: CompiledPacks<Compiled>,
    enabledIDs: [PackID]
) -> [CompiledPack<Compiled>] {
    let byID = Dictionary(uniqueKeysWithValues: compiled.packs.map { ($0.snapshot.id, $0) })
    return enabledIDs.compactMap { byID[$0] }
}

private func isTerminal(_ outcome: EvaluationOutcome) -> Bool {
    switch outcome {
    case .deny, .indeterminate:
        return true
    case .quickRejected, .plain, .safeOnly, .hit:
        return false
    }
}

private func evaluateSingle<E: PatternEngine>(
    _ view: String,
    compiled: [CompiledPack<E.Compiled>],
    patterns: E,
    attempts: inout Int,
    budget: Int?
) -> EvaluationResult? {
    var remembered: RuleMatch?
    var lastSafe: SafeMatch?

    for pack in compiled {
        let keywordHit = pack.snapshot.keywords.contains { QuickReject.keywordHits($0, in: view) }
        let forceFilesystem =
            pack.snapshot.id == .coreFilesystem && QuickReject.containsEmptyParenPair(view)
        if !keywordHit && !forceFilesystem {
            continue
        }

        var skippedBySafe = false
        for named in pack.safe {
            attempts += 1
            if let budget, attempts > budget {
                return EvaluationResult(outcome: .indeterminate(.budgetExhausted))
            }
            if patterns.matches(named.compiled, in: view) {
                lastSafe = SafeMatch(packID: pack.snapshot.id, patternName: named.name)
                skippedBySafe = true
                break
            }
        }
        if skippedBySafe {
            continue
        }

        for rule in pack.destructive {
            attempts += 1
            if let budget, attempts > budget {
                return EvaluationResult(outcome: .indeterminate(.budgetExhausted))
            }
            // firstMatch is the sole destructive hit test so span/matchedText cannot disagree with the hit.
            guard let range = patterns.firstMatch(rule.compiled, in: view) else { continue }
            let span = MatchSpan(
                start: view.distance(from: view.startIndex, to: range.lowerBound),
                end: view.distance(from: view.startIndex, to: range.upperBound)
            )
            let match = RuleMatch(
                ruleID: RuleID(pack: pack.snapshot.id, pattern: rule.rule.name),
                packID: pack.snapshot.id,
                patternName: rule.rule.name,
                severity: rule.rule.severity,
                reason: rule.rule.reason,
                explanation: rule.rule.explanation,
                regex: rule.rule.pattern,
                span: span,
                matchedText: String(view[range]),
                searchText: view
            )
            if rule.rule.severity.blocksByDefault {
                return EvaluationResult(
                    outcome: .deny(
                        Deny(ruleID: match.ruleID, reason: match.reason),
                        matched: match
                    )
                )
            }
            if remembered == nil {
                remembered = match
            }
        }
    }

    if let remembered {
        return EvaluationResult(outcome: .hit(remembered, safe: lastSafe))
    }
    if let lastSafe {
        return EvaluationResult(outcome: .safeOnly(lastSafe))
    }
    return nil
}
