import RVTheme

enum RegexKind: Equatable, Sendable {
    case literal
    case meta
    case escape
    case posixName
}

struct RegexSpan: Equatable, Sendable {
    var text: String
    var kind: RegexKind
}

func tokenizeRegex(_ pattern: String) -> [RegexSpan] {
    var spans: [RegexSpan] = []
    var index = pattern.startIndex
    while index < pattern.endIndex {
        if let escape = takeEscape(pattern, at: index) {
            spans.append(RegexSpan(text: escape.text, kind: .escape))
            index = escape.next
            continue
        }
        if let posix = takePosixClass(pattern, at: index) {
            spans.append(contentsOf: posix.spans)
            index = posix.next
            continue
        }
        let character = pattern[index]
        let kind: RegexKind = isRegexMeta(character) ? .meta : .literal
        if let last = spans.last, last.kind == kind, kind == .literal {
            spans[spans.count - 1].text.append(character)
        } else {
            spans.append(RegexSpan(text: String(character), kind: kind))
        }
        index = pattern.index(after: index)
    }
    return spans
}

func paintedRegex(_ pattern: String, palette: Palette) -> String {
    if !palette.colorsEnabled {
        return pattern
    }
    return tokenizeRegex(pattern).map { span in
        paint(span.text, slot: regexSlot(span.kind, palette: palette), reset: palette.reset)
    }.joined()
}

func paintedRegexLines(_ pattern: String, width: Int, palette: Palette) -> [String] {
    let rows = wrapSpans(tokenizeRegex(pattern), width: max(1, width))
    if !palette.colorsEnabled {
        return rows.map { $0.map(\.text).joined() }
    }
    return rows.map { line in
        line.map { span in
            paint(span.text, slot: regexSlot(span.kind, palette: palette), reset: palette.reset)
        }.joined()
    }
}

private func regexSlot(_ kind: RegexKind, palette: Palette) -> String {
    switch kind {
    case .literal:
        return ""
    case .meta:
        return palette.regex.meta
    case .escape:
        return palette.regex.escape
    case .posixName:
        return palette.regex.name
    }
}

private func isRegexMeta(_ character: Character) -> Bool {
    "^$*+?{}()[]|.".contains(character)
}

private func takeEscape(
    _ pattern: String,
    at index: String.Index
) -> (text: String, next: String.Index)? {
    guard pattern[index] == "\\" else { return nil }
    let next = pattern.index(after: index)
    guard next < pattern.endIndex else {
        return (String(pattern[index]), next)
    }
    let end = pattern.index(after: next)
    return (String(pattern[index..<end]), end)
}

private func takePosixClass(
    _ pattern: String,
    at index: String.Index
) -> (spans: [RegexSpan], next: String.Index)? {
    guard pattern[index] == "[" else { return nil }
    let cursor = pattern.index(after: index)
    guard cursor < pattern.endIndex, pattern[cursor] == ":" else { return nil }
    let nameStart = pattern.index(after: cursor)
    var nameEnd = nameStart
    while nameEnd < pattern.endIndex, pattern[nameEnd].isLetter {
        nameEnd = pattern.index(after: nameEnd)
    }
    guard nameEnd > nameStart else { return nil }
    guard nameEnd < pattern.endIndex, pattern[nameEnd] == ":" else { return nil }
    let close = pattern.index(after: nameEnd)
    guard close < pattern.endIndex, pattern[close] == "]" else { return nil }
    let name = String(pattern[nameStart..<nameEnd])
    let next = pattern.index(after: close)
    return (
        [
            RegexSpan(text: "[", kind: .meta),
            RegexSpan(text: ":", kind: .literal),
            RegexSpan(text: name, kind: .posixName),
            RegexSpan(text: ":", kind: .literal),
            RegexSpan(text: "]", kind: .meta),
        ],
        next
    )
}

private func wrapSpans(_ spans: [RegexSpan], width: Int) -> [[RegexSpan]] {
    var lines: [[RegexSpan]] = []
    var current: [RegexSpan] = []
    var used = 0
    for span in spans {
        var rest = span.text[...]
        while !rest.isEmpty {
            if used >= width {
                lines.append(current)
                current = []
                used = 0
            }
            let room = width - used
            if rest.count <= room {
                current.append(RegexSpan(text: String(rest), kind: span.kind))
                used += rest.count
                rest = rest[rest.endIndex...]
            } else {
                let cut = rest.index(rest.startIndex, offsetBy: room)
                current.append(RegexSpan(text: String(rest[..<cut]), kind: span.kind))
                lines.append(current)
                current = []
                used = 0
                rest = rest[cut...]
            }
        }
    }
    if !current.isEmpty {
        lines.append(current)
    }
    return lines.isEmpty ? [[]] : lines
}
