import Foundation

/// The `.env.schema` syntax tree, following Varlock's env-spec grammar
/// (packages/env-spec-parser/grammar.peggy) rule for rule, with the same
/// PEG semantics: ordered choice, greedy repetition, no re-trying. Values
/// are never resolved or expanded.
enum EnvSpec {
    enum Quote: Sendable, Equatable {
        case double
        case single
        case backtick
    }

    indirect enum Value: Sendable, Equatable {
        /// A static value without its quotes. Unquoted text is trimmed.
        case text(String, quote: Quote?)
        case call(String, [Argument])
        /// `{key=value, ...}`; every argument has a key.
        case object([Argument])
        case array([Value])
    }

    struct Argument: Sendable, Equatable {
        var key: String?
        var value: Value
    }

    struct Decorator: Sendable, Equatable {
        enum Form: Sendable, Equatable {
            /// `@name`
            case flag
            /// `@name=value`
            case value(Value)
            /// `@name(arguments)`
            case call([Argument])
        }

        var name: String
        var form: Form
    }

    enum Comment: Sendable, Equatable {
        /// The text after `#` and its leading spaces.
        case text(String)
        /// A line of decorators; stray words and a trailing `# comment` are dropped.
        case decorators([Decorator])
    }

    struct Item: Sendable, Equatable {
        var key: String
        var value: Value?
        var preComments: [Comment]
        var postComment: Comment?
    }

    enum Node: Sendable, Equatable {
        case item(Item)
        /// Comments ended by a blank line or a divider.
        case block([Comment])
        case divider
        case blank
    }

    struct File: Sendable, Equatable {
        var nodes: [Node]

        var items: [Item] {
            nodes.compactMap { node in
                if case .item(let item) = node { item } else { nil }
            }
        }
    }

    /// The line of the construct that does not parse. Carries no schema
    /// text, which may hold values.
    struct ParseError: Error, Sendable, Equatable {
        var line: Int
    }

    /// Bounds recursion through nested calls and literals.
    static let maximumDepth = 32

    /// Bounds the work, not only the depth: a failed nested call or literal
    /// is retried by every enclosing level, so unclosed `f(x,f(x,...` input
    /// would otherwise take exponential time. Each byte of input pays for this
    /// many calls or literals; well-formed input needs a small constant.
    static let nestedEntriesPerByte = 64
    static let nestedEntryAllowance = 4096

    static func parse(_ source: String) -> Result<File, ParseError> {
        var text = source.replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var parser = Parser(bytes: Array(text.utf8))
        return parser.file()
    }

    /// `text` when it is one whole function call, such as an unquoted value
    /// that followed `KEY = ` and so parsed as a string.
    static func functionCall(_ text: String) -> Value? {
        var parser = Parser(bytes: Array(text.utf8))
        guard let call = parser.functionCall(decorator: false), parser.position == parser.bytes.count,
            parser.exhausted == false
        else { return nil }
        return call
    }
}

extension EnvSpec {
    /// Recursive descent over UTF-8. Every rule restores the position when it
    /// fails, so a caller can try the next alternative.
    struct Parser {
        let bytes: [UInt8]
        var position = 0
        var depth = 0
        var budget: Int
        /// Sticky: once the work budget runs out, no nested rule starts and the
        /// parse is refused, so a fallback alternative cannot misread the input.
        var exhausted = false

        init(bytes: [UInt8]) {
            self.bytes = bytes
            budget = bytes.count * EnvSpec.nestedEntriesPerByte + EnvSpec.nestedEntryAllowance
        }

        // MARK: File structure

        mutating func file() -> Result<File, ParseError> {
            var nodes: [Node] = []
            while position < bytes.count {
                if let item = configItem() {
                    nodes.append(.item(item))
                } else if divider() {
                    nodes.append(.divider)
                } else if let comments = commentBlock() {
                    nodes.append(.block(comments))
                } else if blankLine() {
                    nodes.append(.blank)
                } else {
                    return .failure(ParseError(line: line(at: position)))
                }
                if exhausted { return .failure(ParseError(line: line(at: position))) }
            }
            return .success(File(nodes: nodes))
        }

        /// `_ "\n"` or `__ !.`
        mutating func blankLine() -> Bool {
            let start = position
            skipSpaces()
            if take(.newline) || (position == bytes.count && position > start) { return true }
            return fail(start)
        }

        /// grammar.peggy `ConfigItem`.
        mutating func configItem() -> Item? {
            let start = position
            var preComments: [Comment] = []
            while true {
                let lineStart = position
                guard let comment = decoratorComment() ?? comment(), take(.newline) else {
                    position = lineStart
                    break
                }
                preComments.append(comment)
            }
            let beforeExport = position
            skipSpaces()
            if take("export ") { skipSpaces() } else { position = beforeExport }
            skipSpaces()
            guard let key = configKey() else { return fail(start) }
            skipSpaces()
            guard take(.equals) else { return fail(start) }
            let value = configValue()
            skipSpaces()
            let postComment = decoratorComment() ?? comment()
            guard lineEnd() else { return fail(start) }
            return Item(key: key, value: value, preComments: preComments, postComment: postComment)
        }

        /// `[a-zA-Z_][a-zA-Z0-9_.-]*`
        mutating func configKey() -> String? {
            guard let first = current, first.isLetter || first == .underscore else { return nil }
            let start = position
            position += 1
            while let byte = current, byte.isLetter || byte.isDigit || byte == .underscore || byte == .dot || byte == .dash {
                position += 1
            }
            return text(start..<position)
        }

        /// grammar.peggy `CommentBlock`: comments, then a divider or a blank line.
        mutating func commentBlock() -> [Comment]? {
            let start = position
            var comments: [Comment] = []
            while true {
                let lineStart = position
                guard let comment = decoratorComment() ?? comment(), lineEnd() else {
                    position = lineStart
                    break
                }
                comments.append(comment)
            }
            guard comments.isEmpty == false, divider() || lineEnd() else { return fail(start) }
            return comments
        }

        /// `"#" _ [-=*#]{3,} [^\n]* _n`
        mutating func divider() -> Bool {
            let start = position
            guard take(.hash) else { return false }
            skipSpaces()
            var marks = 0
            while let byte = current, byte == .dash || byte == .equals || byte == .star || byte == .hash {
                marks += 1
                position += 1
            }
            guard marks >= 3 else { return fail(start) }
            skipToLineEnd()
            guard lineEnd() else { return fail(start) }
            return true
        }

        /// grammar.peggy `Comment`: any `#` line that is not a divider and
        /// does not start with `@`.
        mutating func comment() -> Comment? {
            let start = position
            if divider() {
                position = start
                return nil
            }
            guard take(.hash) else { return nil }
            skipSpaces()
            guard current != .at else { return .text("") }
            let contentStart = position
            skipToLineEnd()
            return .text(text(contentStart..<position))
        }

        /// grammar.peggy `DecoratorComment`.
        mutating func decoratorComment() -> Comment? {
            let start = position
            guard take(.hash) else { return nil }
            skipSpaces()
            guard let first = decorator() else { return fail(start) }
            var decorators = [first]
            while true {
                let restStart = position
                guard skipSpaces() > 0 else { break }
                if let next = decorator() {
                    decorators.append(next)
                } else if strayText() == false {
                    position = restStart
                    break
                }
            }
            let beforePost = position
            skipSpaces()
            if take(.hash) { skipToLineEnd() } else { position = beforePost }
            skipSpaces()
            return .decorators(decorators)
        }

        /// Words after a decorator that are not decorators (Varlock warns on them).
        mutating func strayText() -> Bool {
            guard word() else { return false }
            while true {
                let start = position
                guard skipSpaces() > 0, word() else {
                    position = start
                    return true
                }
            }
        }

        /// `[^ \t@#\n] [^ \t@\n]*`
        mutating func word() -> Bool {
            guard let first = current, first.isSpace == false, first != .at, first != .hash, first != .newline else {
                return false
            }
            position += 1
            while let byte = current, byte.isSpace == false, byte != .at, byte != .newline { position += 1 }
            return true
        }

        /// grammar.peggy `Decorator`.
        mutating func decorator() -> Decorator? {
            let start = position
            guard take(.at), let name = decoratorName() else { return fail(start) }
            if let arguments = arguments(decorator: true) { return Decorator(name: name, form: .call(arguments)) }
            let beforeValue = position
            if take(.equals), let value = decoratorValue() { return Decorator(name: name, form: .value(value)) }
            position = beforeValue
            return Decorator(name: name, form: .flag)
        }

        /// `[a-zA-Z] [^ \t\n=()#@]*`
        mutating func decoratorName() -> String? {
            guard let first = current, first.isLetter else { return nil }
            let start = position
            position += 1
            while let byte = current, byte.isSpace == false, byte != .newline, byte != .equals, byte != .openParen,
                byte != .closeParen, byte != .hash, byte != .at
            {
                position += 1
            }
            return text(start..<position)
        }

        /// grammar.peggy `DecoratorValue`.
        mutating func decoratorValue() -> Value? {
            if let object = object(decorator: true) { return object }
            if let array = array(decorator: true) { return array }
            if let call = functionCall(decorator: true) { return call }
            if let quoted = quotedString() { return quoted }
            guard let first = current, first.isQuote == false else { return nil }
            return unquoted { $0 != .hash && $0 != .space && $0 != .newline }
        }

        // MARK: Values

        /// grammar.peggy `ConfigItemValue`.
        mutating func configValue() -> Value? {
            if let call = functionCall(decorator: false) { return call }
            if let object = object(decorator: false) { return object }
            if let array = array(decorator: false) { return array }
            if let multiLine = multiLineString() { return multiLine }
            if let quoted = quotedString() { return quoted }
            let start = position
            skipSpaces()
            guard let first = current, first.isQuote == false,
                let value = unquoted(where: { $0 != .hash && $0 != .newline })
            else { return fail(start) }
            return value
        }

        /// `FunctionName FunctionArgs`, `FunctionName = [a-zA-Z][a-zA-Z0-9_]*`.
        mutating func functionCall(decorator: Bool) -> Value? {
            let start = position
            guard let first = current, first.isLetter else { return nil }
            position += 1
            while let byte = current, byte.isLetter || byte.isDigit || byte == .underscore { position += 1 }
            let name = text(start..<position)
            guard let arguments = arguments(decorator: decorator) else { return fail(start) }
            return .call(name, arguments)
        }

        /// grammar.peggy `FunctionArgs` / `DecoratorFunctionArgs`.
        mutating func arguments(decorator: Bool) -> [Argument]? {
            let start = position
            guard take(.openParen), enter() else { return fail(start) }
            defer { depth -= 1 }
            skipWhitespace(decorator: decorator)
            let arguments = separated(decorator: decorator) { parser in parser.argument(decorator: decorator) }
            guard closeList(.closeParen, decorator: decorator) else { return fail(start) }
            return arguments
        }

        /// `key "=" value` or a positional value.
        mutating func argument(decorator: Bool) -> Argument? {
            let start = position
            if let key = argumentKey(), take(.equals), let value = argumentValue(decorator: decorator) {
                return Argument(key: key, value: value)
            }
            position = start
            return argumentValue(decorator: decorator).map { Argument(key: nil, value: $0) }
        }

        /// `[a-zA-Z] [a-zA-Z0-9_]*`
        mutating func argumentKey() -> String? {
            guard let first = current, first.isLetter else { return nil }
            let start = position
            position += 1
            while let byte = current, byte.isLetter || byte.isDigit || byte == .underscore { position += 1 }
            return text(start..<position)
        }

        /// grammar.peggy `FunctionArgValue` / `DecoratorFunctionArgValue`.
        mutating func argumentValue(decorator: Bool) -> Value? {
            if let object = object(decorator: decorator) { return object }
            if let array = array(decorator: decorator) { return array }
            if let call = functionCall(decorator: decorator) { return call }
            if let quoted = quotedString() { return quoted }
            return unquoted { $0 != .space && $0 != .newline && $0 != .comma && $0 != .closeParen }
        }

        /// grammar.peggy `ObjectLiteral` / `DecoratorObjectLiteral`.
        mutating func object(decorator: Bool) -> Value? {
            let start = position
            guard take(.openBrace), enter() else { return fail(start) }
            defer { depth -= 1 }
            skipWhitespace(decorator: decorator)
            let pairs = separated(decorator: decorator) { parser -> Argument? in
                let pairStart = parser.position
                guard let key = parser.argumentKey() else { return nil }
                parser.skipSpaces()
                guard parser.take(.equals) else { return parser.fail(pairStart) }
                parser.skipSpaces()
                guard let value = parser.elementValue(decorator: decorator) else { return parser.fail(pairStart) }
                return Argument(key: key, value: value)
            }
            guard closeList(.closeBrace, decorator: decorator) else { return fail(start) }
            return .object(pairs)
        }

        /// grammar.peggy `ArrayLiteral` / `DecoratorArrayLiteral`.
        mutating func array(decorator: Bool) -> Value? {
            let start = position
            guard take(.openBracket), enter() else { return fail(start) }
            defer { depth -= 1 }
            skipWhitespace(decorator: decorator)
            let values = separated(decorator: decorator) { parser in parser.elementValue(decorator: decorator) }
            guard closeList(.closeBracket, decorator: decorator) else { return fail(start) }
            return .array(values)
        }

        /// grammar.peggy `LiteralElementValue` / `DecoratorLiteralElementValue`.
        mutating func elementValue(decorator: Bool) -> Value? {
            if let object = object(decorator: decorator) { return object }
            if let array = array(decorator: decorator) { return array }
            if let call = functionCall(decorator: decorator) { return call }
            if let quoted = quotedString() { return quoted }
            let start = position
            // A `${` with no `}` before the line ends leaves every later `${`
            // on that line unclosed too, so the scan is not repeated.
            var unclosedUntil = 0
            while let byte = current {
                let reference = position
                if reference >= unclosedUntil, take("${") {
                    while let inner = current, inner != .closeBrace, inner != .newline { position += 1 }
                    if take(.closeBrace) { continue }
                    unclosedUntil = position
                    position = reference
                }
                guard byte != .space, byte != .newline, byte != .comma, byte != .closeParen, byte != .closeBrace,
                    byte != .closeBracket
                else { break }
                position += 1
            }
            guard position > start else { return nil }
            return .text(text(start..<position).trimmed, quote: nil)
        }

        /// `X|0.., ws "," ws|`: a separator is only consumed with the element after it.
        mutating func separated<T>(decorator: Bool, _ element: (inout Parser) -> T?) -> [T] {
            guard let first = element(&self) else { return [] }
            var elements = [first]
            while true {
                let start = position
                skipWhitespace(decorator: decorator)
                guard take(.comma) else {
                    position = start
                    break
                }
                skipWhitespace(decorator: decorator)
                guard let next = element(&self) else {
                    position = start
                    break
                }
                elements.append(next)
            }
            return elements
        }

        /// `(ws ",")? ws <close>`
        mutating func closeList(_ close: UInt8, decorator: Bool) -> Bool {
            let start = position
            skipWhitespace(decorator: decorator)
            if take(.comma) == false { position = start }
            skipWhitespace(decorator: decorator)
            return take(close)
        }

        /// One-line `"..."`, `'...'`, or `` `...` ``; `\` escapes only the quote.
        mutating func quotedString() -> Value? {
            guard let quote = current, quote.isQuote else { return nil }
            let start = position
            position += 1
            while let byte = current, byte != quote, byte != .newline {
                position += byte == .backslash && peek(1) == quote ? 2 : 1
            }
            guard take(quote) else { return fail(start) }
            return quotedValue(start..<position, fence: 1)
        }

        /// grammar.peggy `multiLineString`: a quote that spans at least one newline.
        mutating func multiLineString() -> Value? {
            for (fence, quote) in [(1, UInt8.singleQuote), (1, .doubleQuote), (3, .doubleQuote), (3, .backtick)] {
                if let value = multiLine(quote, fence: fence) { return value }
            }
            return nil
        }

        mutating func multiLine(_ quote: UInt8, fence: Int) -> Value? {
            let start = position
            let marker = [UInt8](repeating: quote, count: fence)
            guard take(marker) else { return nil }
            var newlines = 0
            while position < bytes.count {
                if bytes[position] == .backslash, matches([.backslash] + marker) {
                    position += fence + 1
                } else if matches(marker) {
                    break
                } else {
                    if bytes[position] == .newline { newlines += 1 }
                    position += 1
                }
            }
            guard newlines > 0, take(marker) else { return fail(start) }
            return quotedValue(start..<position, fence: fence)
        }

        func quotedValue(_ range: Range<Int>, fence: Int) -> Value {
            let quote = bytes[range.lowerBound]
            let inner = text((range.lowerBound + fence)..<(range.upperBound - fence))
            let mark = String(UnicodeScalar(quote))
            let kind: Quote = quote == .doubleQuote ? .double : quote == .singleQuote ? .single : .backtick
            return .text(inner.replacingOccurrences(of: "\\" + mark, with: mark), quote: kind)
        }

        /// Unquoted text of at least one byte matching `allowed`, trimmed.
        mutating func unquoted(where allowed: (UInt8) -> Bool) -> Value? {
            let start = position
            while let byte = current, allowed(byte) { position += 1 }
            guard position > start else { return nil }
            return .text(text(start..<position).trimmed, quote: nil)
        }

        // MARK: Whitespace

        /// `_valWs` (newlines and `#` comments) or `_decWs` (continuation
        /// lines must start with `#`; `#` then a letter or digit is a value).
        mutating func skipWhitespace(decorator: Bool) {
            while let byte = current {
                if byte.isSpace {
                    position += 1
                } else if decorator {
                    guard continuation() else { return }
                } else if byte == .newline {
                    position += 1
                } else if byte == .hash {
                    skipToLineEnd()
                } else {
                    return
                }
            }
        }

        /// `("#" ![a-zA-Z0-9] [^\n]*)? "\n" [ \t]* "#" [ \t]*`
        mutating func continuation() -> Bool {
            let start = position
            if current == .hash, peek(1).map({ $0.isLetter || $0.isDigit }) != true { skipToLineEnd() }
            guard take(.newline) else { return fail(start) }
            skipSpaces()
            guard take(.hash) else { return fail(start) }
            skipSpaces()
            return true
        }

        /// `_n`: optional spaces, then a newline or the end.
        mutating func lineEnd() -> Bool {
            let start = position
            skipSpaces()
            if take(.newline) || position == bytes.count { return true }
            return fail(start)
        }

        @discardableResult
        mutating func skipSpaces() -> Int {
            let start = position
            while let byte = current, byte.isSpace { position += 1 }
            return position - start
        }

        mutating func skipToLineEnd() {
            while let byte = current, byte != .newline { position += 1 }
        }

        // MARK: Primitives

        var current: UInt8? { position < bytes.count ? bytes[position] : nil }

        func peek(_ offset: Int) -> UInt8? {
            position + offset < bytes.count ? bytes[position + offset] : nil
        }

        func matches(_ expected: [UInt8]) -> Bool {
            position + expected.count <= bytes.count && bytes[position..<(position + expected.count)].elementsEqual(expected)
        }

        mutating func take(_ byte: UInt8) -> Bool {
            guard current == byte else { return false }
            position += 1
            return true
        }

        mutating func take(_ expected: [UInt8]) -> Bool {
            guard matches(expected) else { return false }
            position += expected.count
            return true
        }

        mutating func take(_ expected: String) -> Bool { take(Array(expected.utf8)) }

        mutating func enter() -> Bool {
            guard exhausted == false, depth < EnvSpec.maximumDepth else { return false }
            budget -= 1
            guard budget >= 0 else {
                exhausted = true
                return false
            }
            depth += 1
            return true
        }

        /// Restores `start` so the caller can try its next alternative.
        mutating func fail<T>(_ start: Int) -> T? {
            position = start
            return nil
        }

        mutating func fail(_ start: Int) -> Bool {
            position = start
            return false
        }

        func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }

        func line(at offset: Int) -> Int {
            bytes[..<min(offset, bytes.count)].reduce(1) { $1 == .newline ? $0 + 1 : $0 }
        }
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension UInt8 {
    fileprivate static let tab: UInt8 = 9
    fileprivate static let newline: UInt8 = 10
    fileprivate static let space: UInt8 = 32
    fileprivate static let doubleQuote: UInt8 = 34
    fileprivate static let hash: UInt8 = 35
    fileprivate static let singleQuote: UInt8 = 39
    fileprivate static let openParen: UInt8 = 40
    fileprivate static let closeParen: UInt8 = 41
    fileprivate static let star: UInt8 = 42
    fileprivate static let comma: UInt8 = 44
    fileprivate static let dash: UInt8 = 45
    fileprivate static let dot: UInt8 = 46
    fileprivate static let equals: UInt8 = 61
    fileprivate static let at: UInt8 = 64
    fileprivate static let openBracket: UInt8 = 91
    fileprivate static let backslash: UInt8 = 92
    fileprivate static let closeBracket: UInt8 = 93
    fileprivate static let underscore: UInt8 = 95
    fileprivate static let backtick: UInt8 = 96
    fileprivate static let openBrace: UInt8 = 123
    fileprivate static let closeBrace: UInt8 = 125

    fileprivate var isLetter: Bool { (65...90).contains(self) || (97...122).contains(self) }
    fileprivate var isDigit: Bool { (48...57).contains(self) }
    fileprivate var isSpace: Bool { self == .space || self == .tab }
    fileprivate var isQuote: Bool { self == .doubleQuote || self == .singleQuote || self == .backtick }
}
