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
}
