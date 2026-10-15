/// Incomplete-eval sentence shared by hook voice and TTY copy.
public let incompleteEvalSentence =
    "rv could not finish evaluating this command. Run it in Terminal."

/// Text a person or a client reads. Control characters stay inside the field,
/// so a value cannot redraw the screen or start a line. A literal backslash
/// is doubled before a control is written as `\n` or `\uXXXX`, so the escape
/// text is not the same field as the control.
public enum DisplayedText {
    /// Scalars that must never reach a display raw: C0/C1/DEL controls, line
    /// and paragraph separators, and every format character (bidi marks and
    /// overrides, zero-width and invisible tag characters). Category-based,
    /// so a scalar nobody enumerated is still escaped.
    public static func needsEscape(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    public static func field(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            if scalar.value == 0x5C {
                escaped += "\\\\"
                continue
            }
            switch scalar.value {
            case 0x0A: escaped += "\\n"
            case 0x0D: escaped += "\\r"
            default:
                if needsEscape(scalar) {
                    escaped += String(format: "\\u%04x", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return escaped
    }

    /// `JSONEncoder` writes ESC as `\u001b` and leaves separators, bidi
    /// controls, and other format scalars raw inside strings. Escaping those
    /// scalars after encoding keeps one JSON value (and one line for
    /// NEL/LS-splitting consumers) without fielding the text first. Astral
    /// scalars are written as surrogate-pair escapes, as JSON requires.
    public static func escapeJSONScalars(_ text: String) -> String {
        var escaped = ""
        escaped.unicodeScalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if needsEscape(scalar), scalar.value >= 0x80 {
                for unit in String(scalar).utf16 {
                    escaped += String(format: "\\u%04x", unit)
                }
            } else {
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }
}

/// Slash display (`core.git/reset-hard`); `RuleID.rawValue` is colon (`core.git:reset-hard`).
package func displayRuleID(_ ruleID: RuleID) -> String {
    ruleID.slashDisplay
}
