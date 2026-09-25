/// C1 shell-pipeline entry point (T1 seam: tokenizer only).
///
/// Later tickets extend this enum with `parse` (T4) backed by the unwrap
/// (T2) and flag-grammar (T3) stages. `Normalize` keeps its signatures and
/// becomes a thin adapter over this pipeline.
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

        while index < utf8.endIndex {
            var emittedNewline = false
            while index < utf8.endIndex {
                if let width = shellNewlineWidth(utf8, at: index) {
                    if emittedNewline == false {
                        tokens.append(Token(lexeme: "\n", wasQuoted: false))
                        emittedNewline = true
                    }
                    index = utf8.index(index, offsetBy: width)
                    continue
                }
                let width = shellWhitespaceLength(utf8, at: index)
                if width == 0 { break }
                index = utf8.index(index, offsetBy: width)
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
                while index < utf8.endIndex, shellWhitespaceLength(utf8, at: index) == 0 {
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
                    index = shellNextScalarIndex(utf8, index)
                }
                if index > runStart {
                    decoded.append(contentsOf: input[runStart..<index])
                }
            }

            if index > tokenStart {
                tokens.append(Token(lexeme: decoded, wasQuoted: wasQuoted, wasAnsiC: wasAnsiC))
            }
        }
        return tokens
    }
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

private func shellWhitespaceLength(_ utf8: String.UTF8View, at index: String.Index) -> Int {
    let byte = utf8[index]
    if byte < 0x80 {
        switch byte {
        case 9, 10, 11, 12, 13, 32:
            return 1
        default:
            return 0
        }
    }
    guard let (scalar, width) = shellDecodeScalar(utf8, at: index) else { return 0 }
    return Character(scalar).isWhitespace ? width : 0
}

private func shellNextScalarIndex(_ utf8: String.UTF8View, _ index: String.Index) -> String.Index {
    if utf8[index] < 0x80 {
        return utf8.index(after: index)
    }
    guard let (_, width) = shellDecodeScalar(utf8, at: index) else {
        return utf8.index(after: index)
    }
    return utf8.index(index, offsetBy: width, limitedBy: utf8.endIndex) ?? utf8.endIndex
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
