import Foundation

/// True when an awk program can run a command or write a file: a
/// `system(...)` call, an unquoted `|` that is not `||` (pipe to or from a
/// command), or an unparenthesized `>`/`>>` inside a `print`/`printf`
/// statement (output redirection). A `>` inside parentheses is a comparison,
/// and `|` or `>` inside strings and `/regex/` literals is data.
func awkCodeCanSpawn(_ code: String) -> Bool {
    if matches(code, pattern: #"\bsystem\s*\("#) { return true }
    let chars = Array(code)
    var index = 0
    var depth = 0
    var inPrint = false
    var previous: Character?
    while index < chars.count {
        let char = chars[index]
        if char == "\"" {
            index = indexAfterAwkString(chars, openAt: index)
            previous = "\""
            continue
        }
        if char == "/", regexMayStart(after: previous) {
            index = indexAfterAwkRegex(chars, openAt: index)
            previous = "/"
            continue
        }
        if char.isLetter || char == "_" {
            var end = index
            while end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "_" {
                end += 1
            }
            let word = String(chars[index..<end])
            if word == "print" || word == "printf" { inPrint = true }
            previous = chars[end - 1]
            index = end
            continue
        }
        switch char {
        case "|":
            if index + 1 < chars.count, chars[index + 1] == "|" {
                index += 2
                previous = "|"
                continue
            }
            return true
        case "(", "[":
            depth += 1
        case ")", "]":
            depth = max(0, depth - 1)
        case ">":
            if inPrint, depth == 0, awkRedirectTargetIsStdStream(chars, after: index) == false { return true }
        case ";", "}", "\n":
            if depth == 0 { inPrint = false }
        default:
            break
        }
        if char.isWhitespace == false { previous = char }
        index += 1
    }
    return false
}

/// `> "/dev/stdout"`, `> "/dev/stderr"`, `> "/dev/null"` (also `>>`): the
/// redirect writes to a standard stream, not a file.
private func awkRedirectTargetIsStdStream(_ chars: [Character], after index: Int) -> Bool {
    var cursor = index + 1
    if cursor < chars.count, chars[cursor] == ">" { cursor += 1 }
    while cursor < chars.count, chars[cursor] == " " || chars[cursor] == "\t" { cursor += 1 }
    for target in ["/dev/stdout", "/dev/stderr", "/dev/null"] {
        let literal = Array("\"\(target)\"")
        if cursor + literal.count <= chars.count, Array(chars[cursor..<cursor + literal.count]) == literal {
            return true
        }
    }
    return false
}

/// A `/` starts a regex literal where an operand is expected, not after an
/// identifier, number, or closing bracket (division).
private func regexMayStart(after previous: Character?) -> Bool {
    guard let previous else { return true }
    return "{(,;!~&|=<>+-*%^?:\n".contains(previous)
}

private func indexAfterAwkString(_ chars: [Character], openAt open: Int) -> Int {
    var index = open + 1
    while index < chars.count {
        if chars[index] == "\\" {
            index += 2
            continue
        }
        if chars[index] == "\"" { return index + 1 }
        index += 1
    }
    return chars.count
}

/// Skips a `/regex/`, honoring escapes and `[...]` classes that may hold `/`.
private func indexAfterAwkRegex(_ chars: [Character], openAt open: Int) -> Int {
    var index = open + 1
    var inClass = false
    while index < chars.count {
        let char = chars[index]
        if char == "\\" {
            index += 2
            continue
        }
        if char == "[" { inClass = true }
        if char == "]" { inClass = false }
        if char == "/", inClass == false { return index + 1 }
        index += 1
    }
    return chars.count
}
