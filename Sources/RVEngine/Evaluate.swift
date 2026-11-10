import Foundation
import RVDomain

public let commandByteCap = 65_536

/// Wall-clock bound on all pattern matching for one evaluation. Ordinary
/// commands finish in milliseconds; past the bound the verdict is
/// indeterminate (`budgetExhausted`), never allow.
public let patternTimeBudget: Duration = .seconds(2)

/// Returns the pack-only evaluation of `request`; semantic policy is `evaluateWithSemantics`.
/// An allow is tightened by the alias bodies the command uses or defines.
public func evaluate<E: PatternEngine>(
    _ request: EvaluationRequest,
    packs: [PackSnapshot],
    secretPaths: SecretPathDecider = .dayOne,
    engine: E,
    compiled: CompiledPacks<E.Compiled>
) -> EvaluationResult {
    let result = evaluatePacks(request, packs: packs, secretPaths: secretPaths, engine: engine, compiled: compiled)
    return gateAliases(result, command: request.command, packs: packs) { expansion in
        var inner = request
        inner.command = expansion
        return evaluatePacks(inner, packs: packs, secretPaths: secretPaths, engine: engine, compiled: compiled)
    }
}

private func evaluatePacks<E: PatternEngine>(
    _ request: EvaluationRequest,
    packs: [PackSnapshot],
    secretPaths: SecretPathDecider,
    engine: E,
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

    let matchingView = Normalize.matchingView(of: request.command)
    let enabledSnapshots = enabledPacks(from: packs, enabledIDs: request.enabledPacks)
    if QuickReject.shouldSkip(matchingView: matchingView, enabled: enabledSnapshots) {
        return floorSelfProtection(request.command, secretPaths.fold(
            EvaluationResult(outcome: .quickRejected, matchingView: matchingView),
            command: request.command
        ))
    }

    var attempts = 0
    let budget = request.budget?.maxPatternAttempts
    let deadline = ContinuousClock.now + patternTimeBudget

    let segments = splitSegments(matchingView.rawValue)
    var judged: [JudgedSegment] = []
    if segments.count > 1 {
        for segment in segments {
            var ranPacks = Set<PackID>()
            let result = evaluateSingle(
                segment,
                compiled: compiled,
                enabledIDs: request.enabledPacks,
                engine: engine,
                attempts: &attempts,
                budget: budget,
                deadline: deadline,
                ranPacks: &ranPacks
            )
            if let result, isTerminal(result.outcome) {
                return withMatchingView(result, matchingView)
            }
            judged.append(JudgedSegment(text: segment, ranPacks: ranPacks))
        }
    }

    var fullViewRanPacks = Set<PackID>()
    if let result = evaluateSingle(
        matchingView.rawValue,
        compiled: compiled,
        enabledIDs: request.enabledPacks,
        engine: engine,
        attempts: &attempts,
        budget: budget,
        deadline: deadline,
        ranPacks: &fullViewRanPacks,
        segments: judged
    ) {
        let viewed = withMatchingView(result, matchingView)
        if isTerminal(result.outcome) {
            return viewed
        }
        return floorSelfProtection(request.command, secretPaths.fold(viewed, command: request.command))
    }
    return floorSelfProtection(request.command, secretPaths.fold(
        EvaluationResult(outcome: .plain, matchingView: matchingView),
        command: request.command
    ))
}

/// An allowed `rv` invocation that weakens rv is indeterminate: the owner
/// runs rv administration in Terminal, never the agent it guards.
private func floorSelfProtection(_ command: ShellCommand, _ result: EvaluationResult) -> EvaluationResult {
    guard result.decision == .allow, SelfProtectionGuard.weakensPolicy(command) else { return result }
    return EvaluationResult(
        outcome: .indeterminate(.selfProtection),
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
    var byID: [PackID: PackSnapshot] = [:]
    byID.reserveCapacity(packs.count)
    for pack in packs where byID[pack.id] == nil {
        byID[pack.id] = pack
    }
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

/// A segment the segment pass evaluated, with the packs whose destructive
/// rules ran on it (keyword hit, not skipped by a safe match).
private struct JudgedSegment {
    var text: String
    var ranPacks: Set<PackID>
}

private func evaluateSingle<E: PatternEngine>(
    _ view: String,
    compiled: CompiledPacks<E.Compiled>,
    enabledIDs: [PackID],
    engine: E,
    attempts: inout Int,
    budget: Int?,
    deadline: ContinuousClock.Instant,
    ranPacks: inout Set<PackID>,
    segments: [JudgedSegment] = []
) -> EvaluationResult? {
    if isDocumentationQuery(view) {
        return nil
    }

    var remembered: RuleMatch?
    var lastSafe: SafeMatch?

    for enabledID in enabledIDs {
        guard let index = compiled.packIndex(for: enabledID) else { continue }
        let pack = compiled.packs[index]
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
            switch engine.search(named.compiled, in: view, deadline: deadline) {
            case .exhausted:
                return EvaluationResult(outcome: .indeterminate(.budgetExhausted))
            case .noMatch:
                continue
            case .match:
                lastSafe = SafeMatch(packID: pack.snapshot.id, patternName: named.name)
                skippedBySafe = true
            }
            break
        }
        // In the full view of a multi-segment command a safe match vouches only
        // for segments the segment pass already judged. A rule written to match
        // across segments (fork bomb, copy-then-delete) was never seen there, so
        // it still runs and its spanning matches count. Other rules stay
        // suppressed: their `.*`/`\s` crossing a separator is incidental.
        let spanningOnly = skippedBySafe && !segments.isEmpty
        if skippedBySafe && !spanningOnly {
            continue
        }
        if !skippedBySafe {
            ranPacks.insert(pack.snapshot.id)
        }

        for rule in pack.destructive {
            if spanningOnly && !rule.spansSegments {
                continue
            }
            attempts += 1
            if let budget, attempts > budget {
                return EvaluationResult(outcome: .indeterminate(.budgetExhausted))
            }
            // firstMatch is the sole destructive hit test so span/matchedText cannot disagree with the hit.
            let range: Range<String.Index>
            switch engine.search(rule.compiled, in: view, deadline: deadline) {
            case .exhausted:
                return EvaluationResult(outcome: .indeterminate(.budgetExhausted))
            case .noMatch:
                continue
            case .match(let found):
                range = found
            }
            // Exempt only a match some segment already judged with this pack's
            // rules; a segment whose own safe match skipped the pack (`echo
            // $(cp -a /etc /tmp/s && rm -rf /tmp/s)`) judged nothing.
            if spanningOnly, segments.contains(where: {
                $0.ranPacks.contains(pack.snapshot.id) && $0.text.contains(view[range])
            }) {
                continue
            }
            let span = MatchSpan(
                start: view.distance(from: view.startIndex, to: range.lowerBound),
                end: view.distance(from: view.startIndex, to: range.upperBound)
            )
            let match = RuleMatch(
                ruleID: RuleID(pack: pack.snapshot.id, pattern: rule.rule.name),
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
