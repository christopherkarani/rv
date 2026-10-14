import Foundation
import RVPolicy

extension JSONValue {
    /// The same value in RVDomain's model, which RVPolicy rules evaluate.
    /// An exact integer keeps its digits when `Double` cannot hold it, including
    /// spellings with a trailing fraction or an exponent. Anything else that
    /// `Double` would round into an integer fails closed as text.
    public var domainValue: ToolArgumentRule.Value {
        switch self {
        case .null: return .null
        case .bool(let flag): return .bool(flag)
        case .string(let text): return .string(text)
        case .array(let items): return .array(items.map(\.domainValue))
        case .object(let object):
            var members: [String: ToolArgumentRule.Value] = [:]
            for (key, value) in object.entries { members[key] = value.domainValue }
            return .object(members)
        case .number(let spelling):
            if let digits = Self.exactIntegerDigits(spelling) {
                return Self.integerDomainValue(digits)
            }
            guard let number = Double(spelling), number.isFinite, number.magnitude < Self.exactIntegerLimit else {
                return .string(spelling)
            }
            return .number(number)
        }
    }

    /// The value with exact-integer spellings rewritten to canonical digits.
    /// Nil when a number is not an exact integer and is not a finite value
    /// below 2^53: that token must not be forwarded.
    func withExactNumbers() -> JSONValue? {
        switch self {
        case .number(let spelling):
            if let digits = Self.exactIntegerDigits(spelling) { return .number(digits) }
            guard let number = Double(spelling), number.isFinite, number.magnitude < Self.exactIntegerLimit else {
                return nil
            }
            return self
        case .array(let items):
            var rewritten: [JSONValue] = []
            for item in items {
                guard let next = item.withExactNumbers() else { return nil }
                rewritten.append(next)
            }
            return .array(rewritten)
        case .object(let object):
            var copy = JSONObject()
            for (key, value) in object.entries {
                guard let next = value.withExactNumbers() else { return nil }
                copy[key] = next
            }
            return .object(copy)
        default:
            return self
        }
    }

    /// 2^53. Every finite `Double` at or above this magnitude is an integer.
    private static let exactIntegerLimit = 9_007_199_254_740_992.0

    /// Canonical digits (`-` and no leading zeros) when `spelling` is an exact
    /// integer, including `9007199254740993.0` and `9.007199254740993e15`.
    /// Nil for fractions, for a token that is not a JSON number, and when the
    /// digit string would be unbounded.
    private static func exactIntegerDigits(_ spelling: String) -> String? {
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

    private static func integerDomainValue(_ digits: String) -> ToolArgumentRule.Value {
        if let whole = Int64(digits), Int64(exactly: Double(whole)) == whole {
            return .number(Double(whole))
        }
        if digits.hasPrefix("-") == false, let whole = UInt64(digits), UInt64(exactly: Double(whole)) == whole {
            return .number(Double(whole))
        }
        return .string(digits)
    }

    init(domain value: ToolArgumentRule.Value) {
        switch value {
        case .null: self = .null
        case .bool(let flag): self = .bool(flag)
        case .string(let text): self = .string(text)
        case .array(let items): self = .array(items.map(JSONValue.init(domain:)))
        case .object(let members):
            var object = JSONObject()
            for key in members.keys.sorted() { object[key] = members[key].map(JSONValue.init(domain:)) }
            self = .object(object)
        case .number(let number):
            if let whole = Int64(exactly: number) {
                self = .number(String(whole))
            } else {
                self = .number(String(number))
            }
        }
    }
}
