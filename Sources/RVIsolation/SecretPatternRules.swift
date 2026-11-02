#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// A small, high-precision set of token-shape rules that run beside the
/// exact-value scan. Regexes are adapted from betterleaks (as vendored by the
/// Infisical CLI), narrowed to the issuers rv users hit most.
struct SecretPatternRule {
    var id: String
    /// Lowercased substrings; the regex runs only when one is present.
    var keywords: [String]
    var regex: NSRegularExpression
    /// Minimum Shannon entropy (bits per character) of the matched secret.
    var minimumEntropy: Double
    /// The generic assignment rule: also filtered for natural language, and
    /// dropped when a specific rule matches the same line.
    var generic = false
}

/// One pattern hit before suppression. Holds offsets, never the value.
struct SecretPatternMatch: Equatable {
    var rule: String
    var line: Int
    var generic: Bool
}

enum SecretPatternRules {
    static let allowComment = "rv-secrets:allow"

    /// Compiled per scan: `NSRegularExpression` is not `Sendable` on every
    /// platform, so the rules are never held in a static.
    static func compiled() -> [SecretPatternRule] {
        func rule(_ id: String, _ keywords: [String], _ pattern: String, entropy: Double, generic: Bool = false)
            -> SecretPatternRule?
        {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return SecretPatternRule(id: id, keywords: keywords, regex: regex, minimumEntropy: entropy, generic: generic)
        }
        let end = #"(?![A-Za-z0-9_-])"#
        return [
            rule("aws-access-key-id", ["akia", "asia"], #"\b((?:AKIA|ASIA)[A-Z2-7]{16})\b"#, entropy: 3),
            rule(
                "github-token", ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_"],
                #"\b((?:ghp|gho|ghu|ghs|ghr)_[0-9A-Za-z]{36}|github_pat_[0-9A-Za-z_]{82})\b"#, entropy: 3),
            rule("slack-token", ["xox"], #"\b(xox[abprs]-[0-9]+-[0-9A-Za-z-]{10,})"#, entropy: 3),
            rule("stripe-secret-key", ["sk_live_", "rk_live_"], #"\b((?:sk|rk)_live_[0-9A-Za-z]{10,99})\b"#, entropy: 3),
            rule("anthropic-api-key", ["sk-ant-"], #"\b(sk-ant-[a-z]+[0-9]{2}-[A-Za-z0-9_-]{32,})"#, entropy: 3),
            rule(
                "openai-api-key", ["sk-proj-", "sk-svcacct-", "sk-admin-", "t3blbkfj"],
                #"\b(sk-(?:proj|svcacct|admin)-[A-Za-z0-9_-]{32,}|sk-[A-Za-z0-9]{20}T3BlbkFJ[A-Za-z0-9]{20})"# + end,
                entropy: 3),
            rule("google-api-key", ["aiza"], #"\b(AIza[0-9A-Za-z_-]{35})"# + end, entropy: 3),
            // The header alone is common in parsing code; require key material after it.
            rule(
                "private-key", ["private key"],
                #"(-----BEGIN[ A-Z0-9_-]{0,100}PRIVATE KEY(?: BLOCK)?-----)[\s\S]{0,200}?[A-Za-z0-9+/]{40,}"#,
                entropy: 0),
            rule(
                "jwt", ["eyj"],
                #"\b(ey[A-Za-z0-9_-]{17,}\.ey[A-Za-z0-9_-]{17,}\.[A-Za-z0-9_-]{10,})"# + end, entropy: 3),
            rule(
                "generic-secret", ["key", "token", "secret", "password", "passwd"],
                #"(?i)(?:key|token|secret|password|passwd)[\w.-]{0,40}['"]?[ \t]*(?::=|=>|=|:)[ \t]*['"`]?([\w+/=.~-]{16,200})(?=['"`\s;,)]|$)"#,
                entropy: 3.5, generic: true),
        ].compactMap { $0 }
    }

    /// Pattern hits in one text buffer, with specific rules winning over the
    /// generic rule on the same line.
    static func matches(in bytes: [UInt8], rules: [SecretPatternRule]) -> [SecretPatternMatch] {
        let lowered = bytes.map { $0 >= 65 && $0 <= 90 ? $0 | 0x20 : $0 }
        let active = rules.filter { $0.keywords.contains { contains(Array($0.utf8), in: lowered) } }
        guard active.isEmpty == false else { return [] }
        let text = String(decoding: bytes, as: UTF8.self)
        let nsText = text as NSString
        var lines: LineIndex?
        var found: [SecretPatternMatch] = []
        for rule in active {
            let whole = NSRange(location: 0, length: nsText.length)
            for match in rule.regex.matches(in: text, range: whole) {
                let range = match.range(at: 1)
                guard range.location != NSNotFound else { continue }
                let secret = nsText.substring(with: range)
                guard isCandidate(secret, rule: rule) else { continue }
                let index = lines ?? LineIndex(text)
                lines = index
                found.append(SecretPatternMatch(rule: rule.id, line: index.line(at: range.location), generic: rule.generic))
            }
        }
        let specificLines = Set(found.filter { $0.generic == false }.map(\.line))
        return found.filter { $0.generic == false || specificLines.contains($0.line) == false }
    }

    /// Byte search through `memmem`; a Swift loop over every buffer is too
    /// slow for a whole-tree scan.
    static func contains(_ needle: [UInt8], in haystack: [UInt8]) -> Bool {
        guard needle.isEmpty == false, haystack.count >= needle.count else { return needle.isEmpty }
        return haystack.withUnsafeBytes { hay in
            needle.withUnsafeBytes { pin in
                // Both are non-empty here; Glibc's memmem takes non-optional pointers.
                guard let h = hay.baseAddress, let n = pin.baseAddress else { return false }
                return memmem(h, hay.count, n, pin.count) != nil
            }
        }
    }

    static func isCandidate(_ secret: String, rule: SecretPatternRule) -> Bool {
        guard isPlaceholder(secret) == false, entropy(secret) >= rule.minimumEntropy else { return false }
        guard rule.generic else { return true }
        let hasDigit = secret.contains(where: \.isNumber)
        let hasLetter = secret.contains(where: \.isLetter)
        return hasDigit && hasLetter && looksLikeWords(secret) == false
    }

    /// rv's own placeholders and the usual documentation stand-ins.
    static func isPlaceholder(_ secret: String) -> Bool {
        let lowered = secret.lowercased()
        let markers = [
            "rvph_", "xxx", "your-", "your_", "example", "changeme", "change-me", "change_me",
            "placeholder", "redacted", "dummy", "sample", "replace",
        ]
        return markers.contains { lowered.contains($0) }
    }

    /// Natural language or an identifier: most of its letters sit in runs of
    /// four or more (split at case and digit changes) that contain a vowel.
    /// Random tokens rarely do.
    static func looksLikeWords(_ secret: String) -> Bool {
        var runs: [String] = []
        var current = ""
        var previous: Character?
        for character in secret {
            let breaks: Bool
            if let previous {
                breaks = character.isLetter != previous.isLetter
                    || character.isNumber != previous.isNumber
                    || (previous.isLowercase && character.isUppercase)
            } else {
                breaks = false
            }
            if breaks || (character.isLetter == false && character.isNumber == false) {
                if current.isEmpty == false { runs.append(current) }
                current = ""
            }
            if character.isLetter || character.isNumber { current.append(character) }
            previous = character
        }
        if current.isEmpty == false { runs.append(current) }
        let total = runs.reduce(0) { $0 + $1.count }
        guard total > 0 else { return false }
        let vowels = Set("aeiouAEIOU")
        let wordy = runs.filter { run in
            run.count >= 4 && run.allSatisfy(\.isLetter) && run.contains(where: vowels.contains)
        }.reduce(0) { $0 + $1.count }
        return Double(wordy) / Double(total) >= 0.5
    }

    /// Shannon entropy in bits per character.
    static func entropy(_ text: String) -> Double {
        let characters = Array(text.unicodeScalars)
        guard characters.isEmpty == false else { return 0 }
        var counts: [Unicode.Scalar: Int] = [:]
        for character in characters { counts[character, default: 0] += 1 }
        let length = Double(characters.count)
        return counts.values.reduce(0) { sum, count in
            let p = Double(count) / length
            return sum - p * log2(p)
        }
    }
}

/// UTF-16 offset to 1-based line number for one buffer.
struct LineIndex {
    private let starts: [Int]

    /// Offsets are UTF-16, matching `NSString` / `NSRange`.
    init(_ text: String) {
        var starts = [0]
        for (index, unit) in text.utf16.enumerated() where unit == 10 { starts.append(index + 1) }
        self.starts = starts
    }

    init(bytes: [UInt8]) {
        var starts = [0]
        for (index, byte) in bytes.enumerated() where byte == 10 { starts.append(index + 1) }
        self.starts = starts
    }

    /// Line containing `offset`.
    func line(at offset: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low + 1
    }
}
