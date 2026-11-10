import Foundation
import RVDomain

/// JSON that keeps each number's source spelling and each object's entry
/// order. `JSONDecoder` reads numbers through `Double`, so an integer above
/// 2^53 can round before anyone compares it, and it drops key order that
/// host configs need when they are rewritten in place.
public enum JSONSpellingValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSONSpellingValue])
    case object([Entry])

    /// One object member, in source order.
    public struct Entry: Sendable, Equatable {
        public var key: String
        public var value: JSONSpellingValue

        public init(key: String, value: JSONSpellingValue) {
            self.key = key
            self.value = value
        }
    }

    /// The member for `key`, or nil. Parsed objects hold each key once; a
    /// hand-built object that repeats a key reads back its last value.
    public subscript(key: String) -> JSONSpellingValue? {
        if case .object(let entries) = self {
            return entries.last { $0.key == key }?.value
        }
        return nil
    }

    /// The members as a dictionary, or nil when this is not an object.
    public var object: [String: JSONSpellingValue]? {
        if case .object(let entries) = self {
            var members: [String: JSONSpellingValue] = [:]
            for entry in entries { members[entry.key] = entry.value }
            return members
        }
        return nil
    }

    /// The ordered members, or nil when this is not an object.
    public var entries: [Entry]? {
        if case .object(let entries) = self { return entries }
        return nil
    }

    /// The same value policy rules compare. Exact integers, including `.0` and
    /// an exponent, keep the digits the call path uses. A fraction `Double`
    /// would round, onto an integer or onto another fraction, stays text.
    public func domainValue() -> JSONValue {
        switch self {
        case .null: return .null
        case .bool(let flag): return .bool(flag)
        case .string(let text): return .string(text)
        case .array(let items): return .array(items.map { $0.domainValue() })
        case .object(let entries):
            var members: [String: JSONValue] = [:]
            for entry in entries { members[entry.key] = entry.value.domainValue() }
            return .object(members)
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
}

public enum JSONSpellingParseError: Error, Sendable, Equatable {
    case invalid(offset: Int)
    case tooDeep
    /// The same object key appears twice, named as decoded. The last value
    /// must not hide an earlier one.
    case duplicateKey(String)
}

/// The one spelling-preserving JSON parser module. `JSONLiteral` (managed
/// policy) and RVMCP's `JSONValue` are adapters at this seam: each keeps its
/// own value interface, neither keeps a parser.
public enum JSONSpellingParser {
    /// Strict RFC 8259 by default. `lenient` accepts `//` and `/* */`
    /// comments and trailing commas (JSONC: VS Code, OpenCode).
    ///
    /// Depth counts values from the root at depth 0: a value nested deeper
    /// than `maximumDepth` is `.tooDeep`. An empty container never pays for
    /// the level inside it, so `maximumDepth + 1` empty containers nest
    /// where `maximumDepth` containers around a scalar do.
    public static func parse(
        _ data: Data, maximumDepth: Int = 64, lenient: Bool = false
    ) throws(JSONSpellingParseError) -> JSONSpellingValue {
        var parser = Parser(bytes: Array(data), maximumDepth: maximumDepth, lenient: lenient)
        return try parser.parseDocument()
    }

    public static func parse(
        _ text: String, maximumDepth: Int = 64, lenient: Bool = false
    ) throws(JSONSpellingParseError) -> JSONSpellingValue {
        try parse(Data(text.utf8), maximumDepth: maximumDepth, lenient: lenient)
    }

    private struct Parser {
        let bytes: [UInt8]
        let maximumDepth: Int
        let lenient: Bool
        var index = 0

        init(bytes: [UInt8], maximumDepth: Int, lenient: Bool) {
            self.bytes = bytes
            self.maximumDepth = maximumDepth
            self.lenient = lenient
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
        }

        mutating func parseDocument() throws(JSONSpellingParseError) -> JSONSpellingValue {
            let value = try parseValue(depth: 0)
            try skipWhitespace()
            guard index == bytes.count else { throw .invalid(offset: index) }
            return value
        }

        private var invalid: JSONSpellingParseError { .invalid(offset: index) }

        private mutating func skipWhitespace() throws(JSONSpellingParseError) {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D:
                    index += 1
                case UInt8(ascii: "/") where lenient && index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "/"):
                    while index < bytes.count, bytes[index] != 0x0A { index += 1 }
                case UInt8(ascii: "/") where lenient && index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "*"):
                    index += 2
                    while index + 1 < bytes.count, (bytes[index] == UInt8(ascii: "*") && bytes[index + 1] == UInt8(ascii: "/")) == false {
                        index += 1
                    }
                    guard index + 1 < bytes.count else { throw invalid }
                    index += 2
                default:
                    return
                }
            }
        }

        private mutating func parseValue(depth: Int) throws(JSONSpellingParseError) -> JSONSpellingValue {
            guard depth <= maximumDepth else { throw .tooDeep }
            try skipWhitespace()
            guard index < bytes.count else { throw invalid }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return .number(try parseNumber())
            }
        }

        private mutating func expect(_ word: String) throws(JSONSpellingParseError) {
            let literal = Array(word.utf8)
            guard bytes.count - index >= literal.count, Array(bytes[index..<index + literal.count]) == literal else {
                throw invalid
            }
            index += literal.count
        }

        private mutating func parseObject(depth: Int) throws(JSONSpellingParseError) -> JSONSpellingValue {
            index += 1
            var entries: [JSONSpellingValue.Entry] = []
            var seen: Set<String> = []
            try skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(entries)
            }
            while true {
                try skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw invalid }
                let key = try parseString()
                if seen.contains(key) { throw JSONSpellingParseError.duplicateKey(key) }
                seen.insert(key)
                try skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw invalid }
                index += 1
                entries.append(.init(key: key, value: try parseValue(depth: depth + 1)))
                try skipWhitespace()
                guard index < bytes.count else { throw invalid }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(entries) }
                guard bytes[index] == UInt8(ascii: ",") else { throw invalid }
                index += 1
                if lenient {
                    try skipWhitespace()
                    if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(entries) }
                }
            }
        }

        private mutating func parseArray(depth: Int) throws(JSONSpellingParseError) -> JSONSpellingValue {
            index += 1
            var items: [JSONSpellingValue] = []
            try skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            }
            while true {
                items.append(try parseValue(depth: depth + 1))
                try skipWhitespace()
                guard index < bytes.count else { throw invalid }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                guard bytes[index] == UInt8(ascii: ",") else { throw invalid }
                index += 1
                if lenient {
                    try skipWhitespace()
                    if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                }
            }
        }

        private mutating func parseString() throws(JSONSpellingParseError) -> String {
            index += 1
            var output: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    guard let text = String(validating: output, as: UTF8.self) else { throw invalid }
                    return text
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { throw invalid }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): output.append(0x22)
                    case UInt8(ascii: "\\"): output.append(0x5C)
                    case UInt8(ascii: "/"): output.append(0x2F)
                    case UInt8(ascii: "b"): output.append(0x08)
                    case UInt8(ascii: "f"): output.append(0x0C)
                    case UInt8(ascii: "n"): output.append(0x0A)
                    case UInt8(ascii: "r"): output.append(0x0D)
                    case UInt8(ascii: "t"): output.append(0x09)
                    case UInt8(ascii: "u"): output += Array(String(try parseUnicodeEscape()).utf8)
                    default: throw invalid
                    }
                case 0..<0x20:
                    throw invalid
                default:
                    output.append(byte)
                }
            }
            throw invalid
        }

        private mutating func parseUnicodeEscape() throws(JSONSpellingParseError) -> Character {
            let high = try parseHex4()
            if (0xD800..<0xDC00).contains(high) {
                guard bytes.count - index >= 6, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else {
                    throw invalid
                }
                index += 2
                let low = try parseHex4()
                guard (0xDC00..<0xE000).contains(low),
                    let scalar = Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00))
                else { throw invalid }
                return Character(scalar)
            }
            guard let scalar = Unicode.Scalar(high) else { throw invalid }
            return Character(scalar)
        }

        private mutating func parseHex4() throws(JSONSpellingParseError) -> UInt32 {
            guard bytes.count - index >= 4 else { throw invalid }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                let digit: UInt32
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
                default: throw invalid
                }
                value = value * 16 + digit
                index += 1
            }
            return value
        }

        private mutating func parseNumber() throws(JSONSpellingParseError) -> String {
            let start = index
            func digits(_ parser: inout Parser) -> Int {
                let first = parser.index
                while parser.index < parser.bytes.count,
                    (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(parser.bytes[parser.index])
                {
                    parser.index += 1
                }
                return parser.index - first
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count else { throw invalid }
            if bytes[index] == UInt8(ascii: "0") {
                index += 1
            } else {
                guard digits(&self) > 0 else { throw invalid }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard digits(&self) > 0 else { throw invalid }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard digits(&self) > 0 else { throw invalid }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
    }
}
