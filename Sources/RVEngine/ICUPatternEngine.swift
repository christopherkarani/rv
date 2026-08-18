import Foundation

public struct ICUCompiledPattern: @unchecked Sendable {
    let regex: NSRegularExpression
}

public struct ICUPatternEngine: PatternEngine, Sendable {
    public init() {}

    public func compile(_ pattern: String) throws -> ICUCompiledPattern {
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
        let range = NSRange(text.startIndex..., in: text)
        return compiled.regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
