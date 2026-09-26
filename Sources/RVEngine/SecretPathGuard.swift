import RVDomain

enum SecretPathGuard {
    static let candidateCap = 64

    static func firstHit(
        in matchingView: MatchingView,
        catalog: SecretPathCatalog,
        includeMetadata: Bool = false
    ) -> RuleMatch? {
        guard !catalog.rules.isEmpty else { return nil }
        let view = matchingView.rawValue
        let segments = splitSegments(view)
        if segments.count > 1 {
            for segment in segments {
                if let hit = firstHit(
                    inHaystack: segment,
                    catalog: catalog,
                    searchText: view,
                    includeMetadata: includeMetadata
                ) {
                    return hit
                }
            }
        }
        return firstHit(
            inHaystack: view,
            catalog: catalog,
            searchText: view,
            includeMetadata: includeMetadata
        )
    }

    private static func firstHit(
        inHaystack haystack: String,
        catalog: SecretPathCatalog,
        searchText: String,
        includeMetadata: Bool
    ) -> RuleMatch? {
        for candidate in candidates(in: haystack, includeMetadata: includeMetadata) {
            if let rule = catalog.firstMatch(of: candidate) {
                let ruleID = RuleID(pack: .coreSecrets, pattern: rule.pattern)
                return RuleMatch(
                    ruleID: ruleID,
                    severity: .high,
                    reason: rule.reason,
                    regex: nil,
                    matchedText: candidate,
                    searchText: searchText
                )
            }
        }
        return nil
    }

    private static func candidates(in haystack: String, includeMetadata: Bool) -> [String] {
        // C1: lex via the shared pipeline, then route on Argv. The Argv is
        // built manually (not via Argv(tokens:)) so newline lexemes survive:
        // they are load-bearing operands below, exactly as when the legacy
        // tokenizeCommand stream carried them. A leading "\n" routes to
        // `.other` (basename can never equal a head name), and interior
        // "\n" words count as grep positionals and find path operands.
        let tokens = ShellPipeline.tokenize(haystack)
        guard let head = tokens.first else { return [] }
        let argv = Argv(program: head.lexeme, args: tokens.dropFirst().map(\.lexeme))
        switch headKind(basename(argv.program)) {
        case .nonPath:
            return []
        case .grep:
            return grepCandidates(argv.args)
        case .find:
            return findCandidates(argv.args)
        case .metadata:
            guard includeMetadata else { return [] }
            return otherCandidates(argv.args)
        case .other:
            return otherCandidates(argv.args)
        }
    }
}

private enum HeadKind {
    case nonPath
    case grep
    case find
    case metadata
    case other
}

private func headKind(_ argv0: String) -> HeadKind {
    switch argv0.lowercased() {
    case "echo", "printf":
        return .nonPath
    case "grep", "rg":
        return .grep
    case "find":
        return .find
    case "ls", "test", "stat":
        return .metadata
    default:
        return .other
    }
}

private enum OperandFlag {
    case regexp(attached: String?)
    case file(attached: String?)
    case files
    case equalsValue(String)
    case ignore
}

/// Maps one grammar token to the guard's grep operand role.
///
/// Total over `FlagToken`: `.positional` yields `nil`, matching the legacy
/// `parseFlag` returning `nil` for non-dash words. `.terminator` also yields
/// `nil` (legacy `parseFlag("--")` was `nil`), but the caller consumes it
/// first, exactly as the legacy loop tested `decoded == "--"` before calling
/// `parseFlag`. `classify` never emits `.dangling`, so that arm only exists
/// for totality.
private func operandFlag(for token: FlagToken) -> OperandFlag? {
    switch token {
    case .positional, .terminator, .dangling:
        return nil
    case .loneDash:
        // Legacy `parseFlag("-")` fell through to `.ignore`: the empty letter
        // run vacuously satisfies the all-letters test and contains no e/f.
        return .ignore
    case .long(let name, let attached):
        switch name {
        case "regexp":
            return .regexp(attached: attached)
        case "file":
            return .file(attached: attached)
        case "files":
            // Attached values are ignored here, as before: `--files=x` was
            // `.files`, never `.equalsValue`.
            return .files
        default:
            if let attached {
                return .equalsValue(attached)
            }
            return .ignore
        }
    case .shorts(let letters, _):
        guard letters.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            return .ignore
        }
        if letters.contains("f") {
            return .file(attached: nil)
        }
        if letters.contains("e") {
            return .regexp(attached: nil)
        }
        return .ignore
    case .shortEquals(_, let value):
        return .equalsValue(value)
    }
}

private func operandCandidate(_ decoded: String) -> String? {
    if decoded == "--" { return nil }
    if decoded.hasPrefix("-") {
        guard let eq = decoded.firstIndex(of: "="), eq > decoded.startIndex else {
            return nil
        }
        return String(decoded[decoded.index(after: eq)...])
    }
    if let eq = decoded.firstIndex(of: "="), eq > decoded.startIndex {
        return String(decoded[decoded.index(after: eq)...])
    }
    return decoded
}

/// Grep-family candidate extraction over grammar-classified argv words.
///
/// The state machine mirrors the legacy loop: a pending `-e`/`-f` value
/// consumes the next word verbatim (even `"--"` or dash-led words), `--`
/// flips to positional mode, `-e`/`-f`/`--files` mark the pattern as given,
/// and otherwise the first positional is the pattern. Newline words classify
/// as `.positional` and count as positionals, as before.
private func grepCandidates(_ words: [String]) -> [String] {
    let tokens = words.map(FlagToken.classify)
    var collected: [String] = []
    var skipFirstPositional = true
    var expectRegexp = false
    var expectFile = false
    var afterDoubleDash = false

    func add(_ value: String) {
        guard collected.count < SecretPathGuard.candidateCap else { return }
        guard !value.isEmpty else { return }
        collected.append(value)
    }

    for (word, token) in zip(words, tokens) {
        if collected.count >= SecretPathGuard.candidateCap { break }
        if expectRegexp {
            expectRegexp = false
            continue
        }
        if expectFile {
            expectFile = false
            add(word)
            continue
        }
        if afterDoubleDash {
            if skipFirstPositional {
                skipFirstPositional = false
                continue
            }
            add(word)
            continue
        }
        if case .terminator = token {
            afterDoubleDash = true
            continue
        }
        if let flag = operandFlag(for: token) {
            switch flag {
            case .regexp(let attached):
                skipFirstPositional = false
                if attached == nil {
                    expectRegexp = true
                }
            case .file(let attached):
                skipFirstPositional = false
                if let attached {
                    add(attached)
                } else {
                    expectFile = true
                }
            case .files:
                skipFirstPositional = false
            case .equalsValue(let value):
                add(value)
            case .ignore:
                break
            }
            continue
        }
        if skipFirstPositional {
            skipFirstPositional = false
            continue
        }
        add(word)
    }
    return collected
}

/// Find candidate extraction: path operands before the first predicate word.
///
/// A word starts the predicate section exactly when the legacy test held:
/// every dash-led word (all non-`.positional` grammar cases) plus the bare
/// `(`, `!`, and `;` operands. `-name`/`-iname`/`-path`, read via
/// `singleDashWord` (which matches exactly those three literals), skip their
/// value, since patterns are not paths.
private func findCandidates(_ words: [String]) -> [String] {
    let tokens = words.map(FlagToken.classify)
    var collected: [String] = []
    var beforePredicate = true
    var skipValue = false

    func add(_ value: String) {
        guard collected.count < SecretPathGuard.candidateCap else { return }
        guard !value.isEmpty else { return }
        collected.append(value)
    }

    for token in tokens {
        if collected.count >= SecretPathGuard.candidateCap { break }
        if skipValue {
            skipValue = false
            continue
        }
        switch token {
        case .positional("("), .positional("!"), .positional(";"):
            beforePredicate = false
        case .positional(let word):
            if beforePredicate, let candidate = operandCandidate(word) {
                add(candidate)
            }
        default:
            beforePredicate = false
            if let nameWord = token.singleDashWord,
                nameWord == "name" || nameWord == "iname" || nameWord == "path"
            {
                skipValue = true
            }
        }
    }
    return collected
}

private func otherCandidates(_ words: [String]) -> [String] {
    var collected: [String] = []
    for word in words {
        if collected.count >= SecretPathGuard.candidateCap { break }
        guard let candidate = operandCandidate(word), !candidate.isEmpty else {
            continue
        }
        collected.append(candidate)
    }
    return collected
}
