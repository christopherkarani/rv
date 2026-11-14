import Foundation

// MARK: - Brace, glob and dynamic spellings for the MCP host config guard

/// The work budget for resolving brace and glob spellings while judging one
/// command for the MCP host config guard. It lives in `HostTextReads`, so it
/// spans every text read for that command. Expanding a word and matching a
/// glob spend steps before doing the work they stand for; once the budget is
/// spent, or past `maxWordLength` or `maxExpansions`, a word with
/// metacharacters may be any words (fail closed) and no work is done on it.
struct SpellingBudget {
    static let maxSteps = 1_000_000
    /// A word longer than this with metacharacters may be any words.
    static let maxWordLength = 256
    /// A brace expansion of more words than this may be any words.
    static let maxExpansions = 64

    /// Steps spent so far; never above `maxSteps`.
    private(set) var steps = 0
    /// `spellsHostMCPTableWord`'s answer per word already judged.
    fileprivate var tableWordAnswers: [String: Bool] = [:]

    init() {}

    /// Spends `count` steps; false, and the budget spent, when they do not fit.
    mutating func spend(_ count: Int) -> Bool {
        guard count <= Self.maxSteps - steps else {
            steps = Self.maxSteps
            return false
        }
        steps += count
        return true
    }
}

/// What one argv word may become once the shell expands its braces and
/// globs, judged without the filesystem (a wildcard or class is assumed
/// satisfiable). Each word is expanded once (`of`); the shell splits a brace
/// expansion into several words, kept in order in `expansions`.
struct WordSpelling: Sendable {
    let word: String
    /// The words brace expansion yields, in order, empty ones dropped (the
    /// shell removes them); each may still be a glob. Nil: may be any words.
    let expansions: [String]?
    /// The word holds brace or glob metacharacters the shell may expand.
    let expands: Bool

    /// The word's spelling, spending `budget`. A word with no metacharacters
    /// is only itself. So is a word with a blank: the tokenizer joined a
    /// quoted or escaped run there, and every expansion keeps the blank, so
    /// none can be a word the guard matches (`claude -p "f() { ... } ../x"`).
    static func of(_ word: String, budget: inout SpellingBudget) -> WordSpelling {
        guard hasExpansionMetacharacters(word), word.contains(where: \.isWhitespace) == false else {
            return WordSpelling(word: word, expansions: [word], expands: false)
        }
        guard word.count <= SpellingBudget.maxWordLength else {
            return WordSpelling(word: word, expansions: nil, expands: true)
        }
        return WordSpelling(word: word, expansions: boundedBraceExpansions(word, budget: &budget), expands: true)
    }

    /// `word` as only itself, whatever it holds (a literal read).
    static func asWritten(_ word: String) -> WordSpelling {
        WordSpelling(word: word, expansions: [word], expands: false)
    }

    /// Whether some word the expansion yields may be `literal`.
    func mayBe(_ literal: String, budget: inout SpellingBudget) -> Bool {
        guard expands else { return word == literal }
        guard let expansions else { return true }
        for expansion in expansions where patternMayBe(expansion, literal, budget: &budget) { return true }
        return false
    }

    /// Whether some word the expansion yields may run the program `literal`
    /// (its `commandName`: `src/m?p` may run `mcp`).
    func nameMayBe(_ literal: String, budget: inout SpellingBudget) -> Bool {
        guard expands else { return commandName(word) == literal }
        guard let expansions else { return true }
        for expansion in expansions where patternMayBe(commandName(expansion), literal, budget: &budget) {
            return true
        }
        return false
    }

    /// The shell expands the word to no word at all (`{,}`).
    var vanishes: Bool { expansions?.isEmpty == true }
}

/// Whether `word` holds brace (`{a,b}`, `{1..3}`) or glob (`*`, `?`, `[…]`)
/// metacharacters the shell may expand to other words. The tokenizer strips
/// quotes and keeps their text, so a quoted metacharacter arrives looking like
/// an unquoted one and counts too (fail closed).
func hasExpansionMetacharacters(_ word: String) -> Bool {
    if hasGlobCharacters(word) { return true }
    return word.contains("{") && (word.contains(",") || word.contains(".."))
}

private func hasGlobCharacters(_ word: String) -> Bool {
    word.contains("*") || word.contains("?") || word.contains("[")
}

/// Whether one expanded word may be `literal`: a glob match, or equality. An
/// expansion still holding a value rv cannot read (`m$x`) is judged as
/// written, like any dynamic word (`wordIsDynamic`).
func patternMayBe(_ word: String, _ literal: String, budget: inout SpellingBudget) -> Bool {
    guard hasGlobCharacters(word), word.contains("$") == false, word.contains("`") == false else {
        return word == literal
    }
    return globCanMatch(word, literal, budget: &budget)
}

/// Whether `word` holds a value rv cannot resolve to a fixed string: a
/// parameter (`$x`, `${x:-y}`), a command substitution (`$(…)`, backticks) or
/// a process substitution. ANSI-C quoting (`$'…'`), which rv decodes, is not
/// dynamic.
func wordIsDynamic(_ word: String) -> Bool {
    collapsingSubstitutions(word.ansiCDecodedIfMarked).contains("$")
}

/// Bash brace expansion of `word`: comma groups and `{x..y[..step]}` ranges of
/// integers or single characters, the leftmost outer group first, the empty
/// words it yields dropped (the shell removes them). A `..` group that is no
/// such range (`{...}`, `{a..zz}`) stays text, as in bash. Each round finds
/// its group in one pass and spends the word's length. Nil (may be any
/// words) past `SpellingBudget.maxExpansions` words or once the budget is
/// spent. Unlike `braceExpanded`, which other guards share, it never rescans
/// a word per brace.
func boundedBraceExpansions(_ word: String, budget: inout SpellingBudget) -> [String]? {
    let representable = hasGlobCharacters(word) == false
    var results = [word]
    var index = 0
    while index < results.count {
        let chars = Array(results[index])
        guard budget.spend(chars.count + 1) else { return nil }
        guard let group = firstBraceGroup(chars) else {
            index += 1
            continue
        }
        guard let alternatives = group.alternatives(of: chars, representable: representable, budget: &budget)
        else { return nil }
        let prefix = String(chars[..<group.open])
        let suffix = String(chars[(group.close + 1)...])
        results.replaceSubrange(index...index, with: alternatives.map { prefix + $0 + suffix })
        guard results.count <= SpellingBudget.maxExpansions else { return nil }
    }
    return results.filter { $0.isEmpty == false }
}

private struct BraceGroup {
    let open: Int
    let close: Int
    /// Commas at the group's own level; none for a range.
    let commas: [Int]
    /// The range a group with no comma stands for.
    let range: BraceRange?

    func alternatives(of chars: [Character], representable: Bool, budget: inout SpellingBudget) -> [String]? {
        if let range { return range.words(representable: representable, budget: &budget) }
        var out: [String] = []
        var start = open + 1
        for comma in commas + [close] {
            out.append(String(chars[start..<comma]))
            start = comma + 1
        }
        return out
    }
}

/// The leftmost brace pair the shell expands: one with a comma at its own
/// level, or one holding a range (`BraceRange`) and no other brace. One pass
/// with a stack; a range body is parsed once, at its closing brace.
private func firstBraceGroup(_ chars: [Character]) -> BraceGroup? {
    var stack: [(open: Int, commas: [Int], nested: Bool, dots: Bool)] = []
    var best: BraceGroup?
    for (index, char) in chars.enumerated() {
        switch char {
        case "{":
            if stack.isEmpty == false { stack[stack.count - 1].nested = true }
            stack.append((index, [], false, false))
        case "," where stack.isEmpty == false:
            stack[stack.count - 1].commas.append(index)
        case "." where stack.isEmpty == false && index > 0 && chars[index - 1] == ".":
            stack[stack.count - 1].dots = true
        case "}":
            guard let top = stack.popLast(), best.map({ top.open < $0.open }) ?? true else { continue }
            if top.commas.isEmpty == false {
                best = BraceGroup(open: top.open, close: index, commas: top.commas, range: nil)
            } else if top.nested == false, top.dots, let range = BraceRange(String(chars[(top.open + 1)..<index])) {
                best = BraceGroup(open: top.open, close: index, commas: [], range: range)
            }
        default:
            continue
        }
    }
    return best
}

/// A `x..y` or `x..y..step` body bash enumerates: two integers, or two single
/// characters. A zero step counts as one, as in bash.
private enum BraceRange {
    case integers(from: Int, to: Int, step: Int)
    case characters(from: Int, to: Int, step: Int)

    init?(_ body: String) {
        let parts = body.components(separatedBy: "..")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var step = 1
        if parts.count == 3 {
            guard let given = Int(parts[2]) else { return nil }
            step = given == 0 ? 1 : Int(clamping: given.magnitude)
        }
        if let from = Int(parts[0]), let to = Int(parts[1]) {
            self = .integers(from: from, to: to, step: step)
            return
        }
        guard parts[0].unicodeScalars.count == 1, parts[1].unicodeScalars.count == 1,
              let from = parts[0].unicodeScalars.first, let to = parts[1].unicodeScalars.first
        else { return nil }
        self = .characters(from: Int(from.value), to: Int(to.value), step: step)
    }

    /// The words, in bash's order; nil (may be any words) for a character
    /// range past `SpellingBudget.maxExpansions`, or once the budget is
    /// spent. An integer range past it, in a word with no glob character
    /// (`representable`), yields one representative: the words differ only
    /// in the digits there, and no word the guard matches holds a digit
    /// (pinned by a test), so all of them judge alike. Zero padding
    /// (`{01..10}`) is not reproduced for the same reason.
    func words(representable: Bool, budget: inout SpellingBudget) -> [String]? {
        switch self {
        case let .integers(from, to, step):
            let (span, overflow) = to.subtractingReportingOverflow(from)
            // The words after the first; no overflow for any two `Int`s.
            let gaps = overflow || span == Int.min ? Int.max : abs(span) / step
            guard gaps < SpellingBudget.maxExpansions else { return representable ? [String(from)] : nil }
            guard budget.spend(gaps + 1) else { return nil }
            // Each value lies between `from` and `to`, so none overflows.
            return (0...gaps).map { offset in String(to >= from ? from + offset * step : from - offset * step) }
        case let .characters(from, to, step):
            let gaps = abs(to - from) / step
            guard gaps < SpellingBudget.maxExpansions, budget.spend(gaps + 1) else { return nil }
            return (0...gaps).compactMap { offset in
                Unicode.Scalar(UInt32(to >= from ? from + offset * step : from - offset * step))
                    .map { String(Character($0)) }
            }
        }
    }
}

/// Whether the shell glob `pattern` can match `text`: `*`, `?` and `[…]` (with
/// `!`/`^` negation and ranges). A bracket expression holding a POSIX class,
/// equivalence class or collating symbol (`[[:alpha:]]`, `[[=a=]]`,
/// `[[.a.]]`) may match any one character (fail closed). No filesystem: a
/// wildcard or class is assumed satisfiable. Memoised; each state visited
/// and each class scanned spends steps first, and once the budget is spent
/// the pattern may match.
func globCanMatch(_ pattern: String, _ text: String, budget: inout SpellingBudget) -> Bool {
    let p = Array(pattern)
    let t = Array(text)
    let width = t.count + 1
    var failed: Set<Int> = []
    func classEnd(_ open: Int) -> (close: Int, anyCharacter: Bool)? {
        var k = open + 1
        if k < p.count, p[k] == "!" || p[k] == "^" { k += 1 }
        if k < p.count, p[k] == "]" { k += 1 }
        var anyCharacter = false
        while k < p.count, p[k] != "]" {
            if p[k] == "[", k + 1 < p.count, ":=.".contains(p[k + 1]) {
                anyCharacter = true
                let kind = p[k + 1]
                var j = k + 2
                while j + 1 < p.count, (p[j] == kind && p[j + 1] == "]") == false { j += 1 }
                // An unterminated `[:` is plain text inside the class.
                if j + 1 < p.count {
                    k = j + 2
                    continue
                }
            }
            k += 1
        }
        return k < p.count ? (k, anyCharacter) : nil
    }
    func classMatches(_ body: ArraySlice<Character>, _ ch: Character) -> Bool {
        var items = Array(body)
        var negate = false
        if let first = items.first, first == "!" || first == "^" {
            negate = true
            items.removeFirst()
        }
        var matched = false
        var i = 0
        while i < items.count {
            if i + 2 < items.count, items[i + 1] == "-" {
                if items[i] <= ch, ch <= items[i + 2] { matched = true }
                i += 3
            } else {
                if items[i] == ch { matched = true }
                i += 1
            }
        }
        return matched != negate
    }
    func match(_ startP: Int, _ startT: Int) -> Bool {
        var pi = startP
        var ti = startT
        while pi < p.count {
            guard budget.spend(1) else { return true }
            let key = pi * width + ti
            if failed.contains(key) { return false }
            // A closed `[…]` class; an unclosed `[` is a literal (`default`).
            if p[pi] == "[" {
                guard budget.spend(p.count - pi) else { return true }
                if let end = classEnd(pi) {
                    guard ti < t.count, end.anyCharacter || classMatches(p[(pi + 1)..<end.close], t[ti]) else {
                        failed.insert(key)
                        return false
                    }
                    pi = end.close + 1
                    ti += 1
                    continue
                }
            }
            switch p[pi] {
            case "*":
                var np = pi
                while np < p.count, p[np] == "*" { np += 1 }
                if np == p.count { return true }
                var k = ti
                while k <= t.count {
                    if match(np, k) { return true }
                    k += 1
                }
                failed.insert(key)
                return false
            case "?":
                if ti >= t.count { failed.insert(key); return false }
                pi += 1
                ti += 1
            default:
                if ti >= t.count || p[pi] != t[ti] { failed.insert(key); return false }
                pi += 1
                ti += 1
            }
        }
        return ti == t.count
    }
    return match(0, 0)
}

/// Every word the host CLI checks match (`hostMCPTableWords`), once.
private let spellingTableWords: [String] = Array(Set(hostMCPTableWords())).sorted()

/// Whether some word of `text` holding brace or glob metacharacters may, once
/// expanded, be a word the host CLI checks match, or run a program of that
/// name (`m?p`, `m[c]p`, `mc{o..p}`, `src/clau*`): such text may hold no
/// stem (`holdsHostMCPStem`). A word is also judged in the pieces between its
/// `$` and backtick characters (`m?p${IFS}install`). Spends `budget`; each
/// distinct word is judged once.
func spellsHostMCPTableWord(_ text: String, budget: inout SpellingBudget) -> Bool {
    guard text.contains(where: { "*?[{".contains($0) }) else { return false }
    let words = text.split(whereSeparator: { $0.isWhitespace || ";|&()<>".contains($0) })
    for raw in words {
        var candidates = [String(raw)]
        if raw.contains("$") || raw.contains("`") {
            candidates += raw.split(whereSeparator: { "$`".contains($0) }).map(String.init)
        }
        for word in candidates where hasExpansionMetacharacters(word) {
            if let known = budget.tableWordAnswers[word] {
                if known { return true }
                continue
            }
            let spelling = WordSpelling.of(word, budget: &budget)
            var spells = false
            for literal in spellingTableWords
            where spelling.mayBe(literal, budget: &budget) || spelling.nameMayBe(literal, budget: &budget) {
                spells = true
                break
            }
            budget.tableWordAnswers[word] = spells
            if spells { return true }
        }
    }
    return false
}
