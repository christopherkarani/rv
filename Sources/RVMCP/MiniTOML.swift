import Foundation

/// Just enough TOML to read MCP server tables out of a Codex config:
/// tables, dotted and quoted keys, all four string forms, arrays and inline
/// tables. Other scalars (numbers, booleans, dates) are kept as raw text.
/// Array-of-tables (`[[x]]`) content is parsed and dropped.
indirect enum TOMLValue: Equatable {
    case string(String)
    case array([TOMLValue])
    case table([String: TOMLValue])
    case other(String)

    subscript(key: String) -> TOMLValue? {
        if case .table(let table) = self { return table[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    var stringArray: [String]? {
        guard case .array(let items) = self else { return nil }
        let strings = items.compactMap(\.stringValue)
        return strings.count == items.count ? strings : nil
    }

    var tableValue: [String: TOMLValue]? {
        if case .table(let table) = self { return table }
        return nil
    }

    var boolValue: Bool? {
        if case .other(let raw) = self { return raw == "true" ? true : raw == "false" ? false : nil }
        return nil
    }
}

struct MiniTOMLError: Error, Equatable {
    let line: Int
}

enum MiniTOML {
    static func parse(_ text: String) throws(MiniTOMLError) -> [String: TOMLValue] {
        var scanner = TOMLScanner(bytes: Array(text.utf8))
        return try scanner.document()
    }
}

private struct TOMLScanner {
    let bytes: [UInt8]
    var index = 0
    var line = 1

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var failure: MiniTOMLError { MiniTOMLError(line: line) }

    var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    func peek(_ offset: Int) -> UInt8? {
        index + offset < bytes.count ? bytes[index + offset] : nil
    }

    mutating func advance() {
        if bytes[index] == 0x0A { line += 1 }
        index += 1
    }

    mutating func skipSpaces() {
        while let byte = current, byte == 0x20 || byte == 0x09 { advance() }
    }

    mutating func skipComment() {
        if current == UInt8(ascii: "#") {
            while let byte = current, byte != 0x0A { advance() }
        }
    }

    /// Spaces, comments and newlines (inside arrays).
    mutating func skipBlank() {
        while let byte = current {
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                advance()
            } else if byte == UInt8(ascii: "#") {
                skipComment()
            } else {
                return
            }
        }
    }

    mutating func endOfLine() throws(MiniTOMLError) {
        skipSpaces()
        skipComment()
        if current == 0x0D { advance() }
        guard current == nil || current == 0x0A else { throw failure }
        if current == 0x0A { advance() }
    }

    mutating func document() throws(MiniTOMLError) -> [String: TOMLValue] {
        var root: [String: TOMLValue] = [:]
        var path: [String]? = []
        while true {
            skipBlank()
            guard let byte = current else { return root }
            if byte == UInt8(ascii: "[") {
                advance()
                let isArrayTable = current == UInt8(ascii: "[")
                if isArrayTable { advance() }
                skipSpaces()
                let keys = try key()
                skipSpaces()
                guard current == UInt8(ascii: "]") else { throw failure }
                advance()
                if isArrayTable {
                    guard current == UInt8(ascii: "]") else { throw failure }
                    advance()
                    path = nil
                } else {
                    path = keys
                    try Self.ensureTable(at: keys, in: &root, failure: failure)
                }
                try endOfLine()
            } else {
                let keys = try key()
                skipSpaces()
                guard current == UInt8(ascii: "=") else { throw failure }
                advance()
                skipSpaces()
                let parsed = try value()
                try endOfLine()
                if let path {
                    try Self.insert(parsed, at: path + keys, in: &root, failure: failure)
                }
            }
        }
    }

    mutating func key() throws(MiniTOMLError) -> [String] {
        var parts: [String] = []
        while true {
            skipSpaces()
            guard let byte = current else { throw failure }
            if byte == UInt8(ascii: "\"") {
                parts.append(try basicString())
            } else if byte == UInt8(ascii: "'") {
                parts.append(try literalString())
            } else {
                let start = index
                while let next = current, Self.isBareKey(next) { advance() }
                guard index > start else { throw failure }
                parts.append(String(decoding: bytes[start..<index], as: UTF8.self))
            }
            skipSpaces()
            guard current == UInt8(ascii: ".") else { return parts }
            advance()
        }
    }

    static func isBareKey(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "_")
            || byte == UInt8(ascii: "-")
    }

    mutating func value() throws(MiniTOMLError) -> TOMLValue {
        guard let byte = current else { throw failure }
        switch byte {
        case UInt8(ascii: "\""):
            if peek(1) == UInt8(ascii: "\""), peek(2) == UInt8(ascii: "\"") { return .string(try multilineString(literal: false)) }
            return .string(try basicString())
        case UInt8(ascii: "'"):
            if peek(1) == UInt8(ascii: "'"), peek(2) == UInt8(ascii: "'") { return .string(try multilineString(literal: true)) }
            return .string(try literalString())
        case UInt8(ascii: "["):
            advance()
            var items: [TOMLValue] = []
            while true {
                skipBlank()
                if current == UInt8(ascii: "]") { advance(); return .array(items) }
                items.append(try value())
                skipBlank()
                if current == UInt8(ascii: ",") { advance(); continue }
                guard current == UInt8(ascii: "]") else { throw failure }
                advance()
                return .array(items)
            }
        case UInt8(ascii: "{"):
            advance()
            var table: [String: TOMLValue] = [:]
            skipBlank()
            if current == UInt8(ascii: "}") { advance(); return .table(table) }
            while true {
                skipBlank()
                let keys = try key()
                skipSpaces()
                guard current == UInt8(ascii: "=") else { throw failure }
                advance()
                skipSpaces()
                try Self.insert(try value(), at: keys, in: &table, failure: failure)
                skipBlank()
                if current == UInt8(ascii: ",") { advance(); continue }
                guard current == UInt8(ascii: "}") else { throw failure }
                advance()
                return .table(table)
            }
        default:
            let start = index
            while let next = current, next != UInt8(ascii: ","), next != UInt8(ascii: "]"), next != UInt8(ascii: "}"),
                next != 0x0A, next != 0x0D, next != UInt8(ascii: "#")
            {
                advance()
            }
            let raw = String(decoding: bytes[start..<index], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            guard raw.isEmpty == false else { throw failure }
            return .other(raw)
        }
    }

    mutating func basicString() throws(MiniTOMLError) -> String {
        advance()
        var output: [UInt8] = []
        while let byte = current {
            guard byte != 0x0A else { throw failure }
            advance()
            switch byte {
            case UInt8(ascii: "\""):
                return String(decoding: output, as: UTF8.self)
            case UInt8(ascii: "\\"):
                try escape(into: &output)
            default:
                output.append(byte)
            }
        }
        throw failure
    }

    mutating func literalString() throws(MiniTOMLError) -> String {
        advance()
        let start = index
        while let byte = current, byte != UInt8(ascii: "'") {
            guard byte != 0x0A else { throw failure }
            advance()
        }
        guard current == UInt8(ascii: "'") else { throw failure }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        advance()
        return text
    }

    mutating func multilineString(literal: Bool) throws(MiniTOMLError) -> String {
        let quote = literal ? UInt8(ascii: "'") : UInt8(ascii: "\"")
        advance(); advance(); advance()
        if current == 0x0D { advance() }
        if current == 0x0A { advance() }
        var output: [UInt8] = []
        while let byte = current {
            if byte == quote, peek(1) == quote, peek(2) == quote {
                advance(); advance(); advance()
                while current == quote { output.append(quote); advance() }
                return String(decoding: output, as: UTF8.self)
            }
            advance()
            if byte == UInt8(ascii: "\\"), literal == false {
                if let next = current, next == 0x0A || next == 0x0D || next == 0x20 || next == 0x09 {
                    while let blank = current, blank == 0x0A || blank == 0x0D || blank == 0x20 || blank == 0x09 { advance() }
                } else {
                    try escape(into: &output)
                }
            } else {
                output.append(byte)
            }
        }
        throw failure
    }

    mutating func escape(into output: inout [UInt8]) throws(MiniTOMLError) {
        guard let byte = current else { throw failure }
        advance()
        switch byte {
        case UInt8(ascii: "\""): output.append(0x22)
        case UInt8(ascii: "\\"): output.append(0x5C)
        case UInt8(ascii: "b"): output.append(0x08)
        case UInt8(ascii: "f"): output.append(0x0C)
        case UInt8(ascii: "n"): output.append(0x0A)
        case UInt8(ascii: "r"): output.append(0x0D)
        case UInt8(ascii: "t"): output.append(0x09)
        case UInt8(ascii: "e"): output.append(0x1B)
        case UInt8(ascii: "u"), UInt8(ascii: "U"):
            let width = byte == UInt8(ascii: "u") ? 4 : 8
            guard bytes.count - index >= width,
                let code = UInt32(String(decoding: bytes[index..<index + width], as: UTF8.self), radix: 16),
                let scalar = Unicode.Scalar(code)
            else { throw failure }
            for _ in 0..<width { advance() }
            output += Array(String(Character(scalar)).utf8)
        default:
            throw failure
        }
    }

    static func ensureTable(
        at path: [String], in table: inout [String: TOMLValue], failure: MiniTOMLError
    ) throws(MiniTOMLError) {
        guard let head = path.first else { return }
        var child: [String: TOMLValue]
        switch table[head] {
        case nil: child = [:]
        case .table(let existing)?: child = existing
        default: throw failure
        }
        try ensureTable(at: Array(path.dropFirst()), in: &child, failure: failure)
        table[head] = .table(child)
    }

    static func insert(
        _ value: TOMLValue, at path: [String], in table: inout [String: TOMLValue], failure: MiniTOMLError
    ) throws(MiniTOMLError) {
        guard let head = path.first else { throw failure }
        if path.count == 1 {
            table[head] = value
            return
        }
        var child: [String: TOMLValue]
        switch table[head] {
        case nil: child = [:]
        case .table(let existing)?: child = existing
        default: throw failure
        }
        try insert(value, at: Array(path.dropFirst()), in: &child, failure: failure)
        table[head] = .table(child)
    }
}
