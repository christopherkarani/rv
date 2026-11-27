import Foundation

/// Turns a language model's reply into a line fit to show, or nil (use the
/// template). The model's input includes agent-written command text, so its
/// reply is untrusted: it must be one line, describe an effect ("Would…"),
/// and never claim or suggest a decision.
public enum PlainSanitizer {
    /// Words and phrases that judge, decide or advise. Matched on word
    /// boundaries, case-insensitively.
    static let decisionClaims: [String] = [
        "allow", "allowed", "allows", "allowing", "approve", "approved", "approves", "permit", "permitted",
        "deny", "denied", "block", "blocked", "reject", "rejected", "refuse", "refused",
        "safe", "unsafe", "harmless", "dangerous", "risky", "malicious",
        "i will", "i ll", "i can", "i cannot", "i can t", "i won t", "i would",
        "you should", "should not", "shouldn t", "recommend", "advise", "as an ai",
    ]

    /// Characters stripped from both ends.
    static let wrappers = CharacterSet(charactersIn: "\"'`“”‘’*_#>-• ").union(.whitespacesAndNewlines)

    public static func clean(_ raw: String) -> String? {
        var text = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        for marker in ["**", "__", "`"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        text = text.trimmingCharacters(in: wrappers)
        if text.hasSuffix(".") { text.removeLast() }
        text = text.trimmingCharacters(in: wrappers)
        guard !text.isEmpty else { return nil }
        guard startsWithWould(text), !claimsADecision(text) else { return nil }
        return PlainText.clamp(text)
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
