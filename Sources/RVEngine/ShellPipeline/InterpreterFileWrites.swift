import Foundation

/// File-write markers for inline python, node and ruby programs: an `open`
/// in a write/append/update mode, a node write call, a ruby `File` write
/// constant. A write whose path is a string literal is proxied as
/// `tee -- <paths>` so the location decides (in the repo allows, outside
/// denies); any other write (dynamic path or mode, aliasing) limits the
/// unwrap, like a process spawn. Plain reads (`open("f").read()`) pass.

/// File writes found in an inline program: literal target paths, plus
/// whether any write has a target or mode rv cannot resolve.
struct InterpreterWrites {
    var paths: [String] = []
    var opaque = false
}

/// `tee -- <paths>` for the filesystem analysis. Operands holding shell
/// metacharacters are quoted so they stay one word (`;`, `|`, `&&`, `>`);
/// others stay bare so `~` still resolves to home.
func writeProxyCommand(_ paths: [String]) -> String {
    let metacharacters = Set(" \t\n;|&<>()$`\\\"'*?[]{}!#")
    let tokens = (["tee", "--"] + paths).map { path in
        ShellPipeline.Token(lexeme: path, wasQuoted: path.contains(where: metacharacters.contains))
    }
    return renderCommand(tokens)
}

/// Compiled call-site patterns, built once. `callee` is a regex alternation
/// matched at an identifier start or after a `.`; `parenless` also accepts
/// `callee 'arg', ...` (ruby).
struct CallPattern: Sendable {
    fileprivate let regex: NSRegularExpression?

    fileprivate init(_ callee: String, parenless: Bool = false) {
        let tail = parenless ? #"(?:\s*\(|[ \t]+(?=[\w"'$:@/.~-]))"# : #"\s*\("#
        regex = try? NSRegularExpression(pattern: "(?<![\\w$])(?:\(callee))\(tail)")
    }

    static let pythonFunctions = CallPattern("open|ZipFile|TarFile|FileIO")
    static let pythonMethods = CallPattern(#"(?<=\.\s{0,3})open"#)
    static let nodeOpen = CallPattern("open|openSync")
    static let nodeWriters = CallPattern("writeFile|writeFileSync|appendFile|appendFileSync|createWriteStream")
    static let nodeCopies = CallPattern("copyFile|copyFileSync")
    static let rubyOpen = CallPattern(#"File\s*\.\s*(?:open|new)|IO\s*\.\s*open|open"#, parenless: true)
}

/// Top-level (depth-0, outside string literals) argument texts of every
/// call matching `pattern`. Nil when the pattern failed to compile: callers
/// treat that as an unresolvable write (fail closed).
func callArguments(in code: String, pattern: CallPattern) -> [[String]]? {
    guard let regex = pattern.regex else { return nil }
    let chars = Array(code)
    var calls: [[String]] = []
    for match in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
        guard let end = Range(match.range, in: code).map({ code.distance(from: code.startIndex, to: $0.upperBound) })
        else { continue }
        calls.append(splitArguments(chars, from: end, parenless: match.range.length > 0 && chars[end - 1] != "("))
    }
    return calls
}

private func splitArguments(_ chars: [Character], from start: Int, parenless: Bool = false) -> [String] {
    if parenless { return splitParenlessArguments(chars, from: start) }
    var arguments: [String] = []
    var current = ""
    var depth = 0
    var quote: Character?
    var index = start
    while index < chars.count {
        let char = chars[index]
        index += 1
        if let open = quote {
            current.append(char)
            if char == "\\", index < chars.count {
                current.append(chars[index])
                index += 1
            } else if char == open {
                quote = nil
            }
            continue
        }
        switch char {
        case "\"", "'":
            quote = char
            current.append(char)
        case "(", "[", "{":
            depth += 1
            current.append(char)
        case ")", "]", "}":
            if depth == 0 {
                arguments.append(current)
                return arguments.filter { $0.trimmingCharacters(in: .whitespaces).isEmpty == false }
            }
            depth -= 1
            current.append(char)
        case "," where depth == 0:
            arguments.append(current)
            current = ""
        default:
            current.append(char)
        }
    }
    return arguments.filter { $0.trimmingCharacters(in: .whitespaces).isEmpty == false }
}

/// Arguments of a ruby call without parentheses: the rest of the statement,
/// up to a newline, `;`, or a trailing `do`/`{` block.
private func splitParenlessArguments(_ chars: [Character], from start: Int) -> [String] {
    var end = start
    var quote: Character?
    while end < chars.count {
        let char = chars[end]
        if let open = quote {
            if char == "\\" { end += 1 } else if char == open { quote = nil }
        } else if char == "\"" || char == "'" {
            quote = char
        } else if char == "\n" || char == ";" {
            break
        }
        end += 1
    }
    var text = String(chars[start..<min(end, chars.count)])
    for pattern in [#"\s+do\b.*$"#, #"\s*\{.*$"#] {
        text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    return splitArguments(Array(text + ")"), from: 0)
}

private enum ModeLiteral {
    case readOnly
    case writes
    case notLiteral
}

private func classifyMode(_ expression: String) -> ModeLiteral {
    let text = expression.trimmingCharacters(in: .whitespaces)
    if text.range(
        of: #"^(?:File|IO)::RDONLY(?:\s*\|\s*(?:File|IO)::(?:BINARY|NONBLOCK|NOCTTY))*$"#,
        options: .regularExpression
    ) != nil {
        return .readOnly
    }
    guard text.count >= 2, let quote = text.first, quote == "\"" || quote == "'", text.last == quote else {
        return .notLiteral
    }
    // Ruby appends an encoding after a colon ("r:UTF-8").
    let mode = text.dropFirst().dropLast().split(separator: ":", omittingEmptySubsequences: false).first ?? ""
    return mode.allSatisfy({ "rbtU".contains($0) }) ? .readOnly : .writes
}

private func keywordValue(_ argument: String, names: [String]) -> String? {
    var text = argument.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix(":") { text.removeFirst() }
    for name in names where text.hasPrefix(name) {
        let rest = text.dropFirst(name.count).drop { $0 == " " }
        for separator in ["=>", ":", "="] where rest.hasPrefix(separator) {
            if separator == "=", rest.hasPrefix("==") { continue }
            return String(rest.dropFirst(separator.count))
        }
    }
    return nil
}

/// True when a call's mode argument (second positional, or `mode=`/`mode:`)
/// opens for write/update, or cannot be read as a read-only literal.
/// `unknownIsWrite` controls non-literal modes (`open(f, m)`).
private func callOpensForWrite(_ arguments: [String], unknownIsWrite: Bool, modePosition: Int = 2) -> Bool {
    var positional = 0
    for argument in arguments {
        // `open(*args)` / `open(f, **kw)`: the mode is hidden in the splat.
        if argument.trimmingCharacters(in: .whitespaces).hasPrefix("*") {
            if unknownIsWrite { return true }
            continue
        }
        if let value = keywordValue(argument, names: ["mode", "flags"]) {
            switch classifyMode(value) {
            case .writes: return true
            case .notLiteral: if unknownIsWrite { return true }
            case .readOnly: break
            }
            continue
        }
        if keywordValue(argument, names: ["encoding", "buffering", "newline", "errors", "closefd", "opener",
                                          "external_encoding", "textmode", "binmode", "perm"]) != nil
        {
            continue
        }
        positional += 1
        guard positional == modePosition else { continue }
        switch classifyMode(argument) {
        case .writes: return true
        case .notLiteral: if unknownIsWrite { return true }
        case .readOnly: break
        }
    }
    return false
}

/// A string literal's text (no prefix, no interpolation), else nil.
private func literalPath(_ expression: String) -> String? {
    let text = expression.trimmingCharacters(in: .whitespaces)
    guard text.count >= 2, let quote = text.first, quote == "\"" || quote == "'", text.last == quote else {
        return nil
    }
    let body = String(text.dropFirst().dropLast())
    if body.contains("\\") || body.contains("#{") || body.contains("${") || body.contains(quote) { return nil }
    return body
}

private func firstPositional(_ arguments: [String]) -> String? {
    arguments.first { keywordValue($0, names: ["mode", "flags", "file", "path", "encoding"]) == nil }
}

private func record(_ write: String?, into writes: inout InterpreterWrites) {
    if let write, let path = literalPath(write), path.isEmpty == false {
        writes.paths.append(path)
    } else {
        writes.opaque = true
    }
}

/// An `open` whose mode is a known write proxies its literal path; a mode
/// that is only unknown (`open("f", m)`) cannot be resolved at all.
private func recordOpen(_ arguments: [String], into writes: inout InterpreterWrites) {
    if callOpensForWrite(arguments, unknownIsWrite: false) {
        record(firstPositional(arguments), into: &writes)
    } else {
        writes.opaque = true
    }
}

/// Mode-looking literal (`w`, `rb+`, `a`), as opposed to a name like
/// `zf.open('member.txt')`.
private func looksLikeMode(_ expression: String) -> Bool {
    guard let text = literalPath(expression) else { return false }
    return text.isEmpty == false && text.allSatisfy { "rwxabt+U".contains($0) }
}

func pythonFileWrites(_ code: String) -> InterpreterWrites {
    var writes = InterpreterWrites()
    guard let functions = callArguments(in: code, pattern: .pythonFunctions),
        let methods = callArguments(in: code, pattern: .pythonMethods)
    else { return InterpreterWrites(paths: [], opaque: true) }
    for arguments in functions where callOpensForWrite(arguments, unknownIsWrite: true) {
        recordOpen(arguments, into: &writes)
    }
    // `p.open("w")` / `Path(x).open(mode="w")`: the method takes the mode first
    // and the receiver (the path) is not visible, so a write is unresolvable.
    for arguments in methods {
        let first = arguments.first { keywordValue($0, names: ["mode"]) == nil }
        let modeKeyword = arguments.compactMap { keywordValue($0, names: ["mode"]) }.first
        if let modeKeyword {
            if classifyMode(modeKeyword) != .readOnly { writes.opaque = true }
        } else if let first {
            if first.trimmingCharacters(in: .whitespaces).hasPrefix("*") {
                writes.opaque = true
            } else if looksLikeMode(first), callOpensForWrite([first], unknownIsWrite: true, modePosition: 1) {
                writes.opaque = true
            }
        }
    }
    // A bare `open` that is not called (`f = open`, `(open)(...)`) hides its mode.
    if matches(code, pattern: #"(?<![.\w'"])open\b(?!\s*\()(?![\w'"])"#) { writes.opaque = true }
    return writes
}

func nodeFileWrites(_ code: String) -> InterpreterWrites {
    var writes = InterpreterWrites()
    guard let writers = callArguments(in: code, pattern: .nodeWriters),
        let copies = callArguments(in: code, pattern: .nodeCopies),
        let opens = callArguments(in: code, pattern: .nodeOpen)
    else { return InterpreterWrites(paths: [], opaque: true) }
    for arguments in writers { record(arguments.first, into: &writes) }
    for arguments in copies { record(arguments.dropFirst().first, into: &writes) }
    for arguments in opens where callOpensForWrite(arguments, unknownIsWrite: false) {
        record(arguments.first, into: &writes)
    }
    if matches(code, pattern: #"(?<![\w$])(fs|promises)\s*\.\s*(cp|cpSync|truncate|truncateSync|symlink|symlinkSync|link|linkSync)\b"#)
        || matches(code, pattern: #"\bO_(WRONLY|RDWR|CREAT|APPEND|TRUNC)\b"#)
        // Bracketed or renamed access: `fs["writeFileSync"](...)`, `{writeFileSync: w}`.
        || matches(code, pattern: #"\[\s*['"`](write|append|createWrite|copy)\w*['"`]\s*\]"#)
        || matches(code, pattern: #"\b(writeFile|writeFileSync|appendFile|appendFileSync|createWriteStream|copyFile|copyFileSync)\s*:"#)
    {
        writes.opaque = true
    }
    return writes
}

func rubyFileWrites(_ code: String) -> InterpreterWrites {
    var writes = InterpreterWrites()
    if matches(code, pattern: #"\bFile::(WRONLY|RDWR|CREAT|APPEND|TRUNC|EXCL)\b"#) { writes.opaque = true }
    guard let opens = callArguments(in: code, pattern: .rubyOpen) else {
        return InterpreterWrites(paths: [], opaque: true)
    }
    for arguments in opens where callOpensForWrite(arguments, unknownIsWrite: true) {
        recordOpen(arguments, into: &writes)
    }
    return writes
}

// MARK: benign eval

/// Removes `eval` uses that cannot run chosen code so the eval markers do
/// not fire on them: `eval("1+1")` over a pure arithmetic string literal
/// (python, node), and perl's trapping block `eval { ... }` (the block's
/// own contents are still scanned). Perl string eval stays.
func removingBenignEval(_ code: String, arithmeticLiterals: Bool, blockEval: Bool) -> String {
    var program = code
    if arithmeticLiterals {
        program = program.replacingOccurrences(
            of: #"eval\(\s*(["'])[0-9+\-*/%().\s]*\1\s*\)"#, with: "0", options: .regularExpression
        )
    }
    if blockEval {
        program = program.replacingOccurrences(of: #"\beval\s*\{"#, with: "{", options: .regularExpression)
    }
    return program
}
