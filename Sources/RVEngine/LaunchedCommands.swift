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
func launchedCommands(_ raw: String) -> [[String]] {
    launchedCommandHeads(raw).filter { $0.speculative == false && $0.truncated == false }.map(\.argv)
}

/// A launched command with the head word as written (before `commandName`).
/// `headIsDynamic` marks a head that may resolve to any program (`$RV`,
/// `$'rv'`, `r?`, `$(which rv)`). `speculative` entries are fail-closed
/// guesses for the self-protection floor only (a dynamic head may be a
/// launcher, so its operands may be the real command). `truncated` marks
/// input the depth cap could not follow; callers must treat it as unknown.
struct LaunchedCommand {
    let head: String
    let argv: [String]
    var headIsDynamic = false
    var speculative = false
    var truncated = false

    static let truncatedMarker = LaunchedCommand(head: "$", argv: ["$"], headIsDynamic: true, truncated: true)
}

func launchedCommandHeads(_ raw: String) -> [LaunchedCommand] {
    launchedCommandHeads(raw, depth: 0)
}

private let maxLaunchDepth = 8

private func launchedCommandHeads(_ raw: String, depth: Int) -> [LaunchedCommand] {
    guard depth < maxLaunchDepth else { return [.truncatedMarker] }
    // `\<newline>` is a line continuation: the shell joins the words.
    let joined = raw.replacingOccurrences(of: "\\\r\n", with: "").replacingOccurrences(of: "\\\n", with: "")
    var commands: [LaunchedCommand] = []
    for segment in splitSegments(joined) {
        let words = ShellPipeline.tokenize(segment)
            .filter { $0.isNewline == false }
            .map(\.lexeme)
        commands.append(contentsOf: resolve(words, depth: depth, expand: true))
    }
    return commands
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
        if isAssignmentWord(word) {
            index += 1
            continue
        }
        let redirect = redirectWordCount(word)
        if redirect > 0 {
            index += redirect
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
                let payloadWords = ShellPipeline.tokenize(payload).filter { $0.isNewline == false }.map(\.lexeme)
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
    let program = commandName(head)
    let name = decodedCommandName(head)
    if shellNames.contains(name),
       let flag = args.firstIndex(where: { isShellCommandFlag(foldedWord($0), shell: name) }),
       case let payloads = args[(flag + 1)...].filter({ foldedWord($0).hasPrefix("-") == false }),
       payloads.isEmpty == false
    {
        // Valued shell options (`-O extglob`, `-o pipefail`) precede the real
        // command string, so every non-option operand is parsed as one.
        for payload in payloads {
            for variant in payloadVariants(payload) {
                out.append(contentsOf: launchedCommandHeads(variant, depth: depth + 1))
            }
        }
        return out
    }
    if name == "eval" {
        let operands = args.drop(while: { foldedWord($0) == "--" })
        let raw = operands.joined(separator: " ")
        let decoded = operands.map { $0.ansiCDecodedIfMarked }.joined(separator: " ")
        for variant in Set([raw, decoded]) {
            out.append(contentsOf: launchedCommandHeads(variant, depth: depth + 1))
        }
    }
    out.append(LaunchedCommand(head: head, argv: [program] + args, headIsDynamic: isDynamicHead(head)))
    return out
}

/// A dynamic head (`$X`, `$'sudo'`, `r?`) may be any program, so besides
/// judging it as the guarded binary, every operand suffix may be the real
/// command (it may be a launcher) and any spaced operand a command line.
private func dynamicCandidates(_ slice: [String], depth: Int, expand: Bool) -> [LaunchedCommand] {
    guard let head = slice.first else { return [] }
    let rest = Array(slice.dropFirst())
    var out = [LaunchedCommand(head: head, argv: [commandName(head)] + rest, headIsDynamic: true, speculative: true)]
    for word in rest where word.contains(where: \.isWhitespace) {
        out.append(contentsOf: launchedCommandHeads(word, depth: depth + 1).map(\.asSpeculative))
    }
    if expand {
        for start in rest.indices {
            out.append(contentsOf: resolve(Array(rest[start...]), depth: depth + 1, expand: false).map(\.asSpeculative))
        }
    }
    return out
}

private extension LaunchedCommand {
    var asSpeculative: LaunchedCommand {
        LaunchedCommand(head: head, argv: argv, headIsDynamic: headIsDynamic, speculative: true, truncated: truncated)
    }
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
private func redirectWordCount(_ word: String) -> Int {
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
        let remainder = String(chars[(offset + 1)...])
        if launcher == "env", char == "S" {
            if remainder.isEmpty == false { return .split(payload: remainder, consumed: 1) }
            return .split(payload: next ?? "", consumed: nextCount)
        }
        if valued.contains(char) {
            return .consume(remainder.isEmpty ? nextCount : 1)
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

private func isAssignmentWord(_ word: String) -> Bool {
    guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
    let name = word[..<equals]
    guard let first = name.first, assignmentNameStart.contains(first) else { return false }
    return name.allSatisfy { assignmentNameChars.contains($0) }
}
