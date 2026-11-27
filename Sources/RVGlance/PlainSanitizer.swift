import Foundation

/// Turns a language model's reply into a line fit to show, or nil (use the
/// template). The model's input includes agent-written command text, so its
/// reply is untrusted: it must be one line, describe an effect ("Would…"),
/// and never claim or suggest a decision.
public enum PlainSanitizer {
    /// Words and phrases that judge, decide, reassure or advise. Matched
    /// as whole words, case-insensitively, after normalisation.
    static let decisionClaims: [String] = [
        "allow", "allowed", "allows", "allowing", "approve", "approved", "approves", "permit", "permitted",
        "deny", "denied", "block", "blocked", "reject", "rejected", "refuse", "refused",
        "safe", "safely", "unsafe", "harmless", "harmful", "benign", "dangerous", "risky", "risk", "malicious",
        "fine", "ok", "okay", "trusted", "trustworthy", "legitimate", "legit", "expected", "intended",
        "false positive", "mistake", "ignore", "ignored", "warning", "warnings", "worry", "concern",
        "nothing bad", "no harm", "no problem", "not a problem", "just",
        "i will", "i ll", "i can", "i cannot", "i can t", "i won t", "i would",
        "you should", "should not", "shouldn t", "recommend", "advise", "as an ai",
    ]

    /// Characters stripped from both ends.
    static let wrappers = CharacterSet(charactersIn: "\"'`“”‘’*_#>-• ").union(.whitespacesAndNewlines)

    /// `raw` as a line, or nil. `command` is the action text the model
    /// was shown: a non-ASCII character it does not contain cannot be a
    /// faithful copy of it, so the line is refused (homoglyphs, smuggled
    /// scripts).
    public static func clean(_ raw: String, command: String = "") -> String? {
        var text = normalized(raw)
        text = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        for marker in ["**", "__", "`"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        text = text.trimmingCharacters(in: wrappers)
        if text.hasSuffix(".") { text.removeLast() }
        text = text.trimmingCharacters(in: wrappers)
        guard !text.isEmpty, startsWithWould(text), !claimsADecision(text),
              onlyCopiesNonASCII(text, from: normalized(command)) else { return nil }
        return PlainText.clamp(text)
    }

    /// NFKC (so look-alike forms fold to plain letters before matching),
    /// then without control or format scalars (zero-width, bidi overrides).
    public static func normalized(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping
        let kept = folded.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control: scalar == "\n" || scalar == "\t"
            case .format: false
            default: true
            }
        }
        return String(String.UnicodeScalarView(kept))
    }

    static func onlyCopiesNonASCII(_ text: String, from command: String) -> Bool {
        let allowed = Set(command.unicodeScalars.filter { !$0.isASCII })
        return text.unicodeScalars.allSatisfy { $0.isASCII || allowed.contains($0) || $0 == "…" }
    }

    static func startsWithWould(_ text: String) -> Bool {
        text.lowercased().hasPrefix("would ")
    }

    static func claimsADecision(_ text: String) -> Bool {
        let words = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        let padded = " " + String(words).split(separator: " ").joined(separator: " ") + " "
        return decisionClaims.contains { padded.contains(" \($0) ") }
    }
}
