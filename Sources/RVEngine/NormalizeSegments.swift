import Foundation

/// File-write / print heredocs are data. Executing sinks keep the body so
/// `cat <<EOF | bash` stays a pin true-positive.
func maskNonExecutingHeredocBodies(_ text: String) -> String {
    guard let heredoc = extractHeredoc(text), heredoc.body.isEmpty == false else {
        return text
    }
    if peelExecutingSink(text, workingDirectory: nil) != nil {
        return text
    }
    guard let range = text.range(of: heredoc.body) else {
        return text
    }
    return text.replacingCharacters(
        in: range,
        with: String(repeating: " ", count: heredoc.body.count)
    )
}

/// Splits shell text into executable segments. Separators: `&&`, `||`,
/// `;`, `|`, newline, and single `&` (background). Grouping
/// (`(...)`, `{...}`) is peeled and re-split; `$(...)`/backtick inners
/// are emitted as extra segments (they execute). Step 8B §24: a benign
/// prefix must not hide a risky later segment.
func splitSegments(_ text: String) -> [String] {
    expandSegment(text, depth: 0)
}

/// Tokenizes for the filesystem parsers, splitting mid-word redirect
/// operators quoting-aware: `b>/tmp/x` → `["b", ">", "/tmp/x"]`, `a2>>b` →
/// `["a", "2>>", "b"]`. Without this, attached redirects hide their target in an
/// operand (`echo hi>/tmp/x` evaluated as no-action). Only unquoted,
/// non-ANSI-C, non-dynamic tokens split: quoted metachars are literal
/// (`"a>b"` stays one word), and dynamic words belong to the analyze-layer
/// guards. Git call sites do not use this: an attached redirect in git
/// position already fails closed via `.pushUnparsed` / unknown subcommands.
func tokenizeFilesystemWords(_ text: String) -> [String] {
    splitMidWordRedirects(tokenizeCommand(text)).map(\.decoded)
}

/// Splits unquoted tokens at redirect-operator boundaries into alternating
/// word/operator pieces: `b>/tmp/x` → `["b", ">", "/tmp/x"]`, `a2>>b` →
/// `["a", "2>>", "b"]`. Operator pieces carry their fd digits so they read
/// exactly like the separate form; dup/close targets stay glued to their
/// operator (`2>&1` never splits, so the `1` cannot pollute operands).
func splitMidWordRedirects(_ tokens: [CommandToken]) -> [CommandToken] {
    tokens.flatMap { token -> [CommandToken] in
        guard token.wasQuoted == false, token.wasAnsiC == false,
            carriesSubstitution(token.decoded) == false,
            token.decoded.contains("$") == false
        else {
            return [token]
        }
        return splitRedirectPieces(token.decoded).map {
            CommandToken(decoded: $0, wasQuoted: false)
        }
    }
}

private func splitRedirectPieces(_ word: String) -> [String] {
    let chars = Array(word)
    var pieces: [String] = []
    var index = 0
    var wordStart = 0
    while index < chars.count {
        if chars[index] == "\\" {
            index += 2
            continue
        }
        if chars[index] == ">" || chars[index] == "<" {
            let runEnd = redirectRunEnd(chars, from: index)
            // A digit run immediately before the operator is its fd (`a2>b`
            // redirects fd 2, word `a`), maximal like the shell's own read.
            var fdStart = index
            while fdStart > wordStart, chars[fdStart - 1].isASCII, chars[fdStart - 1].isNumber {
                fdStart -= 1
            }
            if wordStart < fdStart {
                pieces.append(String(chars[wordStart..<fdStart]))
            }
            pieces.append(String(chars[fdStart..<runEnd]))
            index = runEnd
            wordStart = runEnd
            continue
        }
        index += 1
    }
    if wordStart < chars.count {
        pieces.append(String(chars[wordStart...]))
    }
    return pieces.isEmpty ? [word] : pieces
}

/// End index of the redirect operator run starting at `from`: `>>`, `>|`,
/// `>&`, `<<`, `<<<`, `<<-`, `<>`, `<&`, each with its fd glued on the left
/// by the caller and dup/close targets (`>&1`, `<&-`) glued on the right.
private func redirectRunEnd(_ chars: [Character], from: Int) -> Int {
    var runEnd = from + 1
    guard runEnd < chars.count else {
        return runEnd
    }
    let next = chars[runEnd]
    if chars[from] == ">", next == ">" || next == "|" || next == "&" {
        runEnd += 1
    } else if chars[from] == "<", next == "<" || next == ">" || next == "&" {
        runEnd += 1
        if next == "<", runEnd < chars.count {
            if chars[runEnd] == "<" || chars[runEnd] == "-" {
                runEnd += 1
            }
        }
    }
    if runEnd - from == 2,
        (chars[from] == ">" || chars[from] == "<"), chars[from + 1] == "&"
    {
        // Dup/close targets glue only to end of token: `>&1` is a dup, but
        // `>&1b` duplicates to the FILE `1b`, so the `1b` must split off.
        var digitsEnd = runEnd
        while digitsEnd < chars.count, chars[digitsEnd].isASCII, chars[digitsEnd].isNumber {
            digitsEnd += 1
        }
        if digitsEnd == chars.count {
            return digitsEnd
        }
        if digitsEnd == runEnd, digitsEnd < chars.count, chars[digitsEnd] == "-",
            digitsEnd + 1 == chars.count
        {
            return digitsEnd + 1
        }
    }
    return runEnd
}

/// The single effective segment, or nil when the view holds more than one
/// executing segment. Peeling applies, so `(git push …)` classifies as its
/// inner command. Multi-segment input stays unknown here; the apply stage
/// parses each segment separately (Step 8B §24).
func singleEffectiveSegment(_ text: String) -> String? {
    let segments = splitSegments(text)
    guard segments.count <= 1 else { return nil }
    let single = segments.first ?? text
    let stripped = ShellPipeline.stripLeadingAssignmentPrefixes(single)
    guard stripped != single else {
        return single
    }
    // The rewrite can insert a separator (`X=$(:) cmd` → `$(:) ; cmd`);
    // resplit so a newly multi-segment view stays unknown here while the
    // apply stage parses each piece separately.
    let resplit = splitSegments(stripped)
    guard resplit.count <= 1 else { return nil }
    return resplit.first ?? stripped
}

/// Bounded recursion over grouping/substitution. Every recursion strictly
/// shortens its input; the depth cap is a backstop.
private let maxSegmentDepth = 8

private func expandSegment(_ text: String, depth: Int) -> [String] {
    let pieces = splitTopLevel(text)
    guard depth < maxSegmentDepth else { return pieces }
    var out: [String] = []
    out.reserveCapacity(pieces.count * 2)
    for piece in pieces {
        if let peeled = peelGrouping(piece) {
            out.append(contentsOf: expandSegment(peeled, depth: depth + 1))
        } else {
            out.append(piece)
            for inner in substitutionInners(piece) {
                out.append(contentsOf: expandSegment(inner, depth: depth + 1))
            }
        }
    }
    return out
}

private func splitTopLevel(_ text: String) -> [String] {
    splitTopLevelEvents(text).parts.map(\.piece)
}

/// One top-level piece plus the exact gap text following it (separator plus
/// surrounding blank runs). The last gap carries the trailing remainder, so
/// pieces and gaps rejoin to the input byte-for-byte.
private struct TopLevelPiece {
    var piece: String
    var gap: String
}

/// Shared top-level scanner. `splitTopLevel` keeps the pieces;
/// `mapTopLevelPieces` rewrites them while preserving every gap byte, so
/// pack patterns anchored on separators cannot observe the rewrite.
private func splitTopLevelEvents(_ text: String) -> (prefix: String, parts: [TopLevelPiece]) {
    var bounds: [(piece: String, start: String.Index, end: String.Index)] = []
    let utf8 = text.utf8
    var index = utf8.startIndex
    var segmentStart = index
    var quote: UInt8?
    var depth = 0

    func flush(upTo end: String.Index) {
        // Trim bounds must match `trimmingCharacters(in: .whitespaces)`
        // exactly (space/tab plus exotic unicode spaces, never newlines —
        // newlines always flush, quoted or trailing alike).
        let trimmed = text[segmentStart..<end].trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var contentStart = segmentStart
        while contentStart < end,
            text[contentStart].unicodeScalars.allSatisfy(CharacterSet.whitespaces.contains)
        {
            text.formIndex(after: &contentStart)
        }
        var contentEnd = end
        while contentEnd > contentStart,
            text[text.index(before: contentEnd)].unicodeScalars.allSatisfy(CharacterSet.whitespaces.contains)
        {
            contentEnd = text.index(before: contentEnd)
        }
        bounds.append((String(text[contentStart..<contentEnd]), contentStart, contentEnd))
    }

    while index < utf8.endIndex {
        let byte = utf8[index]
        if let currentQuote = quote {
            if byte == currentQuote { quote = nil }
            utf8.formIndex(after: &index)
            continue
        }
        if byte == UInt8(ascii: "'") || byte == UInt8(ascii: "\"") {
            quote = byte
            utf8.formIndex(after: &index)
            continue
        }
        if byte == UInt8(ascii: "(") || byte == UInt8(ascii: "{") {
            if isGroupOpener(utf8, at: index, segmentStart: segmentStart) {
                depth += 1
            }
            utf8.formIndex(after: &index)
            continue
        }
        if byte == UInt8(ascii: ")") || byte == UInt8(ascii: "}") {
            depth = max(0, depth - 1)
            utf8.formIndex(after: &index)
            continue
        }
        if depth == 0 {
            if byte == UInt8(ascii: "&"),
               utf8.index(after: index) < utf8.endIndex,
               utf8[utf8.index(after: index)] == UInt8(ascii: "&")
            {
                flush(upTo: index)
                index = utf8.index(after: utf8.index(after: index))
                segmentStart = index
                continue
            }
            if byte == UInt8(ascii: "|"),
               utf8.index(after: index) < utf8.endIndex,
               utf8[utf8.index(after: index)] == UInt8(ascii: "|")
            {
                flush(upTo: index)
                index = utf8.index(after: utf8.index(after: index))
                segmentStart = index
                continue
            }
            // A `|` glued to `>` is the `>|` noclobber redirect, not a pipe:
            // splitting here shredded `echo a >|/tmp/x` and dropped the
            // redirect (Lens C F1). `||` after `>` keeps splitting above:
            // `>||` is a shell syntax error, and evaluating the tail
            // standalone is fail-closed.
            if byte == UInt8(ascii: ";")
                || (byte == UInt8(ascii: "|") && !pipeIsRedirectBar(utf8, at: index))
            {
                flush(upTo: index)
                utf8.formIndex(after: &index)
                segmentStart = index
                continue
            }
            if byte == UInt8(ascii: "&"), isBackgroundAmpersand(utf8, at: index) {
                flush(upTo: index)
                utf8.formIndex(after: &index)
                segmentStart = index
                continue
            }
            if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                flush(upTo: index)
                utf8.formIndex(after: &index)
                if byte == UInt8(ascii: "\r"),
                   index < utf8.endIndex,
                   utf8[index] == UInt8(ascii: "\n")
                {
                    utf8.formIndex(after: &index)
                }
                segmentStart = index
                continue
            }
        }
        index = nextScalarIndex(utf8, index)
    }
    flush(upTo: utf8.endIndex)
    // Prefix, pieces, and gaps partition the input exactly: the first
    // piece's start bounds the leading prefix, consecutive bounds bound
    // each gap, and the last gap carries the trailing remainder.
    let prefix = bounds.isEmpty ? text : String(text[..<bounds[0].start])
    var parts: [TopLevelPiece] = []
    parts.reserveCapacity(bounds.count)
    for (position, bound) in bounds.enumerated() {
        let gap: String
        if position + 1 < bounds.count {
            gap = String(text[bound.end..<bounds[position + 1].start])
        } else {
            gap = String(text[bound.end...])
        }
        parts.append(TopLevelPiece(piece: bound.piece, gap: gap))
    }
    return (prefix, parts)
}

/// Rewrites each top-level piece with `transform`, preserving the prefix and
/// every gap byte (separators plus surrounding blank runs). With the
/// identity transform the output equals the input byte-for-byte, so pack
/// patterns anchored on separators cannot observe the rewrite. Internal for
/// the rejoin tests.
func mapTopLevelPieces(_ text: String, transform: (String) -> String) -> String {
    let events = splitTopLevelEvents(text)
    guard !events.parts.isEmpty else { return text }
    var out = events.prefix
    for part in events.parts {
        out += transform(part.piece)
        out += part.gap
    }
    return out
}

/// True when the `|` at `index` is the bar of a `>|` redirect: immediately
/// preceded by `>`. A quoted `>` cannot sit there — the quote arm consumes
/// quoted bars before this check runs — so the preceding `>` is structural.
private func pipeIsRedirectBar(_ utf8: String.UTF8View, at index: String.Index) -> Bool {
    guard index != utf8.startIndex else { return false }
    return utf8[utf8.index(before: index)] == UInt8(ascii: ">")
}

/// Single `&` separates (background) unless it is part of `&&` or a
/// redirect (`>&`, `&>`, `<&`, `&>>`). Callers check `&&` first.
private func isBackgroundAmpersand(
    _ utf8: String.UTF8View,
    at index: String.Index
) -> Bool {
    let redirectAdjacent: Set<UInt8> = [
        UInt8(ascii: "&"), UInt8(ascii: ">"), UInt8(ascii: "<"),
    ]
    if index != utf8.startIndex {
        let prev = utf8.index(before: index)
        if redirectAdjacent.contains(utf8[prev]) {
            return false
        }
    }
    let next = utf8.index(after: index)
    if next < utf8.endIndex, redirectAdjacent.contains(utf8[next]) {
        return false
    }
    return true
}

/// True when a group opener is shell-structural: at a command position
/// (segment start or after a separator) or `$(`. Mid-word parens/braces
/// (`echo a(b)c`, `${x}`, `FOO={a}`) are literal and add no depth, so a
/// later operator still splits exactly as before.
private func isGroupOpener(
    _ utf8: String.UTF8View,
    at index: String.Index,
    segmentStart: String.Index
) -> Bool {
    if utf8[index] == UInt8(ascii: "("), index != utf8.startIndex,
        utf8[utf8.index(before: index)] == UInt8(ascii: "$")
    {
        return true
    }
    var cursor = index
    while cursor != segmentStart {
        let prev = utf8.index(before: cursor)
        let byte = utf8[prev]
        if byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") {
            cursor = prev
            continue
        }
        return byte == UInt8(ascii: ";") || byte == UInt8(ascii: "&")
            || byte == UInt8(ascii: "|") || byte == UInt8(ascii: "(")
            || byte == UInt8(ascii: "{") || byte == UInt8(ascii: "\n")
            || byte == UInt8(ascii: "\r")
    }
    return true
}

/// Strips one layer of fully-wrapping `(...)`/`{...}` grouping.
/// Quote-aware; unbalanced or non-wrapping text returns nil. Mismatched
/// closers peel too — the shell errors on those, so evaluating the
/// inner text can only fail closed or allow a broken command.
private func peelGrouping(_ segment: String) -> String? {
    let trimmed = segment.trimmingCharacters(in: .whitespaces)
    guard let first = trimmed.first, first == "(" || first == "{" else {
        return nil
    }
    var depth = 0
    var quote: Character?
    var index = trimmed.startIndex
    while index < trimmed.endIndex {
        let char = trimmed[index]
        if let currentQuote = quote {
            if char == currentQuote { quote = nil }
        } else if char == "'" || char == "\"" {
            quote = char
        } else if char == "(" || char == "{" {
            depth += 1
        } else if char == ")" || char == "}" {
            depth -= 1
            if depth == 0 {
                let inner = trimmed[trimmed.index(after: trimmed.startIndex)..<index]
                let rest = trimmed[trimmed.index(after: index)...]
                    .trimmingCharacters(in: .whitespaces)
                guard rest.isEmpty else { return nil }
                return String(inner).trimmingCharacters(in: .whitespaces)
            }
        }
        trimmed.formIndex(after: &index)
    }
    return nil
}

/// Inner commands of `$(...)` and backtick substitutions. Single-quoted
/// regions are literal; double-quoted and unquoted `$()`/backticks
/// execute. Backslash pairs are skipped, so `\$(` is literal while
/// `\\$(` still scans.
private func substitutionInners(_ segment: String) -> [String] {
    var inners: [String] = []
    let chars = Array(segment)
    var index = 0
    var quote: Character?
    while index < chars.count {
        let char = chars[index]
        if let currentQuote = quote {
            if char == currentQuote {
                quote = nil
                index += 1
                continue
            }
            if currentQuote == "\"" {
                if char == "\\" {
                    index += 2
                    continue
                }
                if char == "'" {
                    index += 1
                    continue
                }
            } else {
                index += 1
                continue
            }
        } else if char == "'" || char == "\"" {
            quote = char
            index += 1
            continue
        } else if char == "\\" {
            index += 2
            continue
        }
        if char == "$", index + 1 < chars.count, chars[index + 1] == "(" {
            if let (inner, next) = matchDollarParen(chars, open: index + 1) {
                inners.append(inner)
                index = next
                continue
            }
            index += 1
            continue
        }
        if char == "`" {
            if let (inner, next) = matchBacktick(chars, open: index) {
                inners.append(inner)
                index = next
                continue
            }
        }
        index += 1
    }
    return inners
}

/// True when `chars[index]` is backslash-escaped (odd run before it).
private func isEscaped(_ chars: [Character], at index: Int) -> Bool {
    var backslashes = 0
    var cursor = index - 1
    while cursor >= 0, chars[cursor] == "\\" {
        backslashes += 1
        cursor -= 1
    }
    return backslashes % 2 == 1
}

/// Matches `$(` at `open` (index of `(`) to its closer, skipping quoted
/// and backtick regions. Returns the inner text and the index past `)`.
private func matchDollarParen(
    _ chars: [Character],
    open: Int
) -> (inner: String, next: Int)? {
    var depth = 0
    var quote: Character?
    var index = open
    while index < chars.count {
        let char = chars[index]
        if let currentQuote = quote {
            if char == "\\", currentQuote == "\"" {
                index += 2
                continue
            }
            if char == currentQuote { quote = nil }
            index += 1
            continue
        }
        if char == "'" || char == "\"" {
            quote = char
            index += 1
            continue
        }
        if char == "\\" {
            index += 2
            continue
        }
        if char == "`" {
            guard let (_, next) = matchBacktick(chars, open: index) else {
                return nil
            }
            index = next
            continue
        }
        if char == "(" {
            depth += 1
        } else if char == ")" {
            depth -= 1
            if depth == 0 {
                let inner = String(chars[(open + 1)..<index])
                return (inner, index + 1)
            }
        }
        index += 1
    }
    return nil
}

/// Matches an opening backtick to the first unescaped backtick.
private func matchBacktick(
    _ chars: [Character],
    open: Int
) -> (inner: String, next: Int)? {
    var index = open + 1
    while index < chars.count {
        if chars[index] == "`", isEscaped(chars, at: index) == false {
            return (String(chars[(open + 1)..<index]), index + 1)
        }
        index += 1
    }
    return nil
}
