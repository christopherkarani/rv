import Foundation

public struct ICUCompiledPattern: @unchecked Sendable {
    let regex: NSRegularExpression
}

public struct ICUPatternEngine: PatternEngine, Sendable {
    public init() {}

    public func compile(_ pattern: String) throws(PatternCompileError) -> ICUCompiledPattern {
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [])
            return ICUCompiledPattern(regex: regex)
        } catch {
            throw PatternCompileError.invalidPattern(
                name: pattern,
                message: String(describing: error)
            )
        }
    }

    public func matches(_ compiled: ICUCompiledPattern, in text: String) -> Bool {
        let full = NSRange(text.startIndex..., in: text)
        return compiled.regex.firstMatch(in: text, options: [], range: full) != nil
    }

    public func firstMatch(_ compiled: ICUCompiledPattern, in text: String) -> Range<String.Index>? {
        let full = NSRange(text.startIndex..., in: text)
        guard let match = compiled.regex.firstMatch(in: text, options: [], range: full) else {
            return nil
        }
        return Range(match.range, in: text)
    }

    /// ICU backtracking can go super-linear on adversarial input (a 6 KB
    /// `rm --recursive …` run took seconds). `.reportProgress` calls back
    /// periodically during a long match, so the search stops at `deadline`
    /// and reports `.exhausted` instead of running unbounded.
    public func search(
        _ compiled: ICUCompiledPattern,
        in text: String,
        deadline: ContinuousClock.Instant
    ) -> PatternSearch {
        guard ContinuousClock.now < deadline else { return .exhausted }
        let full = NSRange(text.startIndex..., in: text)
        var found: NSRange?
        var exhausted = false
        compiled.regex.enumerateMatches(in: text, options: [.reportProgress], range: full) { result, _, stop in
            if let result {
                found = result.range
                stop.pointee = true
            } else if ContinuousClock.now >= deadline {
                exhausted = true
                stop.pointee = true
            }
        }
        if let found {
            // A hit whose range cannot map back is not a miss: fail closed.
            return Range(found, in: text).map(PatternSearch.match) ?? .exhausted
        }
        return exhausted ? .exhausted : .noMatch
    }
}
