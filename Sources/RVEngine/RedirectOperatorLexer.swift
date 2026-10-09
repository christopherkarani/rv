/// Classification of a standalone redirect-operator word. Output operators
/// name (or may name) a file destination; input operators never do:
/// input-dups (`<&`) never name a destination.
enum RedirectOperatorClass: Sendable, Equatable {
    case output
    case input
}

/// The single redirect-operator lexer (R1). Owns the one operator table;
/// the create/read predicate, the mid-word splitter, and the writer
/// stripper all read through this seam, so operator-coverage fixes land
/// once. Pure string functions, no I/O.
enum RedirectOperatorLexer {
    // MARK: - Classify

    /// Classify a standalone word: output-op, input-op, or nil. Optional
    /// leading fd digits (`2>`, `10>>`) are ASCII-gated; `&`-led spellings
    /// never take fd digits (`2&>` is not an operator). `isRedirectOperator`
    /// keeps its `<&` exclusion by accepting only `.output` (caller policy).
    static func classify(_ word: String) -> RedirectOperatorClass? {
        var rest = word[...]
        while let first = rest.first, first.isASCII, first.isNumber {
            rest = rest.dropFirst()
        }
        let sawDigits = rest.startIndex != word.startIndex
        guard let kind = kindBySpelling[String(rest)] else { return nil }
        if sawDigits, rest.first == "&" { return nil }
        return kind.isOutput ? .output : .input
    }

    /// True for exactly `2>&1`, `1>&2`, `>&1`, `>&2`: an optional single
    /// source fd in 1...2, the output-dup spelling, then a single target fd
    /// in 1...2, excluding self-dups (`1>&1`, `2>&2`).
    static func isFdDup(_ word: String) -> Bool {
        var rest = word[...]
        var source: Character?
        if let first = rest.first, first == "1" || first == "2" {
            source = first
            rest = rest.dropFirst()
        }
        guard let entry = matchOperator(rest), entry.kind == .outputDup else {
            return false
        }
        rest = rest.dropFirst(entry.spelling.count)
        guard rest.count == 1,
            let target = rest.first,
            target == "1" || target == "2"
        else {
            return false
        }
        return source != target
    }

    // MARK: - Split

    /// Split a mid-word token into alternating word/operator pieces, fd
    /// digits glued left, dup/close targets glued right.
    static func splitPieces(_ word: String) -> [String] {
        splitRedirectPieces(word)
    }

    private static func splitRedirectPieces(_ word: String) -> [String] {
        let chars = Array(word)
        var pieces: [String] = []
        var index = 0
        var wordStart = 0
        while index < chars.count {
            if chars[index] == "\\" {
                index += 2
                continue
            }
            if chars[index] == ">" || chars[index] == "<" {
                let runEnd = redirectRunEnd(chars, from: index)
                // A digit run immediately before the operator is its fd (`a2>b`
                // redirects fd 2, word `a`), maximal like the shell's own read.
                var fdStart = index
                while fdStart > wordStart, chars[fdStart - 1].isASCII, chars[fdStart - 1].isNumber {
                    fdStart -= 1
                }
                if wordStart < fdStart {
                    pieces.append(String(chars[wordStart..<fdStart]))
                }
                pieces.append(String(chars[fdStart..<runEnd]))
                index = runEnd
                wordStart = runEnd
                continue
            }
            index += 1
        }
        if wordStart < chars.count {
            pieces.append(String(chars[wordStart...]))
        }
        return pieces.isEmpty ? [word] : pieces
    }

    /// End index of the redirect operator run starting at `from`, longest
    /// table match, with dup/close targets glued on the right. `&`-led
    /// spellings never match here: the split triggers only on `>`/`<`, so
    /// `&>` splits after the `&` exactly as before.
    private static func redirectRunEnd(_ chars: [Character], from: Int) -> Int {
        if let entries = operatorsByLeader[chars[from]] {
            for entry in entries {
                guard matchChars(chars, from: from, spelling: entry.spelling) else { continue }
                let runEnd = from + entry.spelling.count
                if entry.kind.isDup == false {
                    return runEnd
                }
                // Dup/close targets glue only to end of token: `>&1` is a dup, but
                // `>&1b` duplicates to the FILE `1b`, so the `1b` must split off.
                var digitsEnd = runEnd
                while digitsEnd < chars.count, chars[digitsEnd].isASCII, chars[digitsEnd].isNumber {
                    digitsEnd += 1
                }
                if digitsEnd == chars.count {
                    return digitsEnd
                }
                if digitsEnd == runEnd, digitsEnd < chars.count, chars[digitsEnd] == "-",
                    digitsEnd + 1 == chars.count
                {
                    return digitsEnd + 1
                }
                return runEnd
            }
        }
        return from + 1
    }

    private static func matchChars(_ chars: [Character], from: Int, spelling: String) -> Bool {
        guard chars.count - from >= spelling.count else { return false }
        return zip(chars[from...], spelling).allSatisfy(==)
    }

    // MARK: - Attached target

    /// Attached target of an output redirect, or nil for dups/closes and
    /// non-leading operators.
    static func attachedTarget(_ word: String) -> String? {
        attachedRedirectTarget(word)
    }

    private static func attachedRedirectTarget(_ token: String) -> String? {
        var rest = token[...]
        while let first = rest.first, first.isASCII, first.isNumber {
            rest = rest.dropFirst()
        }
        let sawDigits = rest.startIndex != token.startIndex
        guard let entry = matchOperator(rest), entry.kind.isOutput else { return nil }
        // `&`-led spellings never take fd digits (`2&>f` names nothing).
        if sawDigits, rest.first == "&" { return nil }
        let target = rest.dropFirst(entry.spelling.count)
        // Bare operators name no attached target. They never reach this
        // reader (redirectTargets checks isRedirectOperator first), so the
        // old fallback-arm scraps for bare `>>` / `>|` / `&>>` were dead.
        guard target.isEmpty == false else { return nil }
        if entry.kind == .outputDup {
            // Only `>&file` names a destination: `-`/numeric/`&`-led rests
            // are dup/close. The numeric test is ASCII-gated after fd digits
            // but plain-Unicode otherwise — preserved exactly as found.
            if target == "-" { return nil }
            let numeric = sawDigits
                ? target.allSatisfy({ $0.isASCII && $0.isNumber })
                : target.allSatisfy({ $0.isNumber })
            if numeric { return nil }
            if target.hasPrefix("&") { return nil }
            return String(target)
        }
        if entry.kind == .outputAmp {
            // Unlike `>&`, `&>` has no numeric check: `&>2` names file `2`.
            if target.hasPrefix("&") { return nil }
            return String(target)
        }
        if entry.kind == .outputAppend, sawDigits, target.hasPrefix("&") {
            // Bare `>>&1` names file `&1`, but `2>>&1` reads nil: the fd
            // `>>` arm refused `&`-led rests while the bare arm did not.
            return nil
        }
        return String(target)
    }

    // MARK: - Writer-strip reading

    /// Writer-strip reading: words the stripper drops whole. True when the
    /// word starts with redirect syntax (leading operator with optional fd
    /// digits) or carries a dup spelling anywhere. Every old input separator
    /// (`<`, `<<`, `<<-`, `<<<`, `0<`, `1<`) already read true under the
    /// attached-word rule, and both old arms dropped exactly one word, so
    /// this one predicate reproduces the stripper exactly.
    static func isAttachedRedirectWord(_ word: String) -> Bool {
        if startsWithRedirectOperator(word) { return true }
        return containsDupOperator(word)
    }

    /// Leading operator with optional fd digits. The digit run is plain
    /// `.isNumber` (non-ASCII digits count), exactly like the writer
    /// stripper this replaces — unlike the ASCII-gated readers above.
    private static func startsWithRedirectOperator(_ word: String) -> Bool {
        var rest = word[...]
        var sawDigits = false
        while let first = rest.first, first.isNumber {
            rest = rest.dropFirst()
            sawDigits = true
        }
        guard matchOperator(rest) != nil else { return false }
        if sawDigits, rest.first == "&" { return false }
        return true
    }

    /// True when a dup spelling occurs at any position. A table scan, not a
    /// substring search: spellings come from the operator table.
    private static func containsDupOperator(_ word: String) -> Bool {
        var index = word.startIndex
        while index < word.endIndex {
            if let entry = matchOperator(word[index...]), entry.kind.isDup {
                return true
            }
            word.formIndex(after: &index)
        }
        return false
    }

    // MARK: - Operator table

    private enum OperatorKind: Sendable {
        case output // `>`, `>|`, `&>>`, `<>`: the rest is the target
        case outputAppend // `>>`: the rest is the target, except `&`-led rests after fd digits read nil
        case outputDup // `>&`: `-`/numeric/`&`-led rests are dup/close, else file
        case outputAmp // `&>`: `&`-led rests are dups; numeric rests ARE files
        case input // `<`, `<<`, `<<<`, `<<-`
        case inputDup // `<&`

        var isOutput: Bool {
            self == .output || self == .outputAppend || self == .outputDup || self == .outputAmp
        }

        var isDup: Bool {
            self == .outputDup || self == .inputDup
        }
    }

    private struct OperatorEntry: Sendable {
        var spelling: String
        var kind: OperatorKind
    }

    /// The single redirect-operator table: every spelling the engine
    /// recognizes, grouped by leader, longest spelling first within each
    /// leader so prefix matches resolve deterministically.
    private static let operatorsByLeader: [Character: [OperatorEntry]] = [
        ">": [
            OperatorEntry(spelling: ">>", kind: .outputAppend),
            OperatorEntry(spelling: ">|", kind: .output),
            OperatorEntry(spelling: ">&", kind: .outputDup),
            OperatorEntry(spelling: ">", kind: .output),
        ],
        "&": [
            OperatorEntry(spelling: "&>>", kind: .output),
            OperatorEntry(spelling: "&>", kind: .outputAmp),
        ],
        "<": [
            OperatorEntry(spelling: "<<<", kind: .input),
            OperatorEntry(spelling: "<<-", kind: .input),
            OperatorEntry(spelling: "<<", kind: .input),
            OperatorEntry(spelling: "<>", kind: .output),
            OperatorEntry(spelling: "<&", kind: .inputDup),
            OperatorEntry(spelling: "<", kind: .input),
        ],
    ]

    /// Exact-spelling index over the operator table (derived, not a copy).
    private static let kindBySpelling: [String: OperatorKind] = Dictionary(
        uniqueKeysWithValues: operatorsByLeader.values.flatMap { $0 }.map { ($0.spelling, $0.kind) }
    )

    /// Longest table match at the start of `text`, or nil.
    private static func matchOperator(_ text: Substring) -> OperatorEntry? {
        guard let leader = text.first, let entries = operatorsByLeader[leader] else { return nil }
        return entries.first(where: { text.hasPrefix($0.spelling) })
    }
}
