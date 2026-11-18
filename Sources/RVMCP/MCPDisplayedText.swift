import RVDomain

/// Text a person reads in a terminal before they approve. Control characters
/// stay inside the field, so a value cannot redraw the screen or start a line.
/// A literal backslash is doubled before a control is written as `\n` or
/// `\uXXXX`, so the escape text is not the same field as the control.
public enum MCPDisplayedText {
    public static func field(_ text: String) -> String {
        DisplayedText.field(text)
    }

    /// Prose an upstream wrote for the model and the person (a tool's
    /// `description` and `title`). Line breaks, tabs, and backslashes stay
    /// as written, so the text means what the server meant. Only scalars
    /// that can hide or reorder text are written as the visible text
    /// `\uXXXX`: C0 controls other than TAB and LF (CR and ESC included),
    /// DEL, C1 controls, format characters (bidi marks, embeddings,
    /// overrides and isolates, zero-width and invisible tag characters, the
    /// BOM), and the line and paragraph separators. The joiners and the soft
    /// hyphen stay (`DisplayedText.needsEscape`). A literal backslash is not
    /// doubled, so `‮` in the source and an escaped U+202E read alike;
    /// that is display text, never matched or hashed.
    public static func description(_ text: String) -> String {
        var shown = ""
        shown.unicodeScalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if scalar != "\n", scalar != "\t", DisplayedText.needsEscape(scalar) {
                shown += String(format: "\\u%04x", scalar.value)
            } else {
                shown.unicodeScalars.append(scalar)
            }
        }
        return shown
    }
}
