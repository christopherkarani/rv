import RVDomain

enum SecretPathGuard {
    static let candidateCap = 64

    /// Synthetic ruleID for commands whose operand count makes them
    /// unverifiable: more path candidates exist than `candidateCap` scans.
    /// Fail closed instead of silently skipping the excess operands.
    static let overflowPatternName = "operand-overflow"
    static let overflowDenialReason = "Too many path operands to analyze; refusing without a secret-path scan."

    /// Synthetic ruleID for commands whose operands cannot be modelled
    /// exactly (`find -regex … -exec`, a `man` pager command): over-deny.
    static let unmodelledPatternName = "unmodelled-operand"
    static let unmodelledDenialReason = "Command operands cannot be analyzed for secret paths; refusing."

    /// A bare command name (`less`, `cat`): run as a pager it reads nothing a
    /// secret path names.
    static func isPlainCommandName(_ value: String) -> Bool {
        value.isEmpty == false
            && value.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "+" }
    }

    static func firstHit(
        in matchingView: MatchingView,
        catalog: SecretPathCatalog,
        includeMetadata: Bool = false,
        resolution: SecretPathResolution? = nil,
        exempts: SecretPathExemption? = nil
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
                    includeMetadata: includeMetadata,
                    treatOverflowAsDenial: true,
                    resolution: resolution,
                    exempts: exempts
                ) {
                    return hit
                }
            }
            // Whole-view fallback: every segment scan already ran to
            // completion (an overflow denies above), so an operand drop from
            // the joined scan is an aggregate of fully scanned segments, not
            // a scan defect. Only a rule hit is significant here.
            return firstHit(
                inHaystack: view,
                catalog: catalog,
                searchText: view,
                includeMetadata: includeMetadata,
                treatOverflowAsDenial: false,
                resolution: resolution,
                exempts: exempts
            )
        }
        return firstHit(
            inHaystack: view,
            catalog: catalog,
            searchText: view,
            includeMetadata: includeMetadata,
            treatOverflowAsDenial: true,
            resolution: resolution,
            exempts: exempts
        )
    }

    private static func firstHit(
        inHaystack haystack: String,
        catalog: SecretPathCatalog,
        searchText: String,
        includeMetadata: Bool,
        treatOverflowAsDenial: Bool,
        resolution: SecretPathResolution? = nil,
        exempts: SecretPathExemption? = nil
    ) -> RuleMatch? {
        let scan = candidates(in: haystack, includeMetadata: includeMetadata)
        if scan.unmodelled {
            return overflowHit(
                searchText: searchText, pattern: unmodelledPatternName, reason: unmodelledDenialReason)
        }
        if treatOverflowAsDenial, scan.overflowed {
            return overflowHit(searchText: searchText)
        }
        for (index, operand) in scan.candidates.enumerated() {
            let expands = index < scan.expands.count ? scan.expands[index] : true
            let matching = index < scan.matching.count ? scan.matching[index] : .shell
            for candidate in spellings(of: operand, catalog: catalog, expands: expands, matching: matching) {
                // The resolved spelling is authoritative: a symlinked operand
                // IS its target, so the typed spelling participates only when
                // no distinct target exists. An exemption on one spelling never
                // vouches for the other, so scanning continues until a
                // non-exempt hit breaks out.
                let spelling = resolved(candidate, resolution: resolution) ?? candidate
                if let rule = catalog.firstMatch(of: spelling),
                   !isExempt(spelling, rule, exempts: exempts) {
                    return hit(spelling, rule: rule, searchText: searchText)
                }
            }
        }
        return nil
    }

    /// The spellings one operand word can open, typed spelling first: the
    /// shell drops backslash escapes (`\.env`), an input redirect or curl's
    /// `@` names a file (`<.env`, `-d@.env`), and a glob or brace word
    /// (`.env*`, `{.env,x}`, `~/.ss*/id_*`) opens whatever it matches, so a
    /// catalog name it can select stands in for it. `expands` is false for an
    /// option value (`--exclude='.*'`), which the shell never globs.
    static func spellings(
        of operand: String,
        catalog: SecretPathCatalog,
        expands: Bool = true,
        matching: SecretPathGlob.Matching = .shell
    ) -> [String] {
        var out = [operand]
        func add(_ spelling: String) {
            if spelling.isEmpty == false, out.contains(spelling) == false { out.append(spelling) }
        }
        var plain = unescapeBackslashPairs(operand)
        if let index = plain.firstIndex(where: { $0.isNumber == false }), plain[index] == "<",
            plain[plain.index(after: index)...].first.map({ $0 != "<" && $0 != "(" }) ?? false
        {
            plain = String(plain[plain.index(after: index)...])
            // `<>FILE` opens FILE read-write.
            if plain.hasPrefix(">") { plain.removeFirst() }
        }
        while plain.hasPrefix("@") { plain.removeFirst() }
        add(plain)
        // `curl -F f=@.env`, `f=<.env`, httpie `f@.env`: the file follows an
        // `@` or `=<` inside the word, and runs to a `;` (curl's field
        // options) or a `,` (curl's file list).
        var wordForms = [plain]
        for marker in ["@", "=<"] {
            guard let range = plain.range(of: marker) else { continue }
            var tail = String(plain[range.upperBound...])
            while tail.hasPrefix("@") || tail.hasPrefix("<") { tail.removeFirst() }
            wordForms.append(tail)
        }
        for form in wordForms {
            wordForms.append(contentsOf: form.split(whereSeparator: { ";,".contains($0) }).map(String.init))
        }
        for form in wordForms.dropFirst() { add(form) }
        if matching != .shell {
            // A find pattern is matched against names, never brace-expanded.
            for selected in SecretPathGlob.selections(plain, catalog: catalog, matching: matching) { add(selected) }
            if matching == .findNameFolded { add(plain.lowercased()) }
        } else if expands {
            for form in wordForms where form.contains(where: { "*?[{".contains($0) }) {
                for selected in SecretPathGlob.selections(form, catalog: catalog) { add(selected) }
            }
        }
        return out
    }

    /// Deny-by-default match for unverifiable input. `matchedText` stays nil
    /// so exemption lookup can never suppress it.
    private static func overflowHit(
        searchText: String,
        pattern: String = overflowPatternName,
        reason: String = overflowDenialReason
    ) -> RuleMatch {
        let ruleID = RuleID(pack: .coreSecrets, pattern: pattern)
        return RuleMatch(
            ruleID: ruleID,
            severity: .high,
            reason: reason,
            regex: nil,
            matchedText: nil,
            searchText: searchText
        )
    }

    private static func resolved(
        _ candidate: String,
        resolution: SecretPathResolution?
    ) -> String? {
        guard let resolution else { return nil }
        guard let target = resolution.resolve(candidate), !target.isEmpty else {
            return nil
        }
        // Identity expansion carries no new information.
        return target == candidate ? nil : target
    }

    private static func isExempt(
        _ path: String,
        _ rule: SecretPathRule,
        exempts: SecretPathExemption?
    ) -> Bool {
        exempts?(path, rule) ?? false
    }

    private static func hit(
        _ path: String,
        rule: SecretPathRule,
        searchText: String
    ) -> RuleMatch {
        RuleMatch(
            ruleID: RuleID(pack: .coreSecrets, pattern: rule.pattern),
            severity: .high,
            reason: rule.reason,
            regex: nil,
            matchedText: path,
            searchText: searchText
        )
    }

    private static func candidates(in haystack: String, includeMetadata: Bool) -> OperandScan {
        // C1: lex via the shared pipeline, then route on the head word. The
        // args array is built manually (not via Argv(tokens:)) so newline
        // lexemes survive: they are load-bearing operands below, exactly as
        // when the legacy tokenizeCommand stream carried them. A leading "\n"
        // routes to `.other` (basename can never equal a head name), and
        // interior "\n" words count as grep positionals and find path operands.
        // Routing happens first so `.nonPath` and metadata-excluded inputs
        // return before the args array is materialized.
        let tokens = ShellPipeline.tokenize(haystack)
        guard tokens.isEmpty == false else { return .empty }
        return argvCandidates(tokens.flatMap(splitGluedInputRedirect), includeMetadata: includeMetadata)
    }

    /// `cat<.env`, `base64 -w0<~/.ssh/id_rsa`: an unquoted input redirect
    /// glued to the word before it still opens its file. Split it off as a
    /// `<file` word so it reads exactly like the spaced `cat <.env`. Heredoc
    /// and process-substitution spellings (`<<`, `<(`) stay glued; splitting
    /// a literal `\<` over-claims a read, which only fails closed.
    private static func splitGluedInputRedirect(_ token: ShellPipeline.Token) -> [String] {
        let word = token.lexeme
        guard token.wasQuoted == false,
            let index = word.firstIndex(of: "<"),
            word[..<index].contains(where: { $0.isNumber == false })
        else {
            return [word]
        }
        return [String(word[..<index]), String(word[index...])]
    }

    /// Candidates of one argv, routed on its head word. `find -exec` routes
    /// its inner command through here too.
    fileprivate static func argvCandidates(_ argv: [String], includeMetadata: Bool) -> OperandScan {
        guard let head = argv.first else { return .empty }
        // `$(<.env)` and `<.env cat`: an input redirect in head position reads
        // its file whatever command follows.
        if head.hasPrefix("<") {
            return otherCandidates(argv)
        }
        let name = basename(head)
        let kind = headKind(name)
        // Deferred so only the consuming arm pays for materialization.
        func args() -> [String] { Array(argv.dropFirst()) }
        switch kind {
        case .nonPath:
            return .empty
        case .grep:
            return grepCandidates(args(), head: name.lowercased())
        case .find:
            return findCandidates(args(), includeMetadata: includeMetadata)
        case .metadata:
            guard includeMetadata else { return .empty }
            return otherCandidates(args())
        case .man:
            return manCandidates(args())
        case .other:
            return otherCandidates(args())
        }
    }

    /// Full per-segment scan: the candidates retained up to `candidateCap`
    /// (perf bound) plus whether any candidate operand was dropped because
    /// of that bound. Dropped operands are exactly what a padded
    /// `cat 1 … 64 ~/.ssh/id_rsa` relies on, so callers must treat overflow
    /// as denial, not as a skip.
    fileprivate struct OperandScan: Sendable {
        var candidates: [String]
        var overflowed: Bool
        /// Per candidate: whether the shell expands it as a word, so a glob
        /// in it opens what it matches. Option values are never expanded.
        var expands: [Bool] = []
        /// Per candidate: how a glob in it selects names. Shell by default;
        /// a `find` name or path pattern has no dotfile rule.
        var matching: [SecretPathGlob.Matching] = []
        /// Set when the operands cannot be modelled exactly (a regex predicate
        /// next to `-exec`, a `man` pager command): the scan denies.
        var unmodelled = false

        static let empty = OperandScan(candidates: [], overflowed: false)

        /// Adds one candidate, or records the overflow the caller fails closed on.
        mutating func add(_ value: String, expands: Bool, matching: SecretPathGlob.Matching = .shell) {
            guard value.isEmpty == false else { return }
            guard candidates.count < SecretPathGuard.candidateCap else {
                overflowed = true
                return
            }
            candidates.append(value)
            self.expands.append(expands)
            self.matching.append(matching)
        }
    }
}

private enum HeadKind {
    case nonPath
    case grep
    case find
    case metadata
    case man
    case other
}

private func headKind(_ argv0: String) -> HeadKind {
    switch argv0.lowercased() {
    case "echo", "printf":
        return .nonPath
    // Search tools and pattern-first data readers: the first positional is
    // the pattern or program, the rest are files.
    case "grep", "rg", "egrep", "fgrep", "ripgrep", "ag", "ack", "jq", "awk", "gawk", "mawk", "nawk":
        return .grep
    case "find":
        return .find
    case "ls", "test", "stat":
        return .metadata
    case "man":
        return .man
    default:
        return .other
    }
}

private enum OperandFlag {
    case regexp(attached: String?)
    case file(attached: String?)
    /// A file-selecting glob (`rg -g .env`, `grep --include .env`): its value
    /// names files the search reads, and the pattern is still positional.
    case glob(attached: String?, fold: Bool = false)
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
        case "glob", "include":
            return .glob(attached: attached)
        case "iglob":
            return .glob(attached: attached, fold: true)
        default:
            if let attached {
                // `--exclude=!x` negates like a negated glob: nothing is read.
                if name == "exclude", attached.hasPrefix("!") { return .ignore }
                return .equalsValue(attached)
            }
            return .ignore
        }
    case .shorts(let letters, _):
        // Single pass: legacy required all-ASCII-letters, with `f` winning
        // over `e` when both cluster together.
        var sawFile = false
        var sawRegexp = false
        var sawGlob = false
        // getopt reads the rest of a cluster after a value-taking letter as
        // its value: `-g.env`, `-f.env`. A run of plain letters keeps the
        // per-letter reading below.
        if letters.count > 1, let first = letters.first, first == "g" || first == "f",
            letters.dropFirst().contains(where: { $0.isASCII == false || $0.isLetter == false })
        {
            let attached = String(letters.dropFirst())
            return first == "g" ? .glob(attached: attached) : .file(attached: attached)
        }
        for letter in letters {
            guard letter.isASCII, letter.isLetter else {
                return .ignore
            }
            if letter == "f" { sawFile = true }
            if letter == "e" { sawRegexp = true }
            if letter == "g" { sawGlob = true }
        }
        if sawFile {
            return .file(attached: nil)
        }
        if sawRegexp {
            return .regexp(attached: nil)
        }
        if sawGlob {
            return .glob(attached: nil)
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
            // `-T.env`, `-d@.env`: a short option's attached value. A plain
            // flag cluster (`-la`) yields letters no catalog rule names.
            let letter = decoded.dropFirst().first
            guard decoded.hasPrefix("--") == false, decoded.count > 2,
                let letter, letter.isASCII, letter.isLetter
            else { return nil }
            return String(decoded.dropFirst(2))
        }
        return String(decoded[decoded.index(after: eq)...])
    }
    if let eq = decoded.firstIndex(of: "="), eq > decoded.startIndex {
        return String(decoded[decoded.index(after: eq)...])
    }
    return decoded
}

/// Options that take the next word as their value, per grep-family head.
/// The value is neither the pattern nor a file: `grep -C 2 "id_rsa" docs`
/// searches `docs` for `id_rsa`. `two` options take two words; `fileTwo`
/// options read a file named by their second word (`jq --rawfile v .env`).
private struct ValueOptions {
    var one: Set<String> = []
    var two: Set<String> = []
    var fileTwo: Set<String> = []
}

private func valueOptions(for head: String) -> ValueOptions {
    switch head {
    case "grep", "egrep", "fgrep":
        return ValueOptions(one: [
            "-A", "-B", "-C", "-m", "-d", "-D", "--context", "--after-context", "--before-context",
            "--max-count", "--exclude", "--exclude-dir", "--exclude-from", "--binary-files", "--label",
            "--devices", "--directories", "--group-separator",
        ])
    case "rg", "ripgrep":
        return ValueOptions(one: [
            "-A", "-B", "-C", "-m", "-t", "-T", "-M", "-j", "-E", "-d", "--type", "--type-not", "--type-add",
            "--type-clear", "--context", "--after-context", "--before-context", "--max-count", "--max-columns",
            "--max-depth", "--max-filesize", "--threads", "--sort", "--sortr", "--encoding", "--pre", "--pre-glob",
            "--colors", "--color", "--engine", "--replace", "--context-separator", "--field-match-separator",
            "--path-separator", "--ignore-file", "--dfa-size-limit", "--regex-size-limit",
        ])
    case "ag":
        return ValueOptions(one: [
            "-A", "-B", "-C", "-m", "-G", "-g", "--after", "--before", "--context", "--max-count", "--depth",
            "--ignore", "--ignore-dir", "--file-search-regex", "--pager", "--path-to-ignore",
        ])
    case "ack":
        return ValueOptions(one: [
            "-A", "-B", "-C", "-m", "--after-context", "--before-context", "--context", "--max-count", "--type",
            "--ignore-dir", "--ignore-file", "--output", "--pager",
        ])
    case "jq":
        return ValueOptions(
            one: ["--indent"], two: ["--arg", "--argjson"], fileTwo: ["--slurpfile", "--rawfile"])
    case "awk", "gawk", "mawk", "nawk":
        return ValueOptions(one: ["-v", "-F", "--assign", "--field-separator"])
    default:
        return ValueOptions()
    }
}

/// Grep-family candidate extraction over grammar-classified argv words.
///
/// The state machine mirrors the legacy loop: a pending `-e`/`-f` value
/// consumes the next word verbatim (even `"--"` or dash-led words), `--`
/// flips to positional mode, `-e`/`-f`/`--files` mark the pattern as given,
/// and otherwise the first positional is the pattern. Newline words classify
/// as `.positional` and count as positionals, as before. A head's
/// value-taking options (`valueOptions`) skip their value.
private func grepCandidates(_ words: [String], head: String) -> SecretPathGuard.OperandScan {
    var scan = SecretPathGuard.OperandScan(candidates: [], overflowed: false)
    let options = valueOptions(for: head)
    var skipFirstPositional = true
    var expectRegexp = false
    var expectFile = false
    var expectGlob = false
    var globFolds = false
    var afterDoubleDash = false
    var skipValues = 0
    var fileAfterSkip = false

    for word in words {
        if skipValues > 0 {
            skipValues -= 1
            if skipValues == 0, fileAfterSkip {
                fileAfterSkip = false
                expectFile = true
            }
            continue
        }
        if expectRegexp {
            expectRegexp = false
            continue
        }
        if expectFile {
            expectFile = false
            scan.add(word, expands: true)
            continue
        }
        if expectGlob {
            expectGlob = false
            // `!` negates a glob: an exclusion names files the search skips.
            // A search glob matches names with no dotfile rule (`-g '*env'`
            // reads `.env`).
            if word.hasPrefix("!") == false {
                scan.add(word, expands: true, matching: globFolds ? .findNameFolded : .findName)
            }
            continue
        }
        if afterDoubleDash {
            if skipFirstPositional {
                skipFirstPositional = false
                continue
            }
            scan.add(word, expands: true)
            continue
        }
        if options.one.contains(word) {
            skipValues = 1
            continue
        }
        if options.two.contains(word) {
            skipValues = 2
            continue
        }
        if options.fileTwo.contains(word) {
            skipValues = 1
            fileAfterSkip = true
            continue
        }
        // Classified lazily so the token work stops at the loop boundary
        // once every remaining word is a non-candidate.
        let token = FlagToken.classify(word)
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
                    scan.add(attached, expands: true)
                } else {
                    expectFile = true
                }
            case .files:
                skipFirstPositional = false
            case .glob(let attached, let fold):
                if let attached {
                    if attached.hasPrefix("!") == false {
                        scan.add(attached, expands: true, matching: fold ? .findNameFolded : .findName)
                    }
                } else {
                    expectGlob = true
                    globFolds = fold
                }
            case .equalsValue(let value):
                scan.add(value, expands: false)
            case .ignore:
                break
            }
            continue
        }
        if skipFirstPositional {
            skipFirstPositional = false
            continue
        }
        scan.add(word, expands: true)
    }
    return scan
}

/// Find candidate extraction: path operands before the first predicate word.
///
/// A word starts the predicate section exactly when the legacy test held:
/// every dash-led word (all non-`.positional` grammar cases) plus the bare
/// `(`, `!`, and `;` operands. The `-name`/`-iname`/`-path` literals skip
/// their value, since patterns are not paths, until an `-exec` command reads
/// what they select. The `-exec` command itself scans like any command.
private func findCandidates(_ words: [String], includeMetadata: Bool) -> SecretPathGuard.OperandScan {
    var scan = SecretPathGuard.OperandScan(candidates: [], overflowed: false)
    var beforePredicate = true
    var skipValue = false
    var nameValue = false
    var exec: [String]?
    var execs = false
    var names: [(pattern: String, matching: SecretPathGlob.Matching)] = []
    var pendingMatching = SecretPathGlob.Matching.findName
    var sawRegex = false
    // Global options (`-L`, `-H`, `-D debug`, `-f path`) may precede the
    // paths; they are not the start of the predicates.
    var leadingOptions = true
    var pathValue = false

    func runExec(_ argv: [String]) {
        let inner = SecretPathGuard.argvCandidates(argv.filter { $0 != "{}" }, includeMetadata: includeMetadata)
        if inner.overflowed { scan.overflowed = true }
        if inner.unmodelled { scan.unmodelled = true }
        for (index, candidate) in inner.candidates.enumerated() {
            scan.add(
                candidate,
                expands: index < inner.expands.count ? inner.expands[index] : true,
                matching: index < inner.matching.count ? inner.matching[index] : .shell)
        }
    }

    for word in words {
        // `-exec cat {} +` runs a command on what find selected, up to `;` or `+`.
        if let current = exec {
            if word == ";" || word == "+" || word == "\\;" {
                runExec(current)
                exec = nil
            } else {
                exec = current + [word]
            }
            continue
        }
        // Checked before a pending value: the matching view masks a quoted
        // `-name` value away, leaving `-exec` in its place.
        if word == "-exec" || word == "-execdir" || word == "-ok" || word == "-okdir" {
            beforePredicate = false
            skipValue = false
            nameValue = false
            exec = []
            execs = true
            continue
        }
        if pathValue {
            pathValue = false
            if let candidate = operandCandidate(word) { scan.add(candidate, expands: candidate == word) }
            continue
        }
        if skipValue {
            skipValue = false
            if nameValue { names.append((word, pendingMatching)) }
            nameValue = false
            continue
        }
        // Classified lazily so the state machine keeps walking predicate
        // starts and value skips even after the cap: those call sites do not
        // add candidates and must not mask a real dropped operand.
        if leadingOptions, beforePredicate, word.hasPrefix("-"), word.hasPrefix("--") == false {
            if word == "-D" {
                skipValue = true
                continue
            }
            if word == "-f" {
                pathValue = true
                continue
            }
            if ["-H", "-L", "-P", "-E", "-s", "-x", "-d", "-X"].contains(word)
                || (word.hasPrefix("-O") && word.dropFirst(2).allSatisfy(\.isNumber))
            {
                continue
            }
        }
        switch FlagToken.classify(word) {
        case .positional("("), .positional("!"), .positional(";"):
            beforePredicate = false
        case .positional(let operand):
            leadingOptions = false
            if beforePredicate, let candidate = operandCandidate(operand) {
                scan.add(candidate, expands: candidate == operand)
            }
        case .terminator, .loneDash, .long, .shorts, .shortEquals, .dangling:
            beforePredicate = false
            // Match the raw word: exactly the `-name`/`-iname`/`-path`
            // literals take a value, and this skips the String(letters)
            // rebuild `singleDashWord` performs per dash-led word.
            switch word {
            case "-name", "-path", "-wholename":
                skipValue = true
                nameValue = true
                pendingMatching = .findName
            case "-iname", "-ipath", "-iwholename":
                skipValue = true
                nameValue = true
                pendingMatching = .findNameFolded
            case "-regex", "-iregex":
                // A regex cannot be matched against the catalog here.
                skipValue = true
                sawRegex = true
            default:
                break
            }
        }
    }
    // An unterminated `-exec` is still a command find would refuse; scan it anyway.
    if let current = exec, current.isEmpty == false { runExec(current) }
    if execs {
        for name in names { scan.add(name.pattern, expands: true, matching: name.matching) }
        // What a regex selects cannot be modelled, so an `-exec` reading it fails closed.
        if sawRegex { scan.unmodelled = true }
    }
    return scan
}

/// `man` reads the file named by `-l`, or by an operand holding a `/`; the
/// operands scan as for any command. `-P`/`--pager` and `-H`/`--html` run a
/// command: a plain command name reads nothing, anything else (a quoted
/// `cat .env`, whose spaces the matching view has already flattened) cannot
/// be analysed and fails closed.
private func manCandidates(_ words: [String]) -> SecretPathGuard.OperandScan {
    var scan = otherCandidates(words)
    // Without `-l`, an operand is a page name unless it holds a `/`.
    // An attached pager (`--pager='cat .env'`) arrives with its quotes dropped,
    // so its arguments look like operands: keep every operand then.
    let readsFiles = words.contains { word in
        word == "--local-file" || word.hasPrefix("--pager=") || word.hasPrefix("--html=")
            || (word.hasPrefix("-") && word.hasPrefix("--") == false && word.contains(where: { "lPH".contains($0) }))
    }
    if readsFiles == false {
        let kept = zip(scan.candidates, zip(scan.expands, scan.matching)).filter { $0.0.contains("/") }
        scan.candidates = kept.map(\.0)
        scan.expands = kept.map(\.1.0)
        scan.matching = kept.map(\.1.1)
    }
    func isPlainCommandName(_ value: String) -> Bool { SecretPathGuard.isPlainCommandName(value) }
    var commandPending = false
    for word in words {
        if commandPending {
            commandPending = false
            if isPlainCommandName(word) == false { scan.unmodelled = true }
            continue
        }
        if word == "--" { break }
        if word == "-P" || word == "--pager" || word == "-H" || word == "--html" {
            commandPending = true
        } else if word.hasPrefix("--") {
            for option in ["--pager=", "--html="] where word.hasPrefix(option) {
                if isPlainCommandName(String(word.dropFirst(option.count))) == false { scan.unmodelled = true }
            }
        } else if word.hasPrefix("-"), word.dropFirst().contains(where: { $0 == "P" || $0 == "H" }) {
            // `-Pcat`: an attached value; a letter run (`-aP`) takes its value
            // from the next word, which this reading does not follow.
            let value = word.dropFirst(2)
            if (word.hasPrefix("-P") || word.hasPrefix("-H")), isPlainCommandName(String(value)) {
                continue
            }
            scan.unmodelled = true
        }
    }
    return scan
}

/// Default candidate extraction: every non-flag operand word verbatim. A
/// value taken from `--opt=value` or `-Xvalue` is not shell-expanded.
private func otherCandidates(_ words: [String]) -> SecretPathGuard.OperandScan {
    var scan = SecretPathGuard.OperandScan(candidates: [], overflowed: false)
    for word in words {
        guard let candidate = operandCandidate(word), !candidate.isEmpty else {
            continue
        }
        scan.add(candidate, expands: candidate == word)
    }
    return scan
}
