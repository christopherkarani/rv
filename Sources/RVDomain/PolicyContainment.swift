/// One concrete action a candidate rule set states a weaker verdict on than
/// the ceiling. `action` is what the typed evaluator matches; `argv` is a
/// shell spelling of the same action for people to read and try.
public struct PolicyContainmentWitness: Sendable, Equatable {
    public var action: SemanticAction
    public var argv: [String]
    public var candidateRule: RuleID
    public var candidateVerdict: TypedRuleVerdict
    public var ceilingRule: RuleID
    public var ceilingVerdict: TypedRuleVerdict

    public init(
        action: SemanticAction,
        argv: [String],
        candidateRule: RuleID,
        candidateVerdict: TypedRuleVerdict,
        ceilingRule: RuleID,
        ceilingVerdict: TypedRuleVerdict
    ) {
        self.action = action
        self.argv = argv
        self.candidateRule = candidateRule
        self.candidateVerdict = candidateVerdict
        self.ceilingRule = ceilingRule
        self.ceilingVerdict = ceilingVerdict
    }

    /// `argv` as one shell line, quoted where needed and safe to print.
    public var command: String {
        DisplayedText.field(argv.map(PolicyContainment.shellWord).joined(separator: " "))
    }

    /// The witness as something to check, not run: the read-only
    /// `rv explain` of `command`.
    public var checkCommand: String {
        CommandVocabulary.Alias.why.invocation + " " + PolicyContainment.shellWord(command)
    }
}

public enum PolicyContainmentResult: Sendable, Equatable {
    /// Every action the candidate speaks on gets at least the ceiling's verdict.
    case contained
    case exceeds(PolicyContainmentWitness)
    /// Containment could not be decided. Callers treat it as exceeding.
    case indeterminate(String)

    public var isContained: Bool {
        if case .contained = self { return true }
        return false
    }
}

/// Containment of typed rules in a ceiling, decided without a solver.
///
/// A rule set *states* a verdict on an action when one of its rules matches
/// it; the statement is the strongest matching verdict (deny > ask > allow),
/// the same rank the evaluator uses. A candidate exceeds the ceiling when it
/// states a weaker verdict than the ceiling on some action: an allow where
/// the ceiling asks or denies, or an ask where it denies. Silence never
/// exceeds: a layer that says nothing about an action defers to the others.
///
/// Decision per rule kind. Matching reads only a few fields of each action,
/// so every action falls in one of finitely many classes, and one
/// representative per class is enough:
/// - `gitPush`: each force value times each refspec destination class (no
///   refspec, a destination no rule names, each destination a rule names).
///   A destination matches a rule's branch `b` when it is `b` or ends in
///   `/b`, so a destination matches exactly the rules that its longest
///   matching named branch matches.
/// - `gitDiscardWorktree`: pathspec sets. A rule matches when the set holds
///   its pathspec, so the set made of one ceiling rule's pathspec and one
///   candidate rule's pathspec is a witness whenever any set is.
/// - `gitReset`: each mode. `gitClean`, `filesystemDelete`: each flag pair.
///   `filesystemMove`: one move.
///
/// Every witness is checked with `PolicyMatch` before it is returned.
/// Inputs past the bounds, or a branch no refspec can spell, are
/// indeterminate, never contained.
public enum PolicyContainment {
    public static let maximumRules = 1024
    static let maximumActions = 65_536
    static let witnessName = "rv-ceiling-witness"

    public static func check(candidate: [TypedRule], ceiling: [TypedRule]) -> PolicyContainmentResult {
        guard candidate.count <= maximumRules, ceiling.count <= maximumRules else {
            return .indeterminate("more than \(maximumRules) rules")
        }
        let restricting = ceiling.filter { $0.verdict != .allow }
        guard restricting.isEmpty == false, candidate.isEmpty == false else { return .contained }
        let actions: [SemanticAction]
        switch representatives(candidate: candidate, ceiling: restricting) {
        case .success(let list): actions = list
        case .failure(let reason): return .indeterminate(reason.text)
        }
        for action in actions {
            guard let stated = strongest(candidate, action), let bound = strongest(restricting, action) else {
                continue
            }
            guard rank(stated.verdict) < rank(bound.verdict) else { continue }
            return .exceeds(
                PolicyContainmentWitness(
                    action: action,
                    argv: argv(action),
                    candidateRule: stated.id,
                    candidateVerdict: stated.verdict,
                    ceilingRule: bound.id,
                    ceilingVerdict: bound.verdict
                ))
        }
        return .contained
    }

    /// Strongest matching rule; the first one listed wins a tie.
    static func strongest(_ rules: [TypedRule], _ action: SemanticAction) -> TypedRule? {
        var best: TypedRule?
        for rule in rules where PolicyMatch.matches(rule.predicate, action) {
            if let current = best, rank(rule.verdict) <= rank(current.verdict) { continue }
            best = rule
        }
        return best
    }

    static func rank(_ verdict: TypedRuleVerdict) -> Int {
        switch verdict {
        case .allow: 0
        case .ask: 1
        case .deny: 2
        }
    }

    struct Undecidable: Error {
        var text: String
    }

    /// One action per matching class, for every kind both sides speak on.
    static func representatives(
        candidate: [TypedRule],
        ceiling: [TypedRule]
    ) -> Result<[SemanticAction], Undecidable> {
        let predicates = (candidate + ceiling).map(\.predicate)
        var actions: [SemanticAction] = []
        for kind in Kind.allCases where shared(kind, candidate, ceiling) {
            switch kind {
            case .push:
                switch pushActions(predicates) {
                case .success(let list): actions += list
                case .failure(let error): return .failure(error)
                }
            case .discard:
                let pairs = ceiling.filter { Kind($0.predicate) == .discard }.count
                    * candidate.filter { Kind($0.predicate) == .discard }.count
                guard pairs <= maximumActions else {
                    return .failure(Undecidable(text: "too many pathspec rules to compare"))
                }
                actions += discardActions(candidate: candidate, ceiling: ceiling)
            case .reset:
                actions += resetModes.map { .git(.reset(mode: $0, target: nil)) }
            case .clean:
                actions += flagPairs.map { .git(.clean(force: $0.0, dryRun: false, directories: $0.1)) }
            case .delete:
                actions += flagPairs.map { .filesystem(.delete(targets: [witnessTarget], recursive: $0.0, force: $0.1)) }
            case .move:
                actions.append(.filesystem(.move(sources: [witnessTarget], destination: movedTarget)))
            }
        }
        guard actions.count <= maximumActions else {
            return .failure(Undecidable(text: "too many actions to compare"))
        }
        return .success(actions)
    }

    enum Kind: CaseIterable {
        case push, discard, reset, clean, delete, move

        init(_ predicate: PolicyPredicate) {
            switch predicate {
            case .gitPush: self = .push
            case .gitDiscardWorktree: self = .discard
            case .gitReset: self = .reset
            case .gitClean: self = .clean
            case .filesystemDelete: self = .delete
            case .filesystemMove: self = .move
            }
        }
    }

    private static func shared(_ kind: Kind, _ candidate: [TypedRule], _ ceiling: [TypedRule]) -> Bool {
        candidate.contains { Kind($0.predicate) == kind } && ceiling.contains { Kind($0.predicate) == kind }
    }

    /// Every `GitPushForce`. The switch stops compiling when a case is added,
    /// so the list cannot silently fall behind.
    static let pushForces: [GitPushForce] = [.none, .forceWithLease, .force]
    private static func coversPushForce(_ force: GitPushForce) {
        switch force {
        case .none, .forceWithLease, .force: break
        }
    }

    /// Every `GitResetMode`, kept complete the same way.
    static let resetModes: [GitResetMode] = [.soft, .mixed, .hard, .merge, .keep]
    private static func coversResetMode(_ mode: GitResetMode) {
        switch mode {
        case .soft, .mixed, .hard, .merge, .keep: break
        }
    }

    private static let flagPairs: [(Bool, Bool)] = [(false, false), (false, true), (true, false), (true, true)]

    static let witnessTarget = FilesystemTarget(
        apparent: witnessName,
        canonical: witnessName,
        scope: .insideRepository,
        kind: .unknown
    )
    static let movedTarget = FilesystemTarget(
        apparent: witnessName + "-moved",
        canonical: witnessName + "-moved",
        scope: .insideRepository,
        kind: .unknown
    )

    private static func pushActions(_ predicates: [PolicyPredicate]) -> Result<[SemanticAction], Undecidable> {
        var branches: [String] = []
        for predicate in predicates {
            guard case .gitPush(_, let branch?) = predicate else { continue }
            // An empty branch matches through `:`-only and `/`-ending
            // destinations, which the classes below do not model.
            guard branch.isEmpty == false else {
                return .failure(Undecidable(text: "a gitPush rule names an empty branch"))
            }
            if branches.contains(branch) == false { branches.append(branch) }
        }
        var refspecs: [String?] = [nil]
        guard let fresh = freshDestination(avoiding: branches) else {
            return .failure(Undecidable(text: "no unnamed push destination found"))
        }
        refspecs.append(fresh)
        for branch in branches where branch.contains(":") == false {
            // `names` drops one leading `+` (the force marker) before reading
            // the destination.
            let refspec = branch.hasPrefix("+") ? "+" + branch : branch
            guard pushMatches(branch, refspec: refspec) else {
                return .failure(Undecidable(text: "a gitPush branch has no refspec spelling"))
            }
            refspecs.append(refspec)
        }
        var actions: [SemanticAction] = []
        for force in pushForces {
            for refspec in refspecs {
                actions.append(.git(.push(remote: refspec == nil ? nil : "origin", refspec: refspec, force: force)))
            }
        }
        return .success(actions)
    }

    private static func pushMatches(_ branch: String, refspec: String) -> Bool {
        PolicyMatch.matches(
            .gitPush(force: .any, branch: branch),
            .git(.push(remote: "origin", refspec: refspec, force: .none))
        )
    }

    private static func freshDestination(avoiding branches: [String]) -> String? {
        for suffix in 0..<64 {
            let name = suffix == 0 ? witnessName : "\(witnessName)-\(suffix)"
            if branches.allSatisfy({ pushMatches($0, refspec: name) == false }) { return name }
        }
        return nil
    }

    private static func discardActions(candidate: [TypedRule], ceiling: [TypedRule]) -> [SemanticAction] {
        let named = Set((candidate + ceiling).compactMap { rule -> String? in
            guard case .gitDiscardWorktree(let pathspec?) = rule.predicate else { return nil }
            return pathspec
        })
        var fresh = witnessName
        var suffix = 1
        while named.contains(fresh) {
            fresh = "\(witnessName)-\(suffix)"
            suffix += 1
        }
        func spec(_ rule: TypedRule) -> String? {
            guard case .gitDiscardWorktree(let pathspec) = rule.predicate else { return nil }
            return pathspec ?? fresh
        }
        var actions: [SemanticAction] = []
        for bound in ceiling {
            guard let boundSpec = spec(bound) else { continue }
            for stated in candidate {
                guard let statedSpec = spec(stated) else { continue }
                let specs = boundSpec == statedSpec ? [boundSpec] : [boundSpec, statedSpec]
                actions.append(.git(.discardWorktree(pathspecs: specs, source: nil)))
            }
        }
        return actions
    }

    /// Shell spelling of a witness action. Covers the actions
    /// `representatives` builds; anything else spells as its kind only.
    static func argv(_ action: SemanticAction) -> [String] {
        switch action {
        case .git(.push(let remote, let refspec, let force)):
            var words = ["git", "push"]
            switch force {
            case .none: break
            case .forceWithLease: words.append("--force-with-lease")
            case .force: words.append("--force")
            }
            if let refspec { words += [remote ?? "origin", refspec] }
            return words
        case .git(.discardWorktree(let pathspecs, _)):
            return ["git", "checkout", "--"] + pathspecs
        case .git(.reset(let mode, _)):
            return ["git", "reset", "--\(mode.rawValue)"]
        case .git(.clean(let force, _, let directories)):
            return ["git", "clean"] + (force ? ["-f"] : []) + (directories ? ["-d"] : [])
        case .filesystem(.delete(let targets, let recursive, let force)):
            return ["rm"] + (recursive ? ["-r"] : []) + (force ? ["-f"] : []) + targets.map(\.apparent)
        case .filesystem(.move(let sources, let destination)):
            return ["mv"] + sources.map(\.apparent) + [destination.apparent]
        case .git:
            return ["git"]
        case .filesystem:
            return []
        }
    }

    /// Option words `argv` emits itself. Every other word that starts with
    /// `-`, `=`, or `~` (a pathspec or refspec from a rule) is quoted, so it
    /// cannot read as an option, a zsh `=cmd`, or a home directory.
    static let optionWords: Set<String> = Set(
        ["--", "--force", "--force-with-lease", "-f", "-d", "-r"] + resetModes.map { "--\($0.rawValue)" }
    )

    /// POSIX shell word: bare when it is plain, single-quoted otherwise. A
    /// quote is spelled `'"'"'`, without a backslash, so display escaping
    /// (which doubles backslashes) leaves the word unchanged.
    static func shellWord(_ word: String) -> String {
        let leadingIsSafe = word.first.map { "-=~".contains($0) == false } ?? false
        let plain = (leadingIsSafe || optionWords.contains(word)) && word.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9": true
            case "-", "_", ".", "/", ":", "+", "=", "@", "%", ",": true
            default: false
            }
        }
        if plain { return word }
        var quoted = "'"
        for character in word {
            quoted += character == "'" ? "'\"'\"'" : String(character)
        }
        return quoted + "'"
    }
}
