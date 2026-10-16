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
        // Zero is zero at any scale: `0e-2`, `0.00e-10`, and `0e999999` are exact.
        if significand.allSatisfy({ $0 == "0" }) { return "0" }
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

    /// Marks a domain `.string` that came from a JSON number spelling, so rule
    /// equality never confuses the number `9007199254740993` with the string
    /// `"9007199254740993"`. Only the literal/bridge converters produce it.
    public static let numberMarker = "\u{0}"

    /// The digits when `value` is a marked exact-integer string, else nil.
    public static func markedDigits(_ value: JSONValue) -> String? {
        guard case .string(let text) = value, text.hasPrefix(numberMarker) else { return nil }
        return String(text.dropFirst(numberMarker.count))
    }

    /// `.number` when `Double` holds `digits` exactly, otherwise the marked digit string.
    public static func domainValue(_ digits: String) -> JSONValue {
        if let whole = Int64(digits), Int64(exactly: Double(whole)) == whole {
            return .number(Double(whole))
        }
        if digits.hasPrefix("-") == false, let whole = UInt64(digits), UInt64(exactly: Double(whole)) == whole {
            return .number(Double(whole))
        }
        return .string(numberMarker + digits)
    }

    /// A finite `Double` strictly below 2^53 that is not an integer, and that
    /// equals this spelling exactly. Nil when the spelling is non-finite, too
    /// large, an integer, or a different decimal that `Double` would round onto
    /// the same value. `12.5`, `12.50`, and `125e-1` stay; `2251799813685248.4`
    /// does not become `2251799813685248.5`.
    public static func finiteNonInteger(_ spelling: String) -> Double? {
        guard let number = Double(spelling), number.isFinite, number.magnitude < magnitudeLimit else { return nil }
        guard Int64(exactly: number) == nil else { return nil }
        guard spellingEquals(spelling, number) else { return nil }
        return number
    }

    /// True when `spelling` is the same decimal as `number`, not a nearby
    /// fraction that rounds onto it.
    private static func spellingEquals(_ spelling: String, _ number: Double) -> Bool {
        guard let parts = decimalParts(spelling) else { return false }
        if number == 0 { return parts.significand.allSatisfy { $0 == "0" } }
        guard (number < 0) == parts.negative else { return false }
        return magnitudeEquals(parts.significand, parts.scale, number.magnitude)
    }

    private struct DecimalParts {
        var negative: Bool
        var significand: String
        var scale: Int
    }

    /// Integer digits plus the power of ten that puts the point back.
    /// `12.50` is significand `1250` and scale `-2`.
    private static func decimalParts(_ spelling: String) -> DecimalParts? {
        var rest = Substring(spelling)
        let negative = rest.first == "-"
        if negative { rest = rest.dropFirst() }
        guard let integer = decimalRun(&rest), integer == "0" || integer.first != "0" else { return nil }
        var fraction = ""
        if rest.first == "." {
            rest = rest.dropFirst()
            guard let run = decimalRun(&rest), run.isEmpty == false else { return nil }
            fraction = run
        }
        var exponent = 0
        if rest.first == "e" || rest.first == "E" {
            rest = rest.dropFirst()
            let sign = rest.first
            if sign == "+" || sign == "-" { rest = rest.dropFirst() }
            guard let run = decimalRun(&rest), run.isEmpty == false, run.count <= 6, let value = Int(run) else { return nil }
            exponent = sign == "-" ? -value : value
        }
        guard rest.isEmpty, integer.isEmpty == false else { return nil }
        var digits = integer + fraction
        while digits.first == "0", digits.count > 1 { digits.removeFirst() }
        return DecimalParts(negative: negative, significand: digits, scale: exponent - fraction.count)
    }

    private static func decimalRun(_ rest: inout Substring) -> String? {
        var digits = ""
        while let next = rest.first, next.isASCII && next.isNumber {
            digits.append(next)
            rest = rest.dropFirst()
        }
        return digits
    }

    /// `D * 10^scale == mantissa * 2^exponent`, compared with integers.
    private static func magnitudeEquals(_ significand: String, _ scale: Int, _ number: Double) -> Bool {
        var digits = significand
        var scale = scale
        while digits.last == "0", digits.count > 1 {
            digits.removeLast()
            scale += 1
        }
        if digits.isEmpty || digits == "0" { return number == 0 }
        guard digits.count <= 4096, abs(scale) <= 10_000 else { return false }
        guard let (mantissa, exponent) = oddBinary(number), mantissa != 0 else { return false }
        let decimal = Wide.parseDecimal(digits)
        if scale >= 0 {
            let left = decimal.multipliedByFive(scale)
            let shift = exponent - scale
            if shift >= 0 { return left == Wide(mantissa).shiftedLeft(shift) }
            return left.shiftedLeft(-shift) == Wide(mantissa)
        }
        let right = Wide(mantissa).multipliedByFive(-scale)
        let shift = exponent - scale
        if shift >= 0 { return decimal == right.shiftedLeft(shift) }
        return decimal.shiftedLeft(-shift) == right
    }

    /// Odd integer mantissa and the power of two: `number == mantissa * 2^exponent`.
    private static func oddBinary(_ number: Double) -> (mantissa: UInt64, exponent: Int)? {
        guard number.isFinite, number > 0 else { return nil }
        let bits = number.bitPattern
        let rawExponent = Int((bits >> 52) & 0x7FF)
        let fraction = bits & 0x000F_FFFF_FFFF_FFFF
        var mantissa: UInt64
        var exponent: Int
        if rawExponent == 0 {
            mantissa = fraction
            exponent = -1074
        } else {
            mantissa = fraction | (1 << 52)
            exponent = rawExponent - 1023 - 52
        }
        guard mantissa != 0 else { return (0, 0) }
        let zeros = mantissa.trailingZeroBitCount
        mantissa >>= zeros
        exponent += zeros
        return (mantissa, exponent)
    }

    /// Little-endian base 2^64, enough to compare a decimal spelling with a double.
    private struct Wide: Equatable {
        var limbs: [UInt64]

        init(_ value: UInt64) {
            limbs = value == 0 ? [] : [value]
        }

        private init(limbs: [UInt64]) {
            self.limbs = limbs
        }

        static func parseDecimal(_ digits: String) -> Wide {
            var result = Wide(0)
            for byte in digits.utf8 {
                result = result.multiplied(by: 10).adding(UInt64(byte - UInt8(ascii: "0")))
            }
            return result
        }

        func multipliedByFive(_ count: Int) -> Wide {
            var result = self
            if count > 0 {
                for _ in 0..<count { result = result.multiplied(by: 5) }
            }
            return result
        }

        func adding(_ value: UInt64) -> Wide {
            var limbs = limbs
            var carry = value
            var index = 0
            while carry > 0 {
                if index == limbs.count { limbs.append(0) }
                let sum = limbs[index].addingReportingOverflow(carry)
                limbs[index] = sum.partialValue
                carry = sum.overflow ? 1 : 0
                index += 1
            }
            return Wide(limbs: limbs)
        }

        func multiplied(by factor: UInt64) -> Wide {
            if factor == 0 || limbs.isEmpty { return Wide(0) }
            var result: [UInt64] = []
            var carry: UInt64 = 0
            for limb in limbs {
                let product = limb.multipliedFullWidth(by: factor)
                let low = product.low.addingReportingOverflow(carry)
                result.append(low.partialValue)
                let high = product.high.addingReportingOverflow(low.overflow ? 1 : 0)
                carry = high.partialValue
            }
            if carry > 0 { result.append(carry) }
            return Wide(limbs: result)
        }

        func shiftedLeft(_ bits: Int) -> Wide {
            if bits <= 0 || limbs.isEmpty { return self }
            let limbShift = bits / 64
            let bitShift = bits % 64
            var result = Array(repeating: UInt64(0), count: limbShift)
            var carry: UInt64 = 0
            if bitShift == 0 {
                result.append(contentsOf: limbs)
            } else {
                for limb in limbs {
                    result.append((limb << bitShift) | carry)
                    carry = limb >> (64 - bitShift)
                }
                if carry > 0 { result.append(carry) }
            }
            return Wide(limbs: result)
        }
    }
}
