import Foundation

/// JSON as data. Objects keep key order (host configs are rewritten in
/// place) and numbers keep their source spelling so ids round-trip exactly.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: JSONObject? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let spelling) = self { return Int(spelling) }
        return nil
    }

    /// Every element is a string, or nil.
    public var stringArray: [String]? {
        guard let items = arrayValue else { return nil }
        let strings = items.compactMap(\.stringValue)
        return strings.count == items.count ? strings : nil
    }

    public static func int(_ value: Int) -> JSONValue { .number(String(value)) }

    public static func object(_ pairs: KeyValuePairs<String, JSONValue>) -> JSONValue {
        var object = JSONObject()
        for (key, value) in pairs { object[key] = value }
        return .object(object)
    }
}

/// Insertion-ordered object; equality ignores order.
public struct JSONObject: Sendable, Equatable {
    public private(set) var keys: [String] = []
    private var values: [String: JSONValue] = [:]

    public init() {}

    public subscript(key: String) -> JSONValue? {
        get { values[key] }
        set {
            if let newValue {
                if values.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if values.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var entries: [(key: String, value: JSONValue)] {
        keys.compactMap { key in values[key].map { (key, $0) } }
    }

    public var isEmpty: Bool { keys.isEmpty }

    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        lhs.values == rhs.values
    }
}

public enum JSONParseError: Error, Sendable, Equatable {
    case invalid(offset: Int)
    case tooDeep
}

extension JSONValue {
    /// Strict RFC 8259 by default. `lenient` accepts `//` and `/* */`
    /// comments and trailing commas (JSONC: VS Code, OpenCode).
    public static func parse(_ data: Data, maximumDepth: Int = 64, lenient: Bool = false) throws(JSONParseError) -> JSONValue {
        var parser = JSONParser(bytes: Array(data), maximumDepth: maximumDepth, lenient: lenient)
        return try parser.parseDocument()
    }

    public static func parse(_ text: String, maximumDepth: Int = 64, lenient: Bool = false) throws(JSONParseError) -> JSONValue {
        try parse(Data(text.utf8), maximumDepth: maximumDepth, lenient: lenient)
    }

    /// Compact single-line JSON (safe for newline-delimited framing).
    public var compactText: String {
        var output = ""
        Self.write(self, into: &output, indent: nil, level: 0)
        return output
    }

    /// Two-space indented JSON with a trailing newline.
    public var prettyText: String {
        var output = ""
        Self.write(self, into: &output, indent: "  ", level: 0)
        return output + "\n"
    }

    private static func write(_ value: JSONValue, into output: inout String, indent: String?, level: Int) {
        switch value {
        case .null: output += "null"
        case .bool(let flag): output += flag ? "true" : "false"
        case .number(let spelling): output += spelling
        case .string(let text): writeString(text, into: &output)
        case .array(let items):
            guard items.isEmpty == false else { output += "[]"; return }
            output += "["
            for (index, item) in items.enumerated() {
                if index > 0 { output += "," }
                newline(&output, indent: indent, level: level + 1)
                write(item, into: &output, indent: indent, level: level + 1)
            }
            newline(&output, indent: indent, level: level)
            output += "]"
        case .object(let object):
            guard object.isEmpty == false else { output += "{}"; return }
            output += "{"
            for (index, entry) in object.entries.enumerated() {
                if index > 0 { output += "," }
                newline(&output, indent: indent, level: level + 1)
                writeString(entry.key, into: &output)
                output += indent == nil ? ":" : ": "
                write(entry.value, into: &output, indent: indent, level: level + 1)
            }
            newline(&output, indent: indent, level: level)
            output += "}"
        }
    }

    private static func newline(_ output: inout String, indent: String?, level: Int) {
        guard let indent else { return }
        output += "\n" + String(repeating: indent, count: level)
    }

    /// JSON string contents (no surrounding quotes), matching `compactText`.
    static func escapedContent(_ text: String) -> String {
        var output = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case "\u{2028}": output += "\\u2028"
            case "\u{2029}": output += "\\u2029"
            case "\u{202A}": output += "\\u202a"
            case "\u{202B}": output += "\\u202b"
            case "\u{202C}": output += "\\u202c"
            case "\u{202D}": output += "\\u202d"
            case "\u{202E}": output += "\\u202e"
            case "\u{2066}": output += "\\u2066"
            case "\u{2067}": output += "\\u2067"
            case "\u{2068}": output += "\\u2068"
            case "\u{2069}": output += "\\u2069"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output
    }

    private static func writeString(_ text: String, into output: inout String) {
        output += "\""
        output += escapedContent(text)
        output += "\""
    }
}

private struct JSONParser {
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

    mutating func parseDocument() throws(JSONParseError) -> JSONValue {
        let value = try parseValue(depth: 0)
        try skipWhitespace()
        guard index == bytes.count else { throw .invalid(offset: index) }
        return value
    }

    private var invalid: JSONParseError { .invalid(offset: index) }

    private mutating func skipWhitespace() throws(JSONParseError) {
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

    private mutating func parseValue(depth: Int) throws(JSONParseError) -> JSONValue {
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

    private mutating func expect(_ word: String) throws(JSONParseError) {
        let literal = Array(word.utf8)
        guard bytes.count - index >= literal.count, Array(bytes[index..<index + literal.count]) == literal else {
            throw invalid
        }
        index += literal.count
    }

    private mutating func parseObject(depth: Int) throws(JSONParseError) -> JSONValue {
        index += 1
        var object = JSONObject()
        try skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(object)
        }
        while true {
            try skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw invalid }
            let key = try parseString()
            try skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw invalid }
            index += 1
            object[key] = try parseValue(depth: depth + 1)
            try skipWhitespace()
            guard index < bytes.count else { throw invalid }
            if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
            guard bytes[index] == UInt8(ascii: ",") else { throw invalid }
            index += 1
            if lenient {
                try skipWhitespace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
            }
        }
    }

    private mutating func parseArray(depth: Int) throws(JSONParseError) -> JSONValue {
        index += 1
        var items: [JSONValue] = []
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

    private mutating func parseString() throws(JSONParseError) -> String {
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

    private mutating func parseUnicodeEscape() throws(JSONParseError) -> Character {
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

    private mutating func parseHex4() throws(JSONParseError) -> UInt32 {
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

    private mutating func parseNumber() throws(JSONParseError) -> String {
        let start = index
        func digits(_ parser: inout JSONParser) -> Int {
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
