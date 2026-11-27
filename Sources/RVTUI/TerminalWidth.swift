/// How many terminal columns text takes, `wcwidth`-style: a combining or
/// zero-width scalar takes none, an East Asian wide or fullwidth character
/// or an emoji shown as an emoji takes two, anything else one. Counted per
/// character (grapheme), so `é` written as `e` + U+0301 is one column.
enum TerminalWidth {
    static func of(_ text: String) -> Int {
        text.reduce(0) { $0 + of($1) }
    }

    static func of(_ character: Character) -> Int {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return 0 }
        if scalars.contains(where: { $0.value == 0xFE0F }), first.properties.isEmoji { return 2 }
        if isWide(first) { return 2 }
        if scalars.allSatisfy(isZeroWidth) { return 0 }
        return 1
    }

    /// The longest start of `text` that fits in `width` columns.
    static func prefix(_ text: String, fitting width: Int) -> String {
        var kept = ""
        var used = 0
        for character in text {
            let size = of(character)
            guard used + size <= width else { break }
            kept.append(character)
            used += size
        }
        return kept
    }

    /// The longest end of `text` that fits in `width` columns.
    static func suffix(_ text: String, fitting width: Int) -> String {
        var kept: [Character] = []
        var used = 0
        for character in text.reversed() {
            let size = of(character)
            guard used + size <= width else { break }
            kept.append(character)
            used += size
        }
        return String(kept.reversed())
    }

    /// `text` in at most `width` columns, ending in `…` when cut.
    static func clip(_ text: String, to width: Int) -> String {
        guard of(text) > width else { return text }
        guard width > 1 else { return prefix(text, fitting: width) }
        return prefix(text, fitting: width - 1) + "…"
    }

    /// `text` padded with spaces to `width` columns.
    static func pad(_ text: String, to width: Int) -> String {
        let used = of(text)
        return used >= width ? text : text + String(repeating: " ", count: width - used)
    }

    /// `text` broken at spaces into lines of at most `width` columns; a
    /// word longer than a line is cut.
    static func wrap(_ text: String, width: Int) -> [String] {
        guard width > 0, of(text) > width else { return [text] }
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            let candidate = line.isEmpty ? word : line + " " + word
            if of(candidate) <= width {
                line = candidate
                continue
            }
            if line.isEmpty == false { lines.append(line) }
            line = of(word) <= width ? word : clip(word, to: width)
        }
        if line.isEmpty == false { lines.append(line) }
        return lines
    }

    private static func isZeroWidth(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value == 0x200B || scalar.value == 0x200C || scalar.value == 0x200D || scalar.value == 0xFE0F {
            return true
        }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return true
        default: return false
        }
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isEmojiPresentation { return true }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x20000...0x2FFFD, 0x30000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
