import Foundation

/// File-write markers for inline python, node and ruby programs: an `open`
/// in a write/append/update mode, a node write call, a ruby `File` write
/// constant. A hit limits the unwrap (the target path is dataflow rv cannot
/// resolve), like a process spawn. Plain reads (`open("f").read()`) pass.

/// Top-level (depth-0, outside string literals) argument texts of every
/// `callee(...)` call in `code`; `callee` is a regex alternation matched at
/// an identifier start or after a `.`.
func callArguments(in code: String, callee: String) -> [[String]] {
    guard let regex = try? NSRegularExpression(pattern: "(?<![\\w$])(?:\(callee))\\s*\\(") else { return [] }
    let chars = Array(code)
    var calls: [[String]] = []
    for match in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
        guard let end = Range(match.range, in: code).map({ code.distance(from: code.startIndex, to: $0.upperBound) })
        else { continue }
        calls.append(splitArguments(chars, from: end))
    }
    return calls
}

private func splitArguments(_ chars: [Character], from start: Int) -> [String] {
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

private enum ModeLiteral {
    case readOnly
    case writes
    case notLiteral
}

private func classifyMode(_ expression: String) -> ModeLiteral {
    let text = expression.trimmingCharacters(in: .whitespaces)
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

func pythonOpensFileForWrite(_ code: String) -> Bool {
    let functions = callArguments(in: code, callee: "open|ZipFile|TarFile").contains {
        callOpensForWrite($0, unknownIsWrite: true)
    }
    // `Path(p).open("w")`: the method takes the mode first.
    let methods = callArguments(in: code, callee: #"(?<=\)\s{0,3}\.\s{0,3})open"#).contains {
        callOpensForWrite($0, unknownIsWrite: true, modePosition: 1)
    }
    return functions || methods
}

func nodeWritesFiles(_ code: String) -> Bool {
    if matches(code, pattern: #"(?<![\w$])(writeFile|writeFileSync|appendFile|appendFileSync|createWriteStream|copyFile|copyFileSync)\s*\("#)
    {
        return true
    }
    if matches(code, pattern: #"(?<![\w$])(fs|promises)\s*\.\s*(cp|cpSync|truncate|truncateSync|symlink|symlinkSync|link|linkSync)\b"#) {
        return true
    }
    return callArguments(in: code, callee: "open|openSync").contains {
        callOpensForWrite($0, unknownIsWrite: false)
    }
}

func rubyOpensFileForWrite(_ code: String) -> Bool {
    if matches(code, pattern: #"\bFile::(WRONLY|RDWR|CREAT|APPEND|TRUNC|EXCL)\b"#) { return true }
    return callArguments(in: code, callee: #"File\s*\.\s*(open|new)|IO\s*\.\s*open|open"#).contains {
        callOpensForWrite($0, unknownIsWrite: true)
    }
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
