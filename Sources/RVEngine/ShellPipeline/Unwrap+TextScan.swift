import Foundation
import RVDomain

// Part of the single recursive unwrap; see `Unwrap.swift` for the
// recursion, budget, and `peel` dispatch.

func splitTopLevelPipes(_ text: String) -> [String] {
    var segments: [String] = []
    var current = ""
    var quote: Character?
    var parenDepth = 0
    var inBacktick = false
    var index = text.startIndex

    func flush() {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false {
            segments.append(trimmed)
        }
        current = ""
    }

    while index < text.endIndex {
        let character = text[index]
        let next = text.index(after: index)
        if let currentQuote = quote {
            current.append(character)
            if character == currentQuote {
                quote = nil
            }
            index = next
            continue
        }
        if inBacktick {
            current.append(character)
            if character == "`" {
                inBacktick = false
            }
            index = next
            continue
        }
        if character == "'" || character == "\"" {
            quote = character
            current.append(character)
            index = next
            continue
        }
        if character == "`" {
            inBacktick = true
            current.append(character)
            index = next
            continue
        }
        if (character == "<" || character == ">" || character == "$"),
            next < text.endIndex, text[next] == "("
        {
            parenDepth += 1
            current.append(character)
            current.append("(")
            index = text.index(after: next)
            continue
        }
        if character == "(" {
            parenDepth += 1
            current.append(character)
            index = next
            continue
        }
        if character == ")" {
            if parenDepth > 0 {
                parenDepth -= 1
            }
            current.append(character)
            index = next
            continue
        }
        if parenDepth == 0, character == "|" {
            if next < text.endIndex, text[next] == "|" {
                current.append(character)
                current.append("|")
                index = text.index(after: next)
                continue
            }
            flush()
            index = next
            continue
        }
        current.append(character)
        index = next
    }
    flush()
    return segments
}

func extractHeredoc(_ text: String) -> (header: String, body: String)? {
    locateHeredoc(text).map { ($0.header, $0.body) }
}

/// The first top-level heredoc: its header, trimmed body, and where that
/// body sits in `text`.
struct HeredocMatch {
    let header: String
    let body: String
    /// The trimmed body's range in the scanned text, its lines split on LF
    /// as bash splits them. Nil when the body's position is ambiguous: no
    /// terminator line, a CR on the header line or a CR-only terminator, a
    /// delimiter word bash reads differently (partly quoted, escaped), an
    /// escape, `#`, ANSI-C quote, open `${`/`$[` or earlier `<<` before the
    /// operator, or a header line that holds another heredoc or spills
    /// quoting or a substitution past its end.
    let bodyRange: Range<String.Index>?
}

func locateHeredoc(_ text: String) -> HeredocMatch? {
    var quote: Character?
    var parenDepth = 0
    var inBacktick = false
    // Ambiguity never changes which operator is chosen; it only withholds
    // the body's position. Set by an escape that can hide a quote or the
    // operator, a `#` that can start a comment, an ANSI-C quote, an open
    // `${`/`$[` expansion, or an earlier `<<` in any context: its body may
    // hold the quotes or parens this scan miscounts.
    var ambiguousPrefix = false
    var openExpansions: [Character] = []
    var index = text.startIndex

    while index < text.endIndex {
        let character = text[index]
        let next = text.index(after: index)
        let following = next < text.endIndex ? text[next] : nil
        if let currentQuote = quote {
            // Inside double quotes only `\"` can move the closing quote: a
            // `\\` run that ends at a quote ends in `\"` too.
            if currentQuote == "\"", character == "\\", following == "\"" {
                ambiguousPrefix = true
            }
            // A substitution inside double quotes nests its own quotes,
            // which this scan would read as closing the outer one.
            if currentQuote == "\"", character == "`" || (character == "$" && following == "(") {
                ambiguousPrefix = true
            }
            if isHeredocOperator(in: text, at: index) {
                ambiguousPrefix = true
            }
            if character == currentQuote {
                quote = nil
            }
            index = next
            continue
        }
        if inBacktick {
            if character == "\\" || isHeredocOperator(in: text, at: index) {
                ambiguousPrefix = true
            }
            if character == "`" {
                inBacktick = false
            }
            index = next
            continue
        }
        if character == "\\" {
            // `\<newline>` is a line continuation; any other escape can
            // hide a quote or the operator itself.
            if following != "\n" {
                ambiguousPrefix = true
            }
            index = following == "\n" ? text.index(after: next) : next
            continue
        }
        if character == "'" || character == "\"" {
            quote = character
            index = next
            continue
        }
        if character == "`" {
            inBacktick = true
            index = next
            continue
        }
        if character == "#" || (character == "$" && following == "'") {
            ambiguousPrefix = true
        }
        if character == "$", following == "{" || following == "[" {
            openExpansions.append(following == "{" ? "}" : "]")
            index = text.index(after: next)
            continue
        }
        // zsh counts nested braces inside `${…}`; this scan does not.
        if character == "{", openExpansions.isEmpty == false {
            ambiguousPrefix = true
        }
        if character == openExpansions.last {
            openExpansions.removeLast()
        }
        if (character == "<" || character == ">" || character == "$"),
            next < text.endIndex, text[next] == "("
        {
            parenDepth += 1
            index = text.index(after: next)
            continue
        }
        if character == "(" {
            parenDepth += 1
            index = next
            continue
        }
        if character == ")" {
            if parenDepth > 0 {
                parenDepth -= 1
            }
            index = next
            continue
        }
        if parenDepth > 0, isHeredocOperator(in: text, at: index) {
            ambiguousPrefix = true
        }
        if parenDepth == 0, character == "<", next < text.endIndex, text[next] == "<" {
            let afterTwo = text.index(after: next)
            if afterTwo < text.endIndex, text[afterTwo] == "<" {
                index = text.index(after: afterTwo)
                continue
            }
            if let parsed = parseHeredoc(in: text, operatorStart: index, afterOperator: afterTwo) {
                guard ambiguousPrefix == false, openExpansions.isEmpty else {
                    return HeredocMatch(header: parsed.header, body: parsed.body, bodyRange: nil)
                }
                return parsed
            }
            ambiguousPrefix = true
            index = afterTwo
            continue
        }
        index = next
    }
    return nil
}

/// A `<<` that is not part of a `<<<` here-string.
private func isHeredocOperator(in text: String, at index: String.Index) -> Bool {
    guard text[index] == "<" else { return false }
    let next = text.index(after: index)
    guard next < text.endIndex, text[next] == "<" else { return false }
    let afterTwo = text.index(after: next)
    if afterTwo < text.endIndex, text[afterTwo] == "<" { return false }
    return index == text.startIndex || text[text.index(before: index)] != "<"
}

private func parseHeredoc(
    in text: String,
    operatorStart: String.Index,
    afterOperator: String.Index
) -> HeredocMatch? {
    var cursor = afterOperator
    var stripTabs = false
    if cursor < text.endIndex, text[cursor] == "-" {
        stripTabs = true
        cursor = text.index(after: cursor)
    }
    while cursor < text.endIndex, text[cursor].isWhitespace, text[cursor] != "\n" {
        cursor = text.index(after: cursor)
    }
    guard cursor < text.endIndex, text[cursor] != "\n" else { return nil }

    let delimiter: String
    // Bash strips quotes and backslashes from the whole delimiter word;
    // this parser reads one quoted span or one bare word. Only words both
    // read the same way may place the body.
    var delimiterIsPlain: Bool
    if text[cursor] == "'" || text[cursor] == "\"" {
        let quote = text[cursor]
        cursor = text.index(after: cursor)
        let start = cursor
        while cursor < text.endIndex, text[cursor] != quote {
            cursor = text.index(after: cursor)
        }
        delimiter = String(text[start..<cursor])
        delimiterIsPlain = cursor < text.endIndex
        if cursor < text.endIndex {
            cursor = text.index(after: cursor)
        }
        if cursor < text.endIndex, isHeredocWordBoundary(text[cursor]) == false {
            delimiterIsPlain = false
        }
    } else {
        let start = cursor
        while cursor < text.endIndex {
            let character = text[cursor]
            if isHeredocWordBoundary(character) {
                break
            }
            cursor = text.index(after: cursor)
        }
        delimiter = String(text[start..<cursor])
        delimiterIsPlain = true
    }
    if delimiter.isEmpty { return nil }
    if delimiter.unicodeScalars.contains(where: { "'\"\\`$\n\r".unicodeScalars.contains($0) }) {
        delimiterIsPlain = false
    }

    var lineEnd = cursor
    while lineEnd < text.endIndex, text[lineEnd] != "\n" {
        lineEnd = text.index(after: lineEnd)
    }
    guard lineEnd < text.endIndex else { return nil }
    let header = String(text[text.startIndex..<lineEnd])
    let bodyStart = text.index(after: lineEnd)
    let body = heredocBody(String(text[bodyStart...]), delimiter: delimiter, stripTabs: stripTabs)
    let placeable = delimiterIsPlain
        && headerLineEndsCleanly(text, operatorStart: operatorStart, from: cursor, to: lineEnd)
    let bodyRange = placeable
        ? placeBody(in: text, from: bodyStart, delimiter: delimiter, stripTabs: stripTabs)
        : nil
    return HeredocMatch(header: header, body: body, bodyRange: bodyRange)
}

private func isHeredocWordBoundary(_ character: Character) -> Bool {
    character.isWhitespace || character == "|" || character == "<"
        || character == ">" || character == ";" || character == "&"
        || character == "(" || character == ")"
}

/// True when the header line holds no carriage return and no second
/// heredoc operator and, after the delimiter, nothing that could carry the
/// line past its newline: an open quote, a backslash outside single
/// quotes, a backtick, or a paren.
private func headerLineEndsCleanly(
    _ text: String,
    operatorStart: String.Index,
    from delimiterEnd: String.Index,
    to lineEnd: String.Index
) -> Bool {
    let lineStart = text[..<operatorStart].lastIndex(of: "\n").map { text.index(after: $0) }
        ?? text.startIndex
    let line = String(text[lineStart..<lineEnd])
    if line.unicodeScalars.contains("\r") { return false }
    if line.replacingOccurrences(of: "<<<", with: "").components(separatedBy: "<<").count > 2 {
        return false
    }
    var quote: Character?
    for character in text[delimiterEnd..<lineEnd] {
        if let open = quote {
            if open == "\"", character == "\\" { return false }
            if character == open { quote = nil }
            continue
        }
        if character == "'" || character == "\"" {
            quote = character
        } else if "\\`()".contains(character) {
            return false
        }
    }
    return quote == nil
}

/// The trimmed body's range, found the way bash finds it: lines split on
/// LF alone (a CR stays part of its line), ending at the first line equal
/// to the delimiter. Nil without a terminator line, when a line matches the
/// delimiter only once its CRs are dropped, or when the trimmed bounds are
/// not Character boundaries.
private func placeBody(
    in text: String,
    from bodyStart: String.Index,
    delimiter: String,
    stripTabs: Bool
) -> Range<String.Index>? {
    let scalars = text.unicodeScalars
    var lineStart = bodyStart
    var terminatorStart: String.Index?
    while lineStart < scalars.endIndex {
        let lineEnd = scalars[lineStart...].firstIndex(of: "\n") ?? scalars.endIndex
        let line = String(String.UnicodeScalarView(scalars[lineStart..<lineEnd]))
        let compared = stripTabs ? String(line.drop(while: { $0 == "\t" })) : line
        if compared == delimiter {
            terminatorStart = lineStart
            break
        }
        // `EOF\r` ends the body for a shell that drops CRs, not for bash.
        if compared.replacingOccurrences(of: "\r", with: "") == delimiter { return nil }
        guard lineEnd < scalars.endIndex else { break }
        lineStart = scalars.index(after: lineEnd)
    }
    guard let terminatorStart else { return nil }
    let raw = scalars[bodyStart..<terminatorStart]
    guard let first = raw.firstIndex(where: { $0.properties.isWhitespace == false }),
        let last = raw.lastIndex(where: { $0.properties.isWhitespace == false })
    else { return nil }
    let end = scalars.index(after: last)
    guard first.samePosition(in: text) != nil, end.samePosition(in: text) != nil else { return nil }
    return first..<end
}

private func heredocBody(_ rest: String, delimiter: String, stripTabs: Bool) -> String {
    var lines: [String] = []
    var remaining = rest[...]
    while remaining.isEmpty == false {
        let line: Substring
        if let newline = remaining.firstIndex(of: "\n") {
            line = remaining[..<newline]
            remaining = remaining[remaining.index(after: newline)...]
        } else {
            line = remaining
            remaining = remaining[remaining.endIndex...]
        }
        let compared = stripTabs ? String(line.drop(while: { $0 == "\t" })) : String(line)
        if compared == delimiter {
            break
        }
        lines.append(String(line))
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}
