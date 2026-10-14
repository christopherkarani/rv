import Foundation
import RVDomain

/// JSON number spellings that mean an integer, kept as digits when `Double`
/// would round them. Call arguments and organization policy both use this.
public enum JSONExactInteger {
    /// 2^53. Every finite `Double` at or above this magnitude is an integer.
    public static let magnitudeLimit = 9_007_199_254_740_992.0

    /// Canonical digits (`-` and no leading zeros) when `spelling` is an exact
    /// integer, including `9007199254740993.0` and `9.007199254740993e15`.
    /// Nil for fractions, for a token that is not a JSON number, and when the
    /// digit string would be unbounded.
    public static func digits(_ spelling: String) -> String? {
        let bytes = Array(spelling.utf8)
        var index = 0
        func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }
        var negative = false
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") {
            negative = true
            index += 1
        }
        let integerStart = index
        guard index < bytes.count, isDigit(bytes[index]) else { return nil }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
            if index < bytes.count, isDigit(bytes[index]) { return nil }
        } else {
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        let integer = String(decoding: bytes[integerStart..<index], as: UTF8.self)
        var fraction = ""
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            let fractionStart = index
            guard index < bytes.count, isDigit(bytes[index]) else { return nil }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            fraction = String(decoding: bytes[fractionStart..<index], as: UTF8.self)
        }
        var exponent = 0
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            var exponentNegative = false
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                exponentNegative = bytes[index] == UInt8(ascii: "-")
                index += 1
            }
            let exponentStart = index
            guard index < bytes.count, isDigit(bytes[index]) else { return nil }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            let text = String(decoding: bytes[exponentStart..<index], as: UTF8.self)
            guard text.count <= 6, let value = Int(text) else { return nil }
            exponent = exponentNegative ? -value : value
        }
        guard index == bytes.count else { return nil }
        let significand = integer + fraction
        let scale = exponent - fraction.count
        let digits: String
        if scale >= 0 {
            guard significand.count + scale <= 4096 else { return nil }
            digits = significand + String(repeating: "0", count: scale)
        } else {
            let drop = -scale
            guard significand.count >= drop else { return nil }
            let tail = significand.suffix(drop)
            guard tail.allSatisfy({ $0 == "0" }) else { return nil }
            digits = String(significand.dropLast(drop))
        }
        var trimmed = digits
        while trimmed.first == "0", trimmed.count > 1 { trimmed.removeFirst() }
        if trimmed.isEmpty || trimmed == "0" { return "0" }
        return negative ? "-" + trimmed : trimmed
    }

    /// `.number` when `Double` holds `digits` exactly, otherwise the digit string.
    public static func domainValue(_ digits: String) -> JSONValue {
        if let whole = Int64(digits), Int64(exactly: Double(whole)) == whole {
            return .number(Double(whole))
        }
        if digits.hasPrefix("-") == false, let whole = UInt64(digits), UInt64(exactly: Double(whole)) == whole {
            return .number(Double(whole))
        }
        return .string(digits)
    }

    /// A finite `Double` strictly below 2^53 that is not an integer.
    /// Nil when the spelling is non-finite, too large, or `Double` would
    /// round a fraction onto an integer.
    public static func finiteNonInteger(_ spelling: String) -> Double? {
        guard let number = Double(spelling), number.isFinite, number.magnitude < magnitudeLimit else { return nil }
        guard Int64(exactly: number) == nil else { return nil }
        return number
    }
}
