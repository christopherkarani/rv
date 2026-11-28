import Testing
import RVDomain

/// Containment of typed rules in a ceiling. Each kind is checked against a
/// brute-force oracle over a wider action universe than the checker
/// enumerates: the checker must never say `contained` when the oracle finds
/// an exceeding action, and every witness must replay through the evaluator.
@Suite("PolicyContainment")
struct PolicyContainmentTests {
    // MARK: Examples

    @Test func allowMainUnderForcePushDeny_witnessIsForcePushToMain() {
        let candidate = [rule("repo-allow", .allow, .gitPush(force: .any, branch: "main"))]
        let ceiling = [rule("no-force", .deny, .gitPush(force: .exactly(.force), branch: nil))]
        guard case .exceeds(let witness) = PolicyContainment.check(candidate: candidate, ceiling: ceiling) else {
            Issue.record("expected exceeds")
            return
        }
        #expect(witness.action == .git(.push(remote: "origin", refspec: "main", force: .force)))
        #expect(witness.command == "git push --force origin main")
        #expect(witness.candidateRule == candidate[0].id)
        #expect(witness.ceilingRule == ceiling[0].id)
        #expect(witness.candidateVerdict == .allow)
        #expect(witness.ceilingVerdict == .deny)
        assertReplays(witness, candidate: candidate, ceiling: ceiling)
    }

    @Test func silentCandidate_isContained() {
        let ceiling = [rule("no-force", .deny, .gitPush(force: .any, branch: nil))]
        #expect(PolicyContainment.check(candidate: [], ceiling: ceiling) == .contained)
        let elsewhere = [rule("reset", .allow, .gitReset(mode: .soft))]
        #expect(PolicyContainment.check(candidate: elsewhere, ceiling: ceiling) == .contained)
    }

    @Test func askUnderDeny_exceeds_askUnderAsk_isContained() {
        let ask = [rule("ask-hard", .ask, .gitReset(mode: .hard))]
        let deny = [rule("no-hard", .deny, .gitReset(mode: nil))]
        guard case .exceeds(let witness) = PolicyContainment.check(candidate: ask, ceiling: deny) else {
            Issue.record("expected exceeds")
            return
        }
        #expect(witness.command == "git reset --hard")
        assertReplays(witness, candidate: ask, ceiling: deny)
        let askCeiling = [rule("ask-any", .ask, .gitReset(mode: nil))]
        #expect(PolicyContainment.check(candidate: ask, ceiling: askCeiling) == .contained)
    }

    @Test func candidateDenyCoversItsOwnAllow_isContained() {
        let candidate = [
            rule("allow-push", .allow, .gitPush(force: .any, branch: nil)),
            rule("deny-force", .deny, .gitPush(force: .exactly(.force), branch: nil)),
        ]
        let ceiling = [rule("no-force", .deny, .gitPush(force: .exactly(.force), branch: nil))]
        #expect(PolicyContainment.check(candidate: candidate, ceiling: ceiling) == .contained)
    }

    @Test func branchSuffixOverlap_isFound() {
        // `feature/main` ends in `/main`, so a push to it matches both rules.
        let candidate = [rule("allow-feature", .allow, .gitPush(force: .any, branch: "feature/main"))]
        let ceiling = [rule("no-main", .deny, .gitPush(force: .any, branch: "main"))]
        guard case .exceeds(let witness) = PolicyContainment.check(candidate: candidate, ceiling: ceiling) else {
            Issue.record("expected exceeds")
            return
        }
        #expect(witness.command == "git push origin feature/main")
        assertReplays(witness, candidate: candidate, ceiling: ceiling)
    }

    @Test func disjointBranches_areContained() {
        let candidate = [rule("allow-dev", .allow, .gitPush(force: .any, branch: "dev"))]
        let ceiling = [rule("no-main", .deny, .gitPush(force: .any, branch: "main"))]
        #expect(PolicyContainment.check(candidate: candidate, ceiling: ceiling) == .contained)
    }

    @Test func discardPathspecs_combineIntoOneWitness() {
        let candidate = [rule("allow-docs", .allow, .gitDiscardWorktree(pathspec: "docs"))]
        let ceiling = [rule("no-src", .deny, .gitDiscardWorktree(pathspec: "src"))]
        guard case .exceeds(let witness) = PolicyContainment.check(candidate: candidate, ceiling: ceiling) else {
            Issue.record("expected exceeds")
            return
        }
        #expect(witness.command == "git checkout -- src docs")
        assertReplays(witness, candidate: candidate, ceiling: ceiling)
    }

    @Test func deleteAndMove_witnessesNameAPath() {
        let candidate = [
            rule("allow-rm", .allow, .filesystemDelete(recursive: true, force: nil)),
            rule("allow-mv", .allow, .filesystemMove),
        ]
        let deleteCeiling = [rule("no-rm-rf", .deny, .filesystemDelete(recursive: true, force: true))]
        guard case .exceeds(let delete) = PolicyContainment.check(candidate: candidate, ceiling: deleteCeiling) else {
            Issue.record("expected exceeds")
            return
        }
        #expect(delete.command == "rm -r -f rv-ceiling-witness")
        assertReplays(delete, candidate: candidate, ceiling: deleteCeiling)
        let moveCeiling = [rule("no-mv", .ask, .filesystemMove)]
        guard case .exceeds(let move) = PolicyContainment.check(candidate: candidate, ceiling: moveCeiling) else {
            Issue.record("expected exceeds")
            return
        }
        #expect(move.command == "mv rv-ceiling-witness rv-ceiling-witness-moved")
        assertReplays(move, candidate: candidate, ceiling: moveCeiling)
    }

    @Test func emptyBranch_isIndeterminateNeverContained() {
        let candidate = [rule("allow-empty", .allow, .gitPush(force: .any, branch: ""))]
        let ceiling = [rule("no-dev", .deny, .gitPush(force: .any, branch: "dev"))]
        guard case .indeterminate = PolicyContainment.check(candidate: candidate, ceiling: ceiling) else {
            Issue.record("expected indeterminate")
            return
        }
    }

    @Test func tooManyRules_isIndeterminate() {
        let many = (0...PolicyContainment.maximumRules).map {
            rule("r\($0)", .allow, .gitReset(mode: .soft))
        }
        let ceiling = [rule("no-reset", .deny, .gitReset(mode: nil))]
        guard case .indeterminate = PolicyContainment.check(candidate: many, ceiling: ceiling) else {
            Issue.record("expected indeterminate")
            return
        }
    }

    @Test func witnessCommand_quotesAndEscapesUntrustedWords() {
        let candidate = [rule("allow", .allow, .gitDiscardWorktree(pathspec: "it's\u{1B}[2J"))]
        let ceiling = [rule("deny", .deny, .gitDiscardWorktree(pathspec: nil))]
        guard case .exceeds(let witness) = PolicyContainment.check(candidate: candidate, ceiling: ceiling) else {
            Issue.record("expected exceeds")
            return
        }
        #expect(witness.command.contains("\u{1B}") == false)
        #expect(witness.command.contains("'it'\"'\"'s"))
    }

    @Test func witnessCommand_quotesWordsThatReadAsOptionsOrExpand() {
        for spec in ["-rf", "=ls", "~/notes"] {
            let candidate = [rule("allow", .allow, .gitDiscardWorktree(pathspec: spec))]
            let ceiling = [rule("deny", .deny, .gitDiscardWorktree(pathspec: nil))]
            guard case .exceeds(let witness) = PolicyContainment.check(candidate: candidate, ceiling: ceiling) else {
                Issue.record("expected exceeds for \(spec)")
                continue
            }
            #expect(witness.command.hasSuffix(" '\(spec)'"), "\(witness.command)")
            #expect(witness.command.hasPrefix("git checkout -- "), "option words the witness emits stay bare")
        }
    }

    @Test func witnessCheckCommand_isReadOnlyExplain() {
        let candidate = [rule("repo-allow", .allow, .gitPush(force: .any, branch: "main"))]
        let ceiling = [rule("no-force", .deny, .gitPush(force: .exactly(.force), branch: nil))]
        guard case .exceeds(let witness) = PolicyContainment.check(candidate: candidate, ceiling: ceiling) else {
            Issue.record("expected exceeds")
            return
        }
        #expect(witness.checkCommand == "rv why 'git push --force origin main'")
    }

    // MARK: Properties, one per rule kind

    @Test(arguments: Kind.allCases)
    func containmentAgreesWithOracle(kind: Kind) {
        var generator = SplitMix64(seed: 0x5EED_0000 + UInt64(Kind.allCases.firstIndex(of: kind) ?? 0))
        var exceeded = 0
        var contained = 0
        for _ in 0..<400 {
            let candidate = randomRules(kind, prefix: "c", count: Int(generator.next() % 4) + 1, &generator)
            let ceiling = randomRules(kind, prefix: "k", count: Int(generator.next() % 4) + 1, &generator)
            let oracle = oracleExceeds(kind, candidate: candidate, ceiling: ceiling)
            switch PolicyContainment.check(candidate: candidate, ceiling: ceiling) {
            case .contained:
                #expect(oracle == nil, "missed \(String(describing: oracle)) for \(candidate) under \(ceiling)")
                contained += 1
            case .exceeds(let witness):
                assertReplays(witness, candidate: candidate, ceiling: ceiling)
                exceeded += 1
            case .indeterminate(let reason):
                Issue.record("indeterminate (\(reason)) for \(candidate) under \(ceiling)")
            }
        }
        // The generator must exercise both outcomes, or the property is vacuous.
        #expect(exceeded > 0)
        #expect(contained > 0)
    }

    // MARK: Helpers

    enum Kind: String, CaseIterable, Sendable {
        case push, discard, reset, clean, delete, move
    }

    private func rule(_ id: String, _ verdict: TypedRuleVerdict, _ predicate: PolicyPredicate) -> TypedRule {
        TypedRule(id: RuleID(pack: .typedGit, pattern: id), predicate: predicate, verdict: verdict, origin: .repo)
    }

    /// The candidate states the weaker verdict, the ceiling the stronger, both
    /// as the evaluator ranks them, and the named rules really match.
    private func assertReplays(_ witness: PolicyContainmentWitness, candidate: [TypedRule], ceiling: [TypedRule]) {
        let candidateVerdict = ActionPolicyEngine.typedRestriction(witness.action, rules: candidate)
        let ceilingVerdict = ActionPolicyEngine.typedRestriction(witness.action, rules: ceiling)
        switch witness.ceilingVerdict {
        case .deny:
            guard case .hardDeny? = ceilingVerdict?.decision else {
                Issue.record("ceiling does not deny \(witness.command): \(String(describing: ceilingVerdict))")
                return
            }
            if case .hardDeny? = candidateVerdict?.decision {
                Issue.record("candidate also denies \(witness.command)")
            }
        case .ask:
            guard case .mandatoryHuman? = ceilingVerdict?.decision else {
                Issue.record("ceiling does not ask for \(witness.command): \(String(describing: ceilingVerdict))")
                return
            }
            #expect(candidateVerdict == nil, "candidate restricts \(witness.command)")
        case .allow:
            Issue.record("a ceiling allow is never a bound")
        }
        #expect(candidate.contains { $0.id == witness.candidateRule && PolicyMatch.matches($0.predicate, witness.action) })
        #expect(ceiling.contains { $0.id == witness.ceilingRule && PolicyMatch.matches($0.predicate, witness.action) })
        #expect(rank(witness.candidateVerdict) < rank(witness.ceilingVerdict))
    }

    private func rank(_ verdict: TypedRuleVerdict) -> Int {
        switch verdict {
        case .allow: 0
        case .ask: 1
        case .deny: 2
        }
    }

    private func strongest(_ rules: [TypedRule], _ action: SemanticAction) -> TypedRuleVerdict? {
        rules.filter { PolicyMatch.matches($0.predicate, action) }.map(\.verdict).max { rank($0) < rank($1) }
    }

    private func oracleExceeds(_ kind: Kind, candidate: [TypedRule], ceiling: [TypedRule]) -> SemanticAction? {
        universe(kind).first { action in
            guard let stated = strongest(candidate, action), let bound = strongest(ceiling, action) else { return false }
            return rank(stated) < rank(bound)
        }
    }

    private static let branches = ["main", "dev", "heads/main", "refs/heads/main", "feature/main", "+main", "a:b", "x/dev"]
    private static let pathspecs = ["src", "docs", "README.md", "src/a"]
    private static let forces: [GitPushForce] = [.none, .forceWithLease, .force]
    private static let modes: [GitResetMode] = [.soft, .mixed, .hard, .merge, .keep]

    /// Wider than the checker's representatives: every refspec spelling
    /// (`+`, `src:dst`, nested and unrelated destinations) and every
    /// pathspec subset up to three, plus restores.
    private func universe(_ kind: Kind) -> [SemanticAction] {
        switch kind {
        case .push:
            var refspecs: [String?] = [nil, "", ":", "other", "a/b/c", "main:", "HEAD:other"]
            for branch in Self.branches {
                refspecs += [branch, "+" + branch, "x/" + branch, "HEAD:" + branch, "+HEAD:" + branch, branch + ":z"]
            }
            return Self.forces.flatMap { force in
                refspecs.map { SemanticAction.git(.push(remote: "origin", refspec: $0, force: force)) }
            }
        case .discard:
            let pool = Self.pathspecs + ["other"]
            var sets: [[String]] = [[]]
            for a in pool.indices {
                sets.append([pool[a]])
                for b in pool.indices where b > a {
                    sets.append([pool[a], pool[b]])
                    for c in pool.indices where c > b { sets.append([pool[a], pool[b], pool[c]]) }
                }
            }
            return sets.flatMap { specs in
                [
                    SemanticAction.git(.discardWorktree(pathspecs: specs, source: nil)),
                    .git(.restore(pathspecs: specs, destination: .worktreeAndIndex, source: "HEAD")),
                    .git(.restore(pathspecs: specs, destination: .index, source: nil)),
                ]
            }
        case .reset:
            return Self.modes.flatMap { mode in
                [SemanticAction.git(.reset(mode: mode, target: nil)), .git(.reset(mode: mode, target: "HEAD~1"))]
            }
        case .clean:
            return [false, true].flatMap { force in
                [false, true].flatMap { dryRun in
                    [false, true].map { SemanticAction.git(.clean(force: force, dryRun: dryRun, directories: $0)) }
                }
            }
        case .delete:
            let target = FilesystemTarget(apparent: "/tmp/x", canonical: "/tmp/x", scope: .outsideRepository, kind: .unknown)
            return [false, true].flatMap { recursive in
                [false, true].map { SemanticAction.filesystem(.delete(targets: [target], recursive: recursive, force: $0)) }
            }
        case .move:
            let source = FilesystemTarget(apparent: "a", canonical: "/r/a", scope: .insideRepository, kind: .sourceCode)
            let destination = FilesystemTarget(apparent: "b", canonical: "/r/b", scope: .insideRepository, kind: .unknown)
            return [.filesystem(.move(sources: [source], destination: destination))]
        }
    }

    private func randomRules(_ kind: Kind, prefix: String, count: Int, _ generator: inout SplitMix64) -> [TypedRule] {
        (0..<count).map { index in
            let verdict: TypedRuleVerdict = [.allow, .ask, .deny][Int(generator.next() % 3)]
            return rule("\(prefix)\(index)", verdict, randomPredicate(kind, &generator))
        }
    }

    private func randomPredicate(_ kind: Kind, _ generator: inout SplitMix64) -> PolicyPredicate {
        func pick<T>(_ values: [T]) -> T { values[Int(generator.next() % UInt64(values.count))] }
        func flag() -> Bool? { pick([nil, false, true]) }
        switch kind {
        case .push:
            let force: GitPushForceConstraint = pick([.any] + Self.forces.map { .exactly($0) })
            return .gitPush(force: force, branch: pick([nil] + Self.branches.map(Optional.some)))
        case .discard:
            return .gitDiscardWorktree(pathspec: pick([nil] + Self.pathspecs.map(Optional.some)))
        case .reset:
            return .gitReset(mode: pick([nil] + Self.modes.map(Optional.some)))
        case .clean:
            return .gitClean(force: flag(), directories: flag())
        case .delete:
            return .filesystemDelete(recursive: flag(), force: flag())
        case .move:
            return .filesystemMove
        }
    }
}

/// Deterministic generator so a failing case reproduces.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
