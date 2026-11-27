import RVDomain
import RVTheme

/// `rv box` colours only its glyphs, as the policy refusals and the
/// secrets hook do: red `✕`, blue `→`, green `✓`, amber `◐`, and the
/// heading ink for rv's `◆`. Every word stays in the terminal's own colour.
/// A colour-off palette passes the text through unchanged.
enum BoxInk {
    private typealias Glyph = CommandVocabulary.Glyph

    /// `text` with the glyph that leads each line painted.
    static func paint(_ text: String, palette: Palette) -> String {
        guard palette.colorsEnabled else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { paintLine(String($0), palette: palette) }
            .joined(separator: "\n")
    }

    /// The palette for one output stream: colour only on a terminal, and
    /// never under `NO_COLOR`, `TERM=dumb` or `CI`.
    static func palette(isTerminal: Bool, environment: [String: String]) -> Palette {
        let probe = ThemeProbeFactory.make(
            jsonFlag: false, robotFlag: false, plainFlag: false, noColorFlag: false,
            stdinIsTTY: isTerminal, stdoutIsTTY: isTerminal, environment: environment)
        return Palette(for: ColorCapability(probe: probe, mode: .pretty), background: probe.background)
    }

    private static func paintLine(_ line: String, palette: Palette) -> String {
        let indent = line.prefix { $0 == " " }
        let body = line.dropFirst(indent.count)
        guard let first = body.first,
              let glyph = Glyph(rawValue: String(first)),
              body.dropFirst().first.map({ $0 == " " }) ?? true,
              let ink = ink(glyph, palette: palette), ink.isEmpty == false
        else { return line }
        return indent + ink + String(first) + palette.reset + body.dropFirst()
    }

    private static func ink(_ glyph: Glyph, palette: Palette) -> String? {
        switch glyph {
        case .rv: palette.heading
        case .stopped: palette.deny
        case .watched: palette.mark
        case .done: palette.allow
        case .next: palette.trace
        case .ask: nil
        }
    }
}
