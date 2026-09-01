import Testing
import RVDomain
@testable import RVEngine

private func samplePacks() -> [PackSnapshot] {
    [
        PackSnapshot(
            id: .coreFilesystem,
            name: "fs",
            description: "fs",
            keywords: ["rm"],
            safe: [NamedPattern(name: "rm-rf-tmp", pattern: #"^rm\s+-rf\s+/tmp/"#)],
            destructive: [
                DestructiveRule(
                    name: "rm-rf-general",
                    pattern: #"rm\s+-rf"#,
                    severity: .high,
                    reason: "rm -rf is destructive"
                )
            ]
        ),
        PackSnapshot(
            id: .coreGit,
            name: "git",
            description: "git",
            keywords: ["git"],
            safe: [NamedPattern(name: "checkout-new-branch", pattern: #"git\s+checkout\s+-b\s+"#)],
            destructive: [
                DestructiveRule(
                    name: "reset-hard",
                    pattern: #"git\s+reset\s+--hard"#,
                    severity: .critical,
                    reason: "git reset --hard destroys uncommitted changes"
                ),
                DestructiveRule(
                    name: "checkout-discard",
                    pattern: #"git\s+checkout\s+--"#,
                    severity: .high,
                    reason: "git checkout -- discards uncommitted changes"
                ),
                DestructiveRule(
                    name: "stash-drop",
                    pattern: #"git\s+stash\s+drop"#,
                    severity: .medium,
                    reason: "git stash drop deletes a single stash"
                )
            ]
        )
    ]
}

private func run(
    _ command: String,
    packs: [PackSnapshot]? = nil,
    budget: EvaluationBudget? = nil
) throws -> EvaluationResult {
    let packs = packs ?? samplePacks()
    let engine = ICUPatternEngine()
    let compiled = try CompiledPacks<ICUCompiledPattern>.compile(packs: packs, using: engine)
    return evaluate(
        EvaluationRequest(
            command: ShellCommand(rawValue: command),
            enabledPacks: dayOnePackIDs,
            budget: budget
        ),
        packs: packs,
        patterns: engine,
        compiled: compiled
    )
}

@Test func evaluate_setsMatchingViewOnDeny() throws {
    let result = try run("git reset --hard")
    #expect(result.matchingView == Normalize.matchingView(of: "git reset --hard"))
    guard case .deny = result.decision else {
        Issue.record("expected deny")
        return
    }
}

@Test func evaluate_safeThenDestructiveThenAllow() throws {
    let checkout = try run("git checkout -b x")
    #expect(checkout.decision == .allow)
    #expect(checkout.matchedSafe?.packID == .coreGit)
    #expect(checkout.matchedSafe?.patternName == "checkout-new-branch")

    let discard = try run("git checkout -- .")
    guard case .deny(let deny) = discard.decision else {
        Issue.record("expected deny")
        return
    }
    #expect(deny.ruleID.rawValue == "core.git:checkout-discard")

    let ls = try run("ls -la")
    #expect(ls.decision == .allow)
    #expect(ls.quickRejected)

    let echo = try run("echo hello")
    #expect(echo.decision == .allow)
}

@Test func evaluate_safeIsPerPack() throws {
    let result = try run("git reset --hard && rm -rf /tmp/x")
    guard case .deny(let deny) = result.decision else {
        Issue.record("expected deny")
        return
    }
    #expect(deny.ruleID.rawValue == "core.git:reset-hard")
}

@Test func evaluate_mediumIsAllowPlusMatch() throws {
    let result = try run("git stash drop")
    #expect(result.decision == .allow)
    #expect(result.matched?.ruleID.rawValue == "core.git:stash-drop")
}

@Test func evaluate_matchCopiesRegex() throws {
    let result = try run("git reset --hard")
    #expect(result.matched?.regex == #"git\s+reset\s+--hard"#)
}

@Test func evaluate_matchCopiesSpanAndText() throws {
    let result = try run("git reset --hard")
    #expect(result.matched?.matchedText == "git reset --hard")
    #expect(result.matched?.span == MatchSpan(start: 0, end: 16))
    #expect(result.matched?.searchText == "git reset --hard")
}

@Test func evaluate_oversizeIsIndeterminate() throws {
    let command = String(repeating: "a", count: 65_537)
    let result = try run(command)
    #expect(result.decision == .indeterminate(.commandTooLarge))
    #expect(!result.quickRejected)
}

@Test func evaluate_missingCorePacksIsIndeterminate() throws {
    let onlyGit = samplePacks().filter { $0.id == .coreGit }
    let result = try run("git reset --hard", packs: onlyGit)
    #expect(result.decision == .indeterminate(.corePacksUnavailable))
    if case .deny = result.decision {
        Issue.record("must not invent a deny")
    }
}

@Test func evaluate_emptyCommandAllows() throws {
    let result = try run("   ")
    #expect(result.decision == .allow)
}

@Test func evaluate_allowsQuotedPythonPrintOfReset() throws {
    let result = try run(#"python3 -c "print('git reset --hard')""#)
    #expect(result.decision == .allow)
}

@Test func evaluate_deniesBashHeredocReset() throws {
    let result = try run("bash <<'EOF'\ngit reset --hard\nEOF")
    guard case .deny(let deny) = result.decision else {
        Issue.record("bash heredoc reset must deny, got \(result.decision)")
        return
    }
    #expect(deny.ruleID.rawValue == "core.git:reset-hard")
}

@Test func evaluate_deniesGitAfterQuotedPythonHeredoc() throws {
    let result = try run("python3 <<'PY'\nprint(1)\nPY\ngit reset --hard")
    guard case .deny(let deny) = result.decision else {
        Issue.record("git after python heredoc must deny, got \(result.decision)")
        return
    }
    #expect(deny.ruleID.rawValue == "core.git:reset-hard")
}

@Test func evaluate_budgetExhaustedIsIndeterminate() throws {
    let result = try run("git reset --hard", budget: EvaluationBudget(maxPatternAttempts: 1))
    #expect(result.decision == .indeterminate(.budgetExhausted))
}

@Test func evaluate_emptyCorePacksAreUnavailable() throws {
    let empty = PackSnapshot(
        id: .coreGit,
        name: "git",
        description: "empty",
        keywords: ["git"],
        safe: [],
        destructive: []
    )
    let result = try run("git reset --hard", packs: [empty] + samplePacks().filter { $0.id == .coreFilesystem })
    #expect(result.decision == .indeterminate(.corePacksUnavailable))
}

@Test func evaluate_compiledMissingRequiredRuleIsIndeterminate() {
    let packs = samplePacks()
    let engine = ICUPatternEngine()
    let compiled = CompiledPacks<ICUCompiledPattern>(packs: [])
    let result = evaluate(
        EvaluationRequest(
            command: ShellCommand(rawValue: "git reset --hard"),
            enabledPacks: dayOnePackIDs
        ),
        packs: packs,
        patterns: engine,
        compiled: compiled
    )
    #expect(result.decision == .indeterminate(.corePacksUnavailable))
    if case .allow = result.decision {
        Issue.record("snapshots present with compiled missing reset-hard must not allow")
    }
}

@Test func evaluate_emptyEnabledPacksDoesNotDenyResetHard() throws {
    let packs = samplePacks()
    let engine = ICUPatternEngine()
    let compiled = try CompiledPacks<ICUCompiledPattern>.compile(packs: packs, using: engine)
    let result = evaluate(
        EvaluationRequest(
            command: ShellCommand(rawValue: "git reset --hard"),
            enabledPacks: []
        ),
        packs: packs,
        patterns: engine,
        compiled: compiled
    )
    #expect(result.decision == .allow)
    if case .deny = result.decision {
        Issue.record("empty enabledPacks means none enabled, not a deny")
    }
}

@Test func evaluate_emptyEnabledPacksStillRequireReady() {
    let engine = ICUPatternEngine()
    let compiled = CompiledPacks<ICUCompiledPattern>(packs: [])
    let result = evaluate(
        EvaluationRequest(
            command: ShellCommand(rawValue: "git reset --hard"),
            enabledPacks: []
        ),
        packs: [],
        patterns: engine,
        compiled: compiled
    )
    #expect(result.decision == .indeterminate(.corePacksUnavailable))
}

@Test func evaluate_compiledMissingForkBombIsIndeterminate() throws {
    var packs = samplePacks()
    packs = packs.map { pack in
        guard pack.id == .coreFilesystem else { return pack }
        var copy = pack
        copy.destructive.append(
            DestructiveRule(
                name: "fork-bomb",
                pattern: ":",
                severity: .critical,
                reason: "fork bomb"
            )
        )
        return copy
    }
    let engine = ICUPatternEngine()
    var compiled = try CompiledPacks<ICUCompiledPattern>.compile(packs: packs, using: engine)
    compiled.packs = compiled.packs.map { pack in
        guard pack.snapshot.id == .coreFilesystem else { return pack }
        var copy = pack
        copy.destructive.removeAll { $0.rule.name == "fork-bomb" }
        return copy
    }
    let result = evaluate(
        EvaluationRequest(
            command: ShellCommand(rawValue: "git reset --hard"),
            enabledPacks: dayOnePackIDs
        ),
        packs: packs,
        patterns: engine,
        compiled: compiled
    )
    #expect(result.decision == .indeterminate(.corePacksUnavailable))
    if case .allow = result.decision {
        Issue.record("compiled missing fork-bomb must not allow")
    }
}

/// `matches` would fire; `firstMatch` is the sole destructive hit test.
private struct HitlessPatternEngine: PatternEngine {
    func compile(_ pattern: String) throws(PatternCompileError) -> String { pattern }
    func matches(_ compiled: String, in text: String) -> Bool { true }
    func firstMatch(_ compiled: String, in text: String) -> Range<String.Index>? { nil }
}

@Test func evaluate_destructiveHitRequiresFirstMatch() throws {
    let packs = [
        PackSnapshot(
            id: .coreFilesystem,
            name: "fs",
            description: "fs",
            keywords: ["rm"],
            safe: [],
            destructive: [
                DestructiveRule(
                    name: "rm-rf-general",
                    pattern: #"rm\s+-rf"#,
                    severity: .high,
                    reason: "rm -rf is destructive"
                )
            ]
        ),
        PackSnapshot(
            id: .coreGit,
            name: "git",
            description: "git",
            keywords: ["git"],
            safe: [],
            destructive: [
                DestructiveRule(
                    name: "reset-hard",
                    pattern: #"git\s+reset\s+--hard"#,
                    severity: .critical,
                    reason: "git reset --hard destroys uncommitted changes"
                )
            ]
        )
    ]
    let engine = HitlessPatternEngine()
    let compiled = try CompiledPacks<String>.compile(packs: packs, using: engine)
    let result = evaluate(
        EvaluationRequest(
            command: ShellCommand(rawValue: "git reset --hard"),
            enabledPacks: dayOnePackIDs
        ),
        packs: packs,
        patterns: engine,
        compiled: compiled
    )
    #expect(result.decision == .allow)
    #expect(result.matched == nil)
    if case .deny = result.decision {
        Issue.record("matches-without-firstMatch must not deny")
        #expect(result.matched?.span != nil)
    }
}
