import Foundation
import RVDomain

/// JSON that keeps each number's source spelling. `JSONDecoder` reads numbers
/// through `Double`, so an integer above 2^53 can round before anyone compares it.
enum JSONLiteral: Equatable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSONLiteral])
    case object([String: JSONLiteral])

    var object: [String: JSONLiteral]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// The same value policy rules compare. Exact integers, including `.0` and
    /// an exponent, keep the digits the call path uses. A fraction `Double`
    /// would round, onto an integer or onto another fraction, stays text.
    func domainValue() -> JSONValue {
        switch self {
        case .null: return .null
        case .bool(let flag): return .bool(flag)
        case .string(let text): return .string(text)
        case .array(let items): return .array(items.map { $0.domainValue() })
        case .object(let members):
            var object: [String: JSONValue] = [:]
            for (key, value) in members { object[key] = value.domainValue() }
            return .object(object)
        case .number(let spelling):
            if let digits = JSONExactInteger.digits(spelling) {
                return JSONExactInteger.domainValue(digits)
            }
            if let number = JSONExactInteger.finiteNonInteger(spelling) {
                return .number(number)
            }
            return .string(JSONExactInteger.numberMarker + spelling)
        }
    }

    /// `0` or a decimal integer with no leading zero. Nil when it does not fit in `Int`.
    static func nonNegativeInteger(_ token: String) -> Int? {
        guard token == "0" || (token.first != "0" && token.allSatisfy(isDigit) && token.isEmpty == false) else {
            return nil
        }
        return Int(token)
    }

    static func quoted(_ text: String) -> String {
        var output = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
        return output
    }

    static func parse(_ data: Data) -> JSONLiteral? {
        var parser = Parser(bytes: Array(data))
        guard let value = parser.parseValue(), parser.skipWhitespace(), parser.index == parser.bytes.count else { return nil }
        return value
    }

    private static func isDigit(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue else { return false }
        return ascii >= UInt8(ascii: "0") && ascii <= UInt8(ascii: "9")
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var depth = 0

        init(bytes: [UInt8]) {
            var bytes = bytes
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
            self.bytes = bytes
        }

        mutating func parseValue() -> JSONLiteral? {
            guard skipWhitespace(), depth < 64, index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "{"): return parseObject()
            case UInt8(ascii: "["): return parseArray()
            case UInt8(ascii: "\""): return parseString().map(JSONLiteral.string)
            case UInt8(ascii: "t"): return consume("true") ? .bool(true) : nil
            case UInt8(ascii: "f"): return consume("false") ? .bool(false) : nil
            case UInt8(ascii: "n"): return consume("null") ? .null : nil
            default: return parseNumber().map(JSONLiteral.number)
            }
        }

        mutating func skipWhitespace() -> Bool {
            while index < bytes.count, isSpace(bytes[index]) { index += 1 }
            return true
        }

        private mutating func parseObject() -> JSONLiteral? {
            guard consume("{") else { return nil }
            depth += 1
            defer { depth -= 1 }
            var object: [String: JSONLiteral] = [:]
            guard skipWhitespace() else { return nil }
            if peek(UInt8(ascii: "}")) {
                index += 1
                return .object(object)
            }
            while index < bytes.count {
                guard let key = parseString(), skipWhitespace(), consume(":"), let value = parseValue() else { return nil }
                if object[key] != nil { return nil }
                object[key] = value
                guard skipWhitespace() else { return nil }
                if peek(UInt8(ascii: "}")) {
                    index += 1
                    return .object(object)
                }
                guard consume(","), skipWhitespace() else { return nil }
            }
            return nil
        }

        private mutating func parseArray() -> JSONLiteral? {
            guard consume("[") else { return nil }
            depth += 1
            defer { depth -= 1 }
            var items: [JSONLiteral] = []
            guard skipWhitespace() else { return nil }
            if peek(UInt8(ascii: "]")) {
                index += 1
                return .array(items)
            }
            while index < bytes.count {
                guard let value = parseValue() else { return nil }
                items.append(value)
                guard skipWhitespace() else { return nil }
                if peek(UInt8(ascii: "]")) {
                    index += 1
                    return .array(items)
                }
                guard consume(",") else { return nil }
            }
            return nil
        }

        private mutating func parseString() -> String? {
            guard consume("\"") else { return nil }
            var scalars = String.UnicodeScalarView()
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == UInt8(ascii: "\"") { return String(scalars) }
                if byte == UInt8(ascii: "\\") {
                    guard let escaped = escape() else { return nil }
                    scalars.append(contentsOf: escaped)
                    continue
                }
                if byte < 0x20 { return nil }
                guard let scalar = scalar(at: &index, first: byte) else { return nil }
                scalars.append(scalar)
            }
            return nil
        }

        private mutating func escape() -> [Unicode.Scalar]? {
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            index += 1
            switch byte {
            case UInt8(ascii: "\""): return ["\""]
            case UInt8(ascii: "\\"): return ["\\"]
            case UInt8(ascii: "/"): return ["/"]
            case UInt8(ascii: "b"): return ["\u{08}"]
            case UInt8(ascii: "f"): return ["\u{0C}"]
            case UInt8(ascii: "n"): return ["\n"]
            case UInt8(ascii: "r"): return ["\r"]
            case UInt8(ascii: "t"): return ["\t"]
            case UInt8(ascii: "u"):
                guard let unit = hex4() else { return nil }
                if UTF16.isLeadSurrogate(unit) {
                    guard consume("\\"), consume("u"), let trail = hex4(), UTF16.isTrailSurrogate(trail) else { return nil }
                    let text = String(decoding: [unit, trail], as: UTF16.self)
                    guard text.unicodeScalars.count == 1, text != "\u{FFFD}" else { return nil }
                    return Array(text.unicodeScalars)
                }
                guard let scalar = Unicode.Scalar(unit) else { return nil }
                return [scalar]
            default: return nil
            }
        }

        private mutating func hex4() -> UInt16? {
            guard index + 4 <= bytes.count else { return nil }
            var value: UInt16 = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                index += 1
                let digit: UInt16
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt16(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt16(byte - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt16(byte - UInt8(ascii: "A") + 10)
                default: return nil
                }
                value = value << 4 | digit
            }
            return value
        }

        /// `index` is one past `first`. Rewinds the extra byte the caller already consumed.
        private func scalar(at index: inout Int, first: UInt8) -> Unicode.Scalar? {
            index -= 1
            let rest = bytes[index...].prefix(4)
            var decoder = UTF8()
            var iterator = rest.makeIterator()
            let decoded = decoder.decode(&iterator)
            guard case .scalarValue(let scalar) = decoded else { return nil }
            index += scalar.utf8.count
            return scalar
        }

        private mutating func parseNumber() -> String? {
            let start = index
            if peek(UInt8(ascii: "-")) { index += 1 }
            guard index < bytes.count else { return nil }
            if peek(UInt8(ascii: "0")) {
                index += 1
            } else if let byte = peekDigit() {
                index += 1
                while index < bytes.count, isDigit(bytes[index]) { index += 1 }
                _ = byte
            } else {
                return nil
            }
            if peek(UInt8(ascii: ".")) {
                index += 1
                guard index < bytes.count, isDigit(bytes[index]) else { return nil }
                while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            }
            if let byte = peek(), byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
                index += 1
                if let sign = peek(), sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") { index += 1 }
                guard index < bytes.count, isDigit(bytes[index]) else { return nil }
                while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            }
            guard index > start, let text = String(bytes: bytes[start..<index], encoding: .utf8) else { return nil }
            return text
        }

        private func peek() -> UInt8? {
            index < bytes.count ? bytes[index] : nil
        }

        private func peek(_ byte: UInt8) -> Bool { peek() == byte }

        private func peekDigit() -> UInt8? {
            guard let byte = peek(), byte >= UInt8(ascii: "1"), byte <= UInt8(ascii: "9") else { return nil }
            return byte
        }

        private func isDigit(_ byte: UInt8) -> Bool {
            byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }

        private func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }

        private mutating func consume(_ word: String) -> Bool {
            let literal = Array(word.utf8)
            guard bytes.count - index >= literal.count, Array(bytes[index..<index + literal.count]) == literal else { return false }
            index += literal.count
            return true
        }
    }
}
