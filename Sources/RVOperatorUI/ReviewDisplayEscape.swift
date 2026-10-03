import Foundation

/// Escapes untrusted display strings for the trusted review surface.
///
/// Rendering is literal by construction (SwiftUI `Text(verbatim:)` — no
/// Markdown, no HTML, no markup engine), so markup-like content has nothing
/// to exploit. What remains dangerous is layout/structure spoofing:
/// newlines and tabs that fake extra rows, control characters, and bidi
/// controls that reorder or hide text (e.g. `evil\u{202E}txt.exe`).
/// Every such character is replaced by a visible unambiguous escape, so
/// what the human reads is exactly what is there. Nothing is truncated:
/// the UI renders full values (scrolling) and selects text on demand.
public enum ReviewDisplayEscape: Sendable {
    /// Visible escape of one string. Idempotent.
    public static func escape(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0x0A:
                out += "\\n"
            case 0x0D:
                out += "\\r"
            case 0x09:
                out += "\\t"
            default:
                if isDangerous(scalar) {
                    out += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
                } else {
                    out.append(Character(scalar))
                }
            }
        }
        return out
    }

    private static func isDangerous(_ scalar: Unicode.Scalar) -> Bool {
        // Cc (controls incl. DEL), Cf (format incl. all bidi controls and
        // ALM), Zl/Zp (line/paragraph separators). NL/CR/TAB are handled
        // above with short escapes.
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return false
        }
    }
}
