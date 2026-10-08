/// C1 shell-pipeline entry point.
///
/// `parse` is the single entry over the typed stage chain (tokenize ->
/// peel -> unwrap -> parse -> classify); `tokenize` stays public for
/// stage-level use. `Normalize` and `CommandPeelCore` are thin adapters
/// over this pipeline.
public enum ShellPipeline {
    /// Splits `input` into tokens with quoting/ANSI-C provenance.
    ///
    /// Byte-loop behavior matches the legacy `tokenizeCommand` exactly:
    /// whitespace-delimited, quotes concatenate with adjacent runs, `$(...)`
    /// and backticks are captured literally, `$'...'` keeps its `$` marker,
    /// and unquoted newline runs collapse to one `"\n"` token.
    public static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        let utf8 = input.utf8
        var index = utf8.startIndex
        var pendingRedirectTarget = false

        while index < utf8.endIndex {
            var emittedNewline = false
            while index < utf8.endIndex {
                if let width = shellNewlineWidth(utf8, at: index) {
                    if emittedNewline == false {
                        tokens.append(Token(lexeme: "\n", wasQuoted: false))
                        pendingRedirectTarget = false
                        emittedNewline = true
                    }
                    index = utf8.index(index, offsetBy: width, limitedBy: utf8.endIndex) ?? utf8.endIndex
                    continue
                }
                let width = shellWhitespaceLength(utf8, at: index)
                if width == 0 { break }
                index = utf8.index(index, offsetBy: width, limitedBy: utf8.endIndex) ?? utf8.endIndex
            }
            guard index < utf8.endIndex else { break }

            let tokenStart = index
            var decoded = ""
            var wasQuoted = false
            var wasAnsiC = false

            while index < utf8.endIndex, shellWhitespaceLength(utf8, at: index) == 0 {
                let byte = utf8[index]
                if byte == UInt8(ascii: "$"),
                   utf8.index(after: index) < utf8.endIndex,
                   utf8[utf8.index(after: index)] == UInt8(ascii: "(")
                {
                    let start = index
                    index = utf8.index(after: utf8.index(after: index))
                    var depth = 1
                    while index < utf8.endIndex, depth > 0 {
                        let current = utf8[index]
                        if current == UInt8(ascii: "(") { depth += 1 }
                        else if current == UInt8(ascii: ")") { depth -= 1 }
                        utf8.formIndex(after: &index)
                    }
                    decoded.append(contentsOf: input[start..<index])
                    continue
                }
                if byte == UInt8(ascii: "$"),
                   utf8.index(after: index) < utf8.endIndex,
                   utf8[utf8.index(after: index)] == UInt8(ascii: "'")
                {
                    wasQuoted = true
                    wasAnsiC = true
                    utf8.formIndex(after: &index)
                    utf8.formIndex(after: &index)
                    let innerStart = index
                    while index < utf8.endIndex, utf8[index] != UInt8(ascii: "'") {
                        utf8.formIndex(after: &index)
                    }
                    decoded.append("$")
                    decoded.append(contentsOf: input[innerStart..<index])
                    if index < utf8.endIndex {
                        utf8.formIndex(after: &index)
                    }
                    continue
                }
                if byte == UInt8(ascii: "`") {
                    let start = index
                    utf8.formIndex(after: &index)
                    while index < utf8.endIndex, utf8[index] != UInt8(ascii: "`") {
                        utf8.formIndex(after: &index)
                    }
                    if index < utf8.endIndex {
                        utf8.formIndex(after: &index)
                    }
                    decoded.append(contentsOf: input[start..<index])
                    continue
                }
                if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                    wasQuoted = true
                    utf8.formIndex(after: &index)
                    let innerStart = index
                    while index < utf8.endIndex, utf8[index] != byte {
                        utf8.formIndex(after: &index)
                    }
                    decoded.append(contentsOf: input[innerStart..<index])
                    if index < utf8.endIndex {
                        utf8.formIndex(after: &index)
                    }
                    continue
                }
                let runStart = index
                while index < utf8.endIndex {
                    let step = shellScalarStep(utf8, at: index)
                    if step.isWhitespace { break }
                    let current = utf8[index]
                    if current == UInt8(ascii: "`")
                        || current == UInt8(ascii: "\"")
                        || current == UInt8(ascii: "'")
                    {
                        break
                    }
                    if current == UInt8(ascii: "$"),
                       utf8.index(after: index) < utf8.endIndex
                    {
                        let next = utf8[utf8.index(after: index)]
                        if next == UInt8(ascii: "(") || next == UInt8(ascii: "'") {
                            break
                        }
                    }
                    index = utf8.index(index, offsetBy: step.width, limitedBy: utf8.endIndex) ?? utf8.endIndex
                }
                if index > runStart {
                    decoded.append(contentsOf: input[runStart..<index])
                }
            }

            if index > tokenStart {
                let rawWord = input[tokenStart..<index]
                let structural = pendingRedirectTarget || rawWordCarriesUnquotedRedirectOut(rawWord)
                pendingRedirectTarget = isBareRedirectOutWord(rawWord)
                tokens.append(Token(lexeme: decoded, wasQuoted: wasQuoted, wasAnsiC: wasAnsiC, isRedirectStructural: structural))
            }
        }
        return tokens
    }
}

/// True when the raw word holds an unquoted `>` outside any single-,
/// double-, or ANSI-C-quoted span, with backslash escapes skipped. Mirrors
/// `splitRedirectPieces`: every such `>` becomes a claimed write-redirect
/// downstream (`>`, `>>`, `>|`, `>&`, `<>`, `&>`, fd-prefixed), so the word
/// is redirect structure even when quoting elsewhere in the word sets
/// `wasQuoted` (`hi>"/tmp/eve"`). Fully quoted `>` data (`"a>b"`,
/// `$'a>b'`, `a\>b`) returns false and stays maskable.
private func rawWordCarriesUnquotedRedirectOut(_ raw: Substring) -> Bool {
    let chars = Array(raw)
    var index = 0
    var singleQuoted = false
    var doubleQuoted = false
    while index < chars.count {
        let current = chars[index]
        if singleQuoted {
            if current == "'" { singleQuoted = false }
            index += 1
            continue
        }
        if doubleQuoted {
            if current == "\\" { index += 2; continue }
            if current == "\"" { doubleQuoted = false }
            index += 1
            continue
        }
        if current == "'" { singleQuoted = true; index += 1; continue }
        if current == "\"" { doubleQuoted = true; index += 1; continue }
        if current == "\\" { index += 2; continue }
        if current == "$", index + 1 < chars.count, chars[index + 1] == "'" {
            index += 2
            while index < chars.count, chars[index] != "'" {
                index += chars[index] == "\\" ? 2 : 1
            }
            index += 1
            continue
        }
        if current == ">" { return true }
        index += 1
    }
    return false
}

/// True when the raw word is exactly one unquoted redirect-out operator
/// whose file target is the next word: `>`, `>>`, `>|`, `>&`, `<>`,
/// `&>`, `&>>`, each with optional fd digits (`2>`, `10>>`, `2>&`).
/// Dup/close gluings (`>&2`, `2>&1`), quoted words, dynamic words, and
/// input-only words (`<`, `<<`, `<&`) never match: no file target follows.
private func isBareRedirectOutWord(_ raw: Substring) -> Bool {
    if raw.contains("'") || raw.contains("\"") || raw.contains("\\")
        || raw.contains("$") || raw.contains("`")
    {
        return false
    }
    var word = String(raw)
    if word.hasPrefix("&") {
        return word == "&>" || word == "&>>"
    }
    while let first = word.first, first.isASCII, first.isNumber {
        word.removeFirst()
    }
    return word == ">" || word == ">>" || word == ">|" || word == ">&" || word == "<>"
}

/// Unquoted `\n` / `\r\n` / `\r` width. Quoted newlines stay inside the token.
private func shellNewlineWidth(_ utf8: String.UTF8View, at index: String.Index) -> Int? {
    guard index < utf8.endIndex else { return nil }
    let byte = utf8[index]
    if byte == UInt8(ascii: "\n") { return 1 }
    if byte == UInt8(ascii: "\r") {
        let next = utf8.index(after: index)
        if next < utf8.endIndex, utf8[next] == UInt8(ascii: "\n") {
            return 2
        }
        return 1
    }
    return nil
}

/// Width of the whitespace run starting at `index`, or 0 when the scalar
/// there is not whitespace.
/// - Precondition: `index < utf8.endIndex`.
private func shellWhitespaceLength(_ utf8: String.UTF8View, at index: String.Index) -> Int {
    let step = shellScalarStep(utf8, at: index)
    return step.isWhitespace ? step.width : 0
}

/// Width and whitespace-ness of the scalar starting at `index`, decoded
/// once. ASCII bytes never decode.
/// - Precondition: `index < utf8.endIndex`.
private func shellScalarStep(_ utf8: String.UTF8View, at index: String.Index) -> (width: Int, isWhitespace: Bool) {
    let byte = utf8[index]
    if byte < 0x80 {
        switch byte {
        case 9, 10, 11, 12, 13, 32:
            return (1, true)
        default:
            return (1, false)
        }
    }
    guard let (scalar, width) = shellDecodeScalar(utf8, at: index) else { return (1, false) }
    return (width, scalar.properties.isWhitespace)
}

private func shellDecodeScalar(
    _ utf8: String.UTF8View,
    at index: String.Index
) -> (Unicode.Scalar, Int)? {
    var iterator = utf8[index...].makeIterator()
    var decoder = UTF8()
    switch decoder.decode(&iterator) {
    case .scalarValue(let scalar):
        return (scalar, shellUTF8Width(scalar))
    case .emptyInput, .error:
        return nil
    }
}

private func shellUTF8Width(_ scalar: Unicode.Scalar) -> Int {
    switch scalar.value {
    case 0..<0x80:
        return 1
    case 0x80..<0x800:
        return 2
    case 0x800..<0x1_0000:
        return 3
    default:
        return 4
    }
}
