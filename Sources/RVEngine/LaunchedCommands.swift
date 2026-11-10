import Foundation
import RVDomain

/// Every simple command `raw` launches, as decoded argv words.
///
/// Segments come from `splitSegments` (chains, pipes, grouping, and
/// `$(...)`/backtick inners). Leading `NAME=value` assignments, redirects and
/// plain launchers (`sudo`, `env`, `command`, `exec`, `nohup`, `time`, `nice`,
/// `timeout`, `doas`, `builtin`, `busybox`) are dropped, argv0 is reduced to
/// its `commandName`, and `sh`/`bash`/`zsh -c`, `eval` and `env -S` payloads
/// recurse. Shared by the inline-program and self-protection floors; never
/// evaluates policy.
package func launchedCommands(_ raw: String) -> [[String]] {
    launchedCommandHeads(raw).filter { $0.speculative == false && $0.truncated == false }.map(\.argv)
}

/// Whether `raw` holds input the launcher parser stopped following (depth
/// cap, sensitive brace expansion): `launchedCommands` omits it, so a
/// caller that must see every command treats it as unknown.
package func launchIsTruncated(_ raw: String) -> Bool {
    launchedCommandHeads(raw).contains { $0.truncated }
}

/// Launched commands whose head may resolve to any program (`$NPM test`,
/// `"$(which npm)" test`): the head as written, then its operands.
package func dynamicHeadLaunches(_ raw: String) -> [[String]] {
    launchedCommandHeads(raw)
        .filter { $0.headIsDynamic && $0.speculative == false && $0.truncated == false }
        .map { [$0.head] + Array($0.guardArgv.dropFirst()) }
}

/// Launched commands as written: the head before `commandName` (`./ls`
/// stays a path) and operands without structural redirects.
package func launchedCommandsAsWritten(_ raw: String) -> [[String]] {
    launchedCommandHeads(raw)
        .filter { $0.speculative == false && $0.truncated == false }
        .map { [$0.head] + Array($0.guardArgv.dropFirst()) }
}

/// A launched command with the head word as written (before `commandName`).
/// `headIsDynamic` marks a head that may resolve to any program (`$RV`,
/// `$'rv'`, `r?`, `$(which rv)`). `speculative` entries are fail-closed
/// guesses for the self-protection floor only (a dynamic head may be a
/// launcher, so its operands may be the real command). `truncated` marks
/// input the depth cap could not follow; callers must treat it as unknown.
struct LaunchedCommand {
    let head: String
    /// argv as written, redirect operators included (`python3 < x.py`).
    let argv: [String]
    /// argv without structural redirects, for judging positional arguments.
    let guardArgv: [String]
    /// The structural redirect words alone (operators and targets).
    var redirects: [String] = []
    var headIsDynamic = false
    var speculative = false
    var truncated = false

    init(
        head: String, argv: [String], guardArgv: [String]? = nil,
        headIsDynamic: Bool = false, speculative: Bool = false, truncated: Bool = false
    ) {
        self.head = head
        self.argv = argv
        self.guardArgv = guardArgv ?? argv
        self.headIsDynamic = headIsDynamic
        self.speculative = speculative
        self.truncated = truncated
    }

    static let truncatedMarker = LaunchedCommand(head: "$", argv: ["$"], headIsDynamic: true, truncated: true)

    /// A command from a program name and operands that may carry redirect marks.
    static func make(head: String, program: String, args: [String], headIsDynamic: Bool, speculative: Bool = false) -> LaunchedCommand {
        var command = LaunchedCommand(
            head: head,
            argv: [program] + args.map(unmarkedWord),
            guardArgv: [program] + args.filter { isRedirectWord($0) == false },
            headIsDynamic: headIsDynamic,
            speculative: speculative
        )
        command.redirects = args.filter(isRedirectWord).map(unmarkedWord)
        return command
    }

    var asSpeculative: LaunchedCommand {
        var copy = self
        copy.speculative = true
        return copy
    }
}

/// Structural redirect words (operator and target) are marked in the word
/// list so launcher parsing skips them, while `argv` still shows them to the
/// inline-program floor. A quoted `'>'` is never marked.
private let redirectMark: Character = "\u{1}"
func isRedirectWord(_ word: String) -> Bool { word.first == redirectMark }
func unmarkedWord(_ word: String) -> String { isRedirectWord(word) ? String(word.dropFirst()) : word }

func launchedCommandHeads(_ raw: String) -> [LaunchedCommand] {
    launchedCommandHeads(raw, depth: 0)
}

private let maxLaunchDepth = 8
private let maxDynamicOperands = 512
private let maxBraceExpansions = 64
private let maxShellOperands = 64

private func launchedCommandHeads(_ raw: String, depth: Int) -> [LaunchedCommand] {
    guard depth < maxLaunchDepth else { return [.truncatedMarker] }
    var commands: [LaunchedCommand] = []
    // `splitSegments` peels `{a,b}` groups, so an expansion naming rv, a
    // launcher or a shell anywhere is judged unmodelled instead (fail closed).
    if hasSensitiveBraceExpansion(raw) { commands.append(.truncatedMarker) }
    // The splitter is not escape-aware: judge the raw text and the text with
    // real line continuations joined, so both a separator (`echo \\<LF>rv x`)
    // and a continuation (`rv \<LF>uninstall`) are seen.
    // A third, naive view (every `\<LF>` removed) over-claims where quoting or
    // escaping makes the parity view disagree: extra flags, never fewer.
    var views = [raw]
    for view in [joiningLineContinuations(raw), raw.replacingOccurrences(of: "\\\n", with: "")]
    where views.contains(view) == false {
        views.append(view)
    }
    for view in views {
        commands.append(contentsOf: segmentCommands(view, depth: depth))
    }
    return commands
}

private func segmentCommands(_ text: String, depth: Int) -> [LaunchedCommand] {
    var commands: [LaunchedCommand] = []
    for segment in splitSegments(text) {
        commands.append(contentsOf: resolve(commandWords(segment), depth: depth, expand: true))
    }
    return commands
}

/// Lexemes of `text` without newline tokens; structural redirects (`2>&1`,
/// `< file`) are marked. A quoted `'>'` is an ordinary word, not a redirect.
private func commandWords(_ text: String) -> [String] {
    let tokens = ShellPipeline.tokenize(text).filter { $0.isNewline == false }
    var words: [String] = []
    var index = 0
    while index < tokens.count {
        let token = tokens[index]
        let skip = token.wasQuoted ? 0 : redirectWordCount(token.lexeme)
        if skip > 0 {
            for offset in 0..<min(skip, tokens.count - index) {
                words.append(String(redirectMark) + tokens[index + offset].lexeme)
            }
            index += skip
        } else {
            words.append(token.lexeme)
            index += 1
        }
    }
    return words
}

/// `text` with each `\<LF>` that is a real continuation removed: the
/// backslash must be unescaped (an even run before it) and outside single
/// quotes. Scanned left to right, so `\\<LF>\<LF>` joins only the second.
func joiningLineContinuations(_ text: String) -> String {
    var out = ""
    var inSingle = false
    var inDouble = false
    var ansi = false
    var iterator = text.makeIterator()
    var previous: Character?
    while let char = iterator.next() {
        if inSingle {
            out.append(char)
            if ansi, char == "\\", let next = iterator.next() {
                out.append(next)
            } else if char == "'" {
                inSingle = false
                ansi = false
            }
            previous = char
            continue
        }
        if char == "\\" {
            guard let next = iterator.next() else {
                out.append(char)
                break
            }
            if next != "\n" { out.append(char); out.append(next) }
            previous = next
            continue
        }
        if char == "'", inDouble == false {
            inSingle = true
            ansi = previous == "$"
        } else if char == "\"" {
            inDouble.toggle()
        }
        out.append(char)
        previous = char
    }
    return out
}

private let braceSensitiveNames: Set<String> = {
    var names: Set<String> = ["rv", "rv-cli", "sudo", "env", "timeout", "busybox", "eval"]
    names.formUnion(plainLaunchers)
    names.formUnion(shellNames)
    return names
}()

/// True when an unquoted brace-comma group in `text` can expand to rv, a
/// launcher or a shell (`{rv,uninstall}`, `{r,}v`, `{sh,-c,...}`), or cannot be
/// expanded within bounds. Single quotes and `\{` are literal; double quotes
/// are not tracked (`$(...)` runs inside them).
func hasSensitiveBraceExpansion(_ text: String) -> Bool {
    guard text.contains("{"), text.contains(",") else { return false }
    var words: [String] = []
    var current = ""
    var iterator = text.makeIterator()
    var previous: Character?
    func flush() {
        if current.contains("{"), current.contains(",") { words.append(current) }
        current = ""
    }
    while let char = iterator.next() {
        defer { previous = char }
        if char == "\\" {
            _ = iterator.next()
            current.append("x")
        } else if char == "'" {
            while let inner = iterator.next() {
                if inner == "'" { break }
                if previous == "$", inner == "\\" { _ = iterator.next() }
            }
            current.append("x")
        } else if char.isWhitespace || ";&|()<>`".contains(char) {
            flush()
        } else if char != "\"" {
            current.append(char)
        }
    }
    flush()
    for word in words {
        guard let expansions = braceExpanded(word) else { return true }
        if expansions.contains(where: { braceSensitiveNames.contains(commandName($0)) }) { return true }
    }
    return false
}

private func resolve(_ input: [String], depth: Int, expand: Bool) -> [LaunchedCommand] {
    guard depth < maxLaunchDepth else { return [.truncatedMarker] }
    var words = input
    var out: [LaunchedCommand] = []
    var index = 0
    var launcher: String?
    var optionsEnded = false
    var splits = 0
    while index < words.count {
        let word = words[index]
        if isRedirectWord(word) {
            index += 1
            continue
        }
        if isAssignmentWord(word) {
            index += 1
            continue
        }
        // Option letters are case-sensitive (`-S` vs `-s`): unescape only.
        let folded = unescapeBackslashPairs(word)
        if let current = launcher, optionsEnded == false, folded.hasPrefix("-") {
            if folded == "--" {
                optionsEnded = true
                index += 1
                continue
            }
            let next = index + 1 < words.count ? words[index + 1] : nil
            switch launcherOption(current, folded, next: next) {
            case .consume(let count):
                index += count
            case .split(let payload, let count):
                splits += 1
                guard splits < maxLaunchDepth else { return out + [.truncatedMarker] }
                out.append(contentsOf: launchedCommandHeads(payload, depth: depth + 1))
                let payloadWords = commandWords(payload)
                words = payloadWords + Array(words[min(index + count, words.count)...])
                index = 0
                launcher = nil
                optionsEnded = false
            }
            continue
        }
        if launcher == "timeout" {
            // The duration operand precedes the command.
            launcher = nil
            index += 1
            continue
        }
        if isDynamicHead(word) {
            out.append(contentsOf: dynamicCandidates(Array(words[index...]), depth: depth, expand: expand))
        }
        let name = decodedCommandName(word)
        if name == "sudo" || name == "env" || name == "timeout" || name == "busybox" || plainLaunchers.contains(name) {
            launcher = name
            optionsEnded = false
            index += 1
            continue
        }
        break
    }
    guard index < words.count else { return out }
    let head = words[index]
    let args = Array(words[(index + 1)...])
    let operands = args.filter { isRedirectWord($0) == false }
    let program = commandName(head)
    let name = decodedCommandName(head)
    if shellNames.contains(name),
       let flag = operands.firstIndex(where: { isShellCommandFlag(foldedWord($0), shell: name) }),
       case let payloads = operands[(flag + 1)...].filter({ foldedWord($0).hasPrefix("-") == false }),
       payloads.isEmpty == false
    {
        // Valued shell options (`-O extglob`, `-o pipefail`) precede the real
        // command string, so every non-option operand is parsed as one.
        if payloads.count > maxShellOperands { out.append(.truncatedMarker) }
        for payload in payloads.prefix(maxShellOperands) {
            for variant in payloadVariants(payload) {
                out.append(contentsOf: launchedCommandHeads(variant, depth: depth + 1))
            }
        }
        return out
    }
    if name == "eval" {
        let operands = operands.drop(while: { foldedWord($0) == "--" })
        let raw = operands.joined(separator: " ")
        let decoded = operands.map { $0.ansiCDecodedIfMarked }.joined(separator: " ")
        for variant in Set([raw, decoded]) {
            out.append(contentsOf: launchedCommandHeads(variant, depth: depth + 1))
        }
    }
    out.append(.make(head: head, program: program, args: args, headIsDynamic: isDynamicHead(head)))
    return out
}

/// A dynamic head (`$X`, `$'sudo'`, `r?`) may be any program, so besides
/// judging it as the guarded binary, every operand suffix may be the real
/// command (it may be a launcher) and any spaced operand a command line.
private func dynamicCandidates(_ slice: [String], depth: Int, expand: Bool) -> [LaunchedCommand] {
    guard let head = slice.first else { return [] }
    // Operand suffixes are materialised per start: bound the work and fail
    // closed on absurd operand counts rather than going quadratic.
    guard slice.count <= maxDynamicOperands else { return [.truncatedMarker] }
    let rest = Array(slice.dropFirst())
    var out = [LaunchedCommand.make(head: head, program: commandName(head), args: rest, headIsDynamic: true, speculative: true)]
    for word in rest where isRedirectWord(word) == false && word.contains(where: \.isWhitespace) {
        out.append(contentsOf: launchedCommandHeads(word, depth: depth + 1).map(\.asSpeculative))
    }
    if expand {
        for start in rest.indices {
            out.append(contentsOf: resolve(Array(rest[start...]), depth: depth + 1, expand: false).map(\.asSpeculative))
        }
    }
    return out
}

/// True when the head may resolve to a program other than its literal text:
/// a substitution or variable that survives into the basename (`$RV`,
/// `$(which rv)`, `$'rv'`), or a glob/brace there (`r?`, `r[v]`). A literal
/// basename under a dynamic directory (`$HOME/bin/tool`) is that program.
func isDynamicHead(_ word: String) -> Bool {
    let base = basename(collapsingSubstitutions(word))
    if base == "[" || base == "[[" { return false }
    return base.contains(where: { "$`*?[{".contains($0) })
}

/// Replaces each `$(...)`, `${...}` and backtick span with a lone `$`, so a
/// `/` inside a substitution cannot masquerade as a path separator.
private func collapsingSubstitutions(_ word: String) -> String {
    let chars = Array(word)
    var out = ""
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c == "`" {
            i += 1
            while i < chars.count, chars[i] != "`" { i += 1 }
            i += 1
            out.append("$")
        } else if c == "$", i + 1 < chars.count, chars[i + 1] == "(" || chars[i + 1] == "{" {
            let close: Character = chars[i + 1] == "(" ? ")" : "}"
            let open = chars[i + 1]
            var depth = 1
            i += 2
            while i < chars.count, depth > 0 {
                if chars[i] == open { depth += 1 } else if chars[i] == close { depth -= 1 }
                i += 1
            }
            out.append("$")
        } else {
            out.append(c)
            i += 1
        }
    }
    return out
}

/// Leading redirect words to skip: `2>&1`, `</dev/null`, `>f` are one word;
/// a bare operator (`<`, `>>`, `2>`) is followed by its target.
func redirectWordCount(_ word: String) -> Int {
    let chars = Array(word)
    var i = 0
    while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1 }
    if i < chars.count, chars[i] == "&" { i += 1 }
    guard i < chars.count, chars[i] == "<" || chars[i] == ">" else { return 0 }
    while i < chars.count, chars[i] == "<" || chars[i] == ">" { i += 1 }
    if i < chars.count, chars[i] == "&" || chars[i] == "|" { i += 1 }
    return i >= chars.count ? 2 : 1
}

private enum LauncherOption {
    case consume(Int)
    case split(payload: String, consumed: Int)
}

private let shortValuedOptions: [String: Set<Character>] = [
    "sudo": ["u", "g", "C", "D", "h", "p", "r", "t", "U", "T"],
    "env": ["u", "C", "P", "a"],
    "nice": ["n"],
    "doas": ["u", "C"],
    "timeout": ["s", "k"],
    "exec": ["a"],
]

private let longValuedOptions: [String: [String]] = [
    "sudo": ["user", "group", "host", "prompt", "chdir", "close-from", "role", "type", "other-user"],
    "env": ["unset", "chdir", "argv0"],
    "timeout": ["signal", "kill-after"],
]

/// Parses one launcher option word (already unescaped): short clusters like
/// `-iS` and `-nu`, long options with unambiguous-prefix abbreviations.
private func launcherOption(_ launcher: String, _ word: String, next: String?) -> LauncherOption {
    let nextCount = next == nil ? 1 : 2
    if word.hasPrefix("--") {
        let body = word.dropFirst(2)
        let name = String(body.prefix { $0 != "=" })
        let value = body.firstIndex(of: "=").map { String(body[body.index(after: $0)...]) }
        if launcher == "env", "split-string".hasPrefix(name) {
            if let value { return .split(payload: value, consumed: 1) }
            return .split(payload: next ?? "", consumed: nextCount)
        }
        if value == nil, longValuedOptions[launcher, default: []].contains(where: { $0.hasPrefix(name) }) {
            return .consume(nextCount)
        }
        return .consume(1)
    }
    let chars = Array(word.dropFirst())
    let valued = shortValuedOptions[launcher] ?? []
    for (offset, char) in chars.enumerated() {
        // The remainder is only built where it is used: clusters can be huge.
        if launcher == "env", char == "S" {
            if offset + 1 < chars.count { return .split(payload: String(chars[(offset + 1)...]), consumed: 1) }
            return .split(payload: next ?? "", consumed: nextCount)
        }
        if valued.contains(char) {
            return .consume(offset + 1 < chars.count ? 1 : nextCount)
        }
    }
    return .consume(1)
}

/// Unescaped word (`\-S` -> `-S`) for flag and verb matching.
func foldedWord(_ word: String) -> String {
    unescapeBackslashPairs(word).folding(options: .caseInsensitive, locale: nil)
}

/// The tokenizer emits `$'...'` as `$` plus the raw, undecoded inner text.
/// The shell decodes the escapes, so `$'\x72v'` runs `rv`.
extension String {
    var ansiCDecodedIfMarked: String {
        guard hasPrefix("$"), hasPrefix("$(") == false, hasPrefix("${") == false else { return self }
        return decodingAnsiCEscapes(String(dropFirst()))
    }
}

private func payloadVariants(_ word: String) -> [String] {
    Array(Set([word, word.ansiCDecodedIfMarked, unescapeBackslashPairs(word)]))
}

private func decodedCommandName(_ word: String) -> String {
    commandName(word.ansiCDecodedIfMarked)
}

func decodingAnsiCEscapes(_ text: String) -> String {
    let chars = Array(text.unicodeScalars)
    var out = String.UnicodeScalarView()
    var i = 0
    func digits(_ limit: Int, radix: Int) -> UInt32? {
        var value: UInt32 = 0
        var count = 0
        while count < limit, i < chars.count, let digit = Character(chars[i]).hexDigitValue, digit < radix {
            value = value * UInt32(radix) + UInt32(digit)
            i += 1
            count += 1
        }
        return count == 0 ? nil : value
    }
    while i < chars.count {
        let c = chars[i]
        guard c == "\\", i + 1 < chars.count else {
            out.append(c)
            i += 1
            continue
        }
        let n = chars[i + 1]
        i += 2
        switch n {
        case "n": out.append("\n")
        case "t": out.append("\t")
        case "r": out.append("\r")
        case "a": out.append("\u{07}")
        case "b": out.append("\u{08}")
        case "e", "E": out.append("\u{1B}")
        case "f": out.append("\u{0C}")
        case "v": out.append("\u{0B}")
        case "x":
            if let v = digits(2, radix: 16), let scalar = Unicode.Scalar(v) { out.append(scalar) }
        case "u":
            if let v = digits(4, radix: 16), let scalar = Unicode.Scalar(v) { out.append(scalar) }
        case "U":
            if let v = digits(8, radix: 16), let scalar = Unicode.Scalar(v) { out.append(scalar) }
        case "0"..."7":
            i -= 1
            if let v = digits(3, radix: 8), let scalar = Unicode.Scalar(v) { out.append(scalar) }
        default: out.append(n)
        }
    }
    return String(out)
}

/// A command word as a case-insensitive filesystem resolves it: basename,
/// backslash-unescaped, then Unicode case-folded the way APFS folds
/// (`BASH`, `r\v`, `baſh`, `ﬁsh`). `lowercased()` alone misses `ſ`/`ﬁ`.
func commandName(_ word: String) -> String {
    unescapeBackslashPairs(basename(word)).folding(options: .caseInsensitive, locale: nil)
}

private let shellNames: Set<String> = [
    "sh", "bash", "zsh", "dash", "ksh", "mksh", "ash", "fish", "csh", "tcsh",
    "ksh93", "rbash", "yash", "pwsh", "nu", "xonsh",
]

/// Any short-option cluster containing `c` (`-c`, `-lc`, `-ce`, `-cex`)
/// takes the next non-option word as the command string; pwsh/nu spell it
/// `-c`/`-Command`.
private func isShellCommandFlag(_ word: String, shell: String) -> Bool {
    guard word.hasPrefix("-"), word.hasPrefix("--") == false else { return false }
    if word.hasPrefix("-command") { return true }
    return word.dropFirst().contains("c")
}

/// Launchers whose next non-flag word is the real command.
let plainLaunchers: Set<String> = ["command", "exec", "nohup", "time", "builtin", "nice", "doas"]

func isAssignmentWord(_ word: String) -> Bool {
    guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
    let name = word[..<equals]
    guard let first = name.first, assignmentNameStart.contains(first) else { return false }
    return name.allSatisfy { assignmentNameChars.contains($0) }
}

/// Bounded bash-style brace expansion (`pre{a,b}post`, nested). Nil when the
/// word has no expandable group worth modelling or the expansion exceeds the
/// bound, so the caller fails closed.
func braceExpanded(_ word: String) -> [String]? {
    var results = [word]
    var rounds = 0
    while let target = results.firstIndex(where: { expandableGroup($0) != nil }) {
        rounds += 1
        guard rounds <= maxBraceExpansions, let group = expandableGroup(results[target]) else { return nil }
        let text = Array(results[target])
        let prefix = String(text[..<group.open])
        let suffix = String(text[(group.close + 1)...])
        results.remove(at: target)
        results.insert(contentsOf: group.alternatives.map { prefix + $0 + suffix }, at: target)
        if results.count > maxBraceExpansions { return nil }
    }
    return results
}

private func expandableGroup(_ word: String) -> (open: Int, close: Int, alternatives: [String])? {
    let chars = Array(word)
    var i = 0
    while i < chars.count {
        defer { i += 1 }
        guard chars[i] == "{", i == 0 || chars[i - 1] != "$" else { continue }
        var depth = 1
        var j = i + 1
        var commas: [Int] = []
        while j < chars.count, depth > 0 {
            if chars[j] == "{" { depth += 1 }
            else if chars[j] == "}" { depth -= 1 }
            else if chars[j] == ",", depth == 1 { commas.append(j) }
            j += 1
        }
        guard depth == 0, commas.isEmpty == false else { continue }
        var alternatives: [String] = []
        var start = i + 1
        for comma in commas + [j - 1] {
            alternatives.append(String(chars[start..<comma]))
            start = comma + 1
        }
        return (i, j - 1, alternatives)
    }
    return nil
}
