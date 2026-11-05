import Foundation
import RVDomain

// Part of the single recursive unwrap; see `Unwrap.swift` for the
// recursion, budget, and `peelAfterSink` dispatch.

// MARK: - Top-level pipe and heredoc scanning

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
    var quote: Character?
    var parenDepth = 0
    var inBacktick = false
    var index = text.startIndex

    while index < text.endIndex {
        let character = text[index]
        let next = text.index(after: index)
        if let currentQuote = quote {
            if character == currentQuote {
                quote = nil
            }
            index = next
            continue
        }
        if inBacktick {
            if character == "`" {
                inBacktick = false
            }
            index = next
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
        if parenDepth == 0, character == "<", next < text.endIndex, text[next] == "<" {
            let afterTwo = text.index(after: next)
            if afterTwo < text.endIndex, text[afterTwo] == "<" {
                index = text.index(after: afterTwo)
                continue
            }
            if let parsed = parseHeredoc(in: text, afterOperator: afterTwo) {
                return parsed
            }
            index = afterTwo
            continue
        }
        index = next
    }
    return nil
}

private func parseHeredoc(
    in text: String,
    afterOperator: String.Index
) -> (header: String, body: String)? {
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
    if text[cursor] == "'" || text[cursor] == "\"" {
        let quote = text[cursor]
        cursor = text.index(after: cursor)
        let start = cursor
        while cursor < text.endIndex, text[cursor] != quote {
            cursor = text.index(after: cursor)
        }
        delimiter = String(text[start..<cursor])
        if cursor < text.endIndex {
            cursor = text.index(after: cursor)
        }
    } else {
        let start = cursor
        while cursor < text.endIndex {
            let character = text[cursor]
            if character.isWhitespace || character == "|" || character == "<"
                || character == ">" || character == ";" || character == "&"
                || character == "(" || character == ")"
            {
                break
            }
            cursor = text.index(after: cursor)
        }
        delimiter = String(text[start..<cursor])
    }
    if delimiter.isEmpty { return nil }

    var lineEnd = cursor
    while lineEnd < text.endIndex, text[lineEnd] != "\n" {
        lineEnd = text.index(after: lineEnd)
    }
    guard lineEnd < text.endIndex else { return nil }
    let header = String(text[text.startIndex..<lineEnd])
    let bodyStart = text.index(after: lineEnd)
    let body = heredocBody(
        String(text[bodyStart...]),
        delimiter: delimiter,
        stripTabs: stripTabs
    )
    return (header, body)
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
