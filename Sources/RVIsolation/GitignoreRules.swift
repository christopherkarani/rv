/// `.gitignore` selection for workspace file transfer (`rv workspace upload`
/// and `download`). Pure: the caller reads each `.gitignore` file and says
/// which directory it came from.
///
/// Supported: comments, blank lines, `\` escapes, trailing-space trimming,
/// `!` negation, a trailing `/` (directories only), a leading or inner `/`
/// (anchored to the file's directory), `*`, `?`, `[...]` classes (`!`/`^`
/// negation, ranges) and `**` as a whole segment. The last matching rule
/// wins. Not read: `.git/info/exclude` and the global `core.excludesFile`.
/// Selection only narrows what is copied, so a rule it misreads can copy
/// less or more than git would, never reach a path outside the transfer.
struct GitignoreRules: Sendable, Equatable {
    private var rules: [Rule] = []
    /// Pattern bytes held by `rules`, for the caller's memory cap.
    private(set) var heldBytes = 0
    var count: Int { rules.count }

    /// Path segments longer than this, or patterns with more segments, are
    /// not matched (treated as "no match"): matching stays bounded.
    private static let maxSegments = 128

    struct Rule: Sendable, Equatable {
        let base: [String]
        let segments: [[Character]]
        let negated: Bool
        let directoryOnly: Bool
        /// No slash in the pattern: match the last path component at any depth.
        let nameOnly: Bool
        let byteCount: Int
    }

    /// The rules of one `.gitignore` in directory `base` (relative to the
    /// transfer root), after the rules already held.
    func adding(_ text: String, base: [String]) -> GitignoreRules {
        var copy = self
        copy.append(text, base: base)
        return copy
    }

    /// In place, so a tree walk can push a directory's rules and `truncate`
    /// them on the way out instead of copying the stack per level.
    mutating func append(_ text: String, base: [String]) {
        // Split on the scalar: Swift reads "\r\n" as one Character, so a
        // Character split would leave a CRLF file as one line (no rules).
        for line in text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            if let rule = Self.parse(String(Substring(line)), base: base) {
                rules.append(rule)
                heldBytes += rule.byteCount
            }
        }
    }

    mutating func truncate(to count: Int) {
        while rules.count > count { heldBytes -= rules.removeLast().byteCount }
    }

    /// Whether `path` (components relative to the transfer root) is ignored.
    /// A directory's contents are skipped by the caller once the directory
    /// is ignored, as git does.
    func isIgnored(_ path: [String], isDirectory: Bool) -> Bool {
        var ignored = false
        for rule in rules where rule.matches(path, isDirectory: isDirectory) {
            ignored = rule.negated == false
        }
        return ignored
    }

    private static func parse(_ raw: String, base: [String]) -> Rule? {
        var line = raw
        if line.hasSuffix("\r") { line.removeLast() }
        line = trimmingUnescapedTrailingSpaces(line)
        guard line.isEmpty == false, line.hasPrefix("#") == false else { return nil }
        var negated = false
        if line.hasPrefix("!") {
            negated = true
            line.removeFirst()
        }
        var directoryOnly = false
        while line.hasSuffix("/") && line.hasSuffix("\\/") == false {
            directoryOnly = true
            line.removeLast()
        }
        var anchored = false
        if line.hasPrefix("/") {
            anchored = true
            line.removeFirst()
        }
        guard line.isEmpty == false else { return nil }
        let parts = line.split(separator: "/", omittingEmptySubsequences: true).map { Array($0) }
        guard parts.isEmpty == false, parts.count <= maxSegments else { return nil }
        anchored = anchored || parts.count > 1
        return Rule(
            base: base, segments: parts, negated: negated, directoryOnly: directoryOnly,
            nameOnly: anchored == false, byteCount: line.utf8.count
        )
    }

    private static func trimmingUnescapedTrailingSpaces(_ line: String) -> String {
        var characters = Array(line)
        while characters.last == " " {
            let beforeSpace = characters.count - 2
            if beforeSpace >= 0, characters[beforeSpace] == "\\" {
                // `\ ` keeps the space; the escape itself is resolved by the matcher.
                break
            }
            characters.removeLast()
        }
        return String(characters)
    }
}

extension GitignoreRules.Rule {
    func matches(_ path: [String], isDirectory: Bool) -> Bool {
        if directoryOnly && isDirectory == false { return false }
        guard path.count > base.count, Array(path.prefix(base.count)) == base else { return false }
        let relative = path.dropFirst(base.count).map(Array.init)
        guard relative.count <= 128 else { return false }
        if nameOnly {
            guard let last = relative.last else { return false }
            return globMatch(segments[0], last)
        }
        return segmentsMatch(segments[...], relative[...])
    }

    /// `**` matches zero or more whole segments. Memoised on (pattern
    /// index, path index), so it is at most |pattern| x |path| steps.
    private func segmentsMatch(_ pattern: ArraySlice<[Character]>, _ path: ArraySlice<[Character]>) -> Bool {
        var memo: [Int: Bool] = [:]
        func match(_ p: Int, _ s: Int) -> Bool {
            let key = p * 1024 + s
            if let known = memo[key] { return known }
            let result: Bool
            if p == pattern.endIndex {
                result = s == path.endIndex
            } else if pattern[p] == ["*", "*"] {
                result = match(p + 1, s) || (s < path.endIndex && match(p, s + 1))
            } else {
                result = s < path.endIndex && globMatch(pattern[p], path[s]) && match(p + 1, s + 1)
            }
            memo[key] = result
            return result
        }
        return match(pattern.startIndex, path.startIndex)
    }
}

/// One segment: `*` (any run), `?` (one character), `[...]`, `\x`.
/// Iterative with a single backtrack point per `*`, so linear-ish.
private func globMatch(_ pattern: [Character], _ name: [Character]) -> Bool {
    var p = 0
    var n = 0
    var starP = -1
    var starN = 0
    while n < name.count {
        if p < pattern.count, pattern[p] == "*" {
            while p < pattern.count, pattern[p] == "*" { p += 1 }
            starP = p
            starN = n
            continue
        }
        if p < pattern.count, let width = singleMatch(pattern, at: p, name[n]) {
            p += width
            n += 1
            continue
        }
        guard starP >= 0 else { return false }
        starN += 1
        n = starN
        p = starP
    }
    while p < pattern.count, pattern[p] == "*" { p += 1 }
    return p == pattern.count
}

/// Width of the pattern token at `index` when it matches `character`, nil otherwise.
private func singleMatch(_ pattern: [Character], at index: Int, _ character: Character) -> Int? {
    switch pattern[index] {
    case "?":
        return 1
    case "\\":
        guard index + 1 < pattern.count else { return character == "\\" ? 1 : nil }
        return pattern[index + 1] == character ? 2 : nil
    case "[":
        guard let (matched, width) = bracketMatch(pattern, at: index, character) else {
            return character == "[" ? 1 : nil
        }
        return matched ? width : nil
    default:
        return pattern[index] == character ? 1 : nil
    }
}

/// nil when the class is unterminated (then `[` is literal).
private func bracketMatch(_ pattern: [Character], at start: Int, _ character: Character) -> (Bool, Int)? {
    var index = start + 1
    var negated = false
    if index < pattern.count, pattern[index] == "!" || pattern[index] == "^" {
        negated = true
        index += 1
    }
    var matched = false
    var first = true
    while index < pattern.count {
        if pattern[index] == "]", first == false {
            return (matched != negated, index - start + 1)
        }
        first = false
        var low = pattern[index]
        if low == "\\", index + 1 < pattern.count {
            index += 1
            low = pattern[index]
        }
        if index + 2 < pattern.count, pattern[index + 1] == "-", pattern[index + 2] != "]" {
            let high = pattern[index + 2]
            if low <= character && character <= high { matched = true }
            index += 3
        } else {
            if low == character { matched = true }
            index += 1
        }
    }
    return nil
}
