import RVDomain
import RVTheme

extension CommandVocabulary.Glyph {
    /// The ink this glyph takes on a colour terminal: red ✕, amber ◐,
    /// green ✓, blue →. A colour-off palette (piped, `NO_COLOR`,
    /// `TERM=dumb`) gives the empty ink, so the glyph prints plain.
    package func ink(_ palette: Palette) -> String {
        switch self {
        case .stopped: palette.deny
        case .watched, .ask: palette.mark
        case .done: palette.allow
        case .next: palette.trace
        case .rv: palette.heading
        }
    }
}

/// Paints the vocabulary glyph that leads `words` (`✕ Stopped`,
/// `◐ Would stop`) in its own ink and the words after it in `rest`.
/// Words that do not start with a glyph are painted in `rest`.
package func paintLeadingGlyph(_ words: String, rest: String, palette: Palette) -> String {
    guard let first = words.first,
          let glyph = CommandVocabulary.Glyph(rawValue: String(first)) else {
        return paint(words, slot: rest, reset: palette.reset)
    }
    let tail = words.dropFirst()
    let gap = tail.prefix { $0 == " " }
    let text = String(tail.dropFirst(gap.count))
    return paint(String(first), slot: glyph.ink(palette), reset: palette.reset)
        + gap
        + (text.isEmpty ? "" : paint(text, slot: rest, reset: palette.reset))
}

/// True when `words` start with one of the vocabulary glyphs.
package func leadsWithGlyph(_ words: String) -> Bool {
    words.first.map { CommandVocabulary.Glyph(rawValue: String($0)) != nil } ?? false
}
