import Foundation

/// Why a hook payload failed the strict JSON screen.
public enum StrictJSONRejection: Equatable, Sendable {
    /// An object holds the same key twice (after unescaping).
    case duplicateKey
    /// Nesting is deeper than `StrictHookJSON.maxDepth`.
    case tooDeep
    /// Not one well-formed RFC 8259 JSON text.
    case syntax
}

/// Strict screen every hook payload passes before a codec decodes it.
///
/// `JSONDecoder` keeps the FIRST value of a repeated key, while Node and
/// Python keep the LAST, so `{"command":"ls","command":"rm -rf /"}` reads
/// as `ls` to rv and as `rm -rf /` to anything else that parses the same
/// bytes (a host, an adapter, a log reader). No parser's choice is safe to
/// rely on: a document with a duplicate key anywhere is refused outright.
///
/// Keys compare after escape decoding (`"command"` is `command`)
/// with Swift `String` equality, which also folds canonically equivalent
/// spellings together — strictly more duplicates than any byte-exact
/// parser sees. A lone surrogate escape decodes to U+FFFD, so two
/// different lone surrogates in sibling keys also count as a duplicate.
/// Refusing more is the fail-closed direction.
///
/// The scanner is a full RFC 8259 tokenizer (bounded depth, no
/// recursion), so a document it accepts has exactly the structure the
/// decoder sees; anything it cannot read is refused rather than guessed.
public enum StrictHookJSON {
    /// Deeper documents are refused. Hook envelopes nest a few levels.
    public static let maxDepth = 512

    /// Nil when `text` is one strict JSON document with no duplicate key.
    public static func rejection(_ text: String) -> StrictJSONRejection? {
        var text = text
        return text.withUTF8 { rejection(bytes: $0) }
    }

    /// The UTF-8 bytes of `stdin` when it passes the strict screen.
    static func screenedData(_ stdin: String) -> Data? {
        guard rejection(stdin) == nil else { return nil }
        return stdin.data(using: .utf8)
    }

    static func rejection(bytes: UnsafeBufferPointer<UInt8>) -> StrictJSONRejection? {
        var scanner = Scanner(bytes: bytes)
        return scanner.run()
    }

    private enum Container {
        case object(Set<String>)
        case array
    }

    private struct Scanner {
        let bytes: UnsafeBufferPointer<UInt8>
        var index = 0
        var stack: [Container] = []

        init(bytes: UnsafeBufferPointer<UInt8>) {
            self.bytes = bytes
            // A UTF-8 byte-order mark is tolerated before the document.
            if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
                index = 3
            }
        }

        mutating func run() -> StrictJSONRejection? {
            skipWhitespace()
            if let failure = value() { return failure }
            skipWhitespace()
            return index == bytes.count ? nil : .syntax
        }

        private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

        private mutating func skipWhitespace() {
            while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                index += 1
            }
        }

        /// Parses one value, iteratively for containers.
        private mutating func value() -> StrictJSONRejection? {
            let baseDepth = stack.count
            var needValue = true
            while true {
                if needValue {
                    skipWhitespace()
                    guard let byte = current else { return .syntax }
                    switch byte {
                    case UInt8(ascii: "{"):
                        guard stack.count < StrictHookJSON.maxDepth else { return .tooDeep }
                        index += 1
                        skipWhitespace()
                        if current == UInt8(ascii: "}") {
                            index += 1
                            needValue = false
                        } else {
                            stack.append(.object([]))
                            if let failure = key() { return failure }
                            continue
                        }
                    case UInt8(ascii: "["):
                        guard stack.count < StrictHookJSON.maxDepth else { return .tooDeep }
                        index += 1
                        skipWhitespace()
                        if current == UInt8(ascii: "]") {
                            index += 1
                            needValue = false
                        } else {
                            stack.append(.array)
                            continue
                        }
                    case UInt8(ascii: "\""):
                        guard skipString() else { return .syntax }
                        needValue = false
                    case UInt8(ascii: "t"):
                        guard literal("true") else { return .syntax }
                        needValue = false
                    case UInt8(ascii: "f"):
                        guard literal("false") else { return .syntax }
                        needValue = false
                    case UInt8(ascii: "n"):
                        guard literal("null") else { return .syntax }
                        needValue = false
                    default:
                        guard number() else { return .syntax }
                        needValue = false
                    }
                }
                // A value just ended: close containers or move to the next member.
                guard stack.count > baseDepth else { return nil }
                skipWhitespace()
                guard let byte = current else { return .syntax }
                switch stack[stack.count - 1] {
                case .object:
                    if byte == UInt8(ascii: ",") {
                        index += 1
                        if let failure = key() { return failure }
                        needValue = true
                    } else if byte == UInt8(ascii: "}") {
                        index += 1
                        stack.removeLast()
                        needValue = false
                    } else {
                        return .syntax
                    }
                case .array:
                    if byte == UInt8(ascii: ",") {
                        index += 1
                        needValue = true
                    } else if byte == UInt8(ascii: "]") {
                        index += 1
                        stack.removeLast()
                        needValue = false
                    } else {
                        return .syntax
                    }
                }
            }
        }

        /// Reads `"key" :` for the innermost object and records the key.
        private mutating func key() -> StrictJSONRejection? {
            skipWhitespace()
            guard current == UInt8(ascii: "\""), let name = decodeString() else { return .syntax }
            guard case .object(var keys) = stack[stack.count - 1] else { return .syntax }
            // Release the stack's copy so the insert does not copy the set.
            stack[stack.count - 1] = .array
            guard keys.insert(name).inserted else { return .duplicateKey }
            stack[stack.count - 1] = .object(keys)
            skipWhitespace()
            guard current == UInt8(ascii: ":") else { return .syntax }
            index += 1
            return nil
        }

        private mutating func literal(_ word: StaticString) -> Bool {
            let count = word.utf8CodeUnitCount
            guard bytes.count - index >= count else { return false }
            let expected = UnsafeBufferPointer(start: word.utf8Start, count: count)
            for offset in 0..<count where bytes[index + offset] != expected[offset] {
                return false
            }
            index += count
            return true
        }

        private mutating func number() -> Bool {
            if current == UInt8(ascii: "-") { index += 1 }
            guard let first = current, isDigit(first) else { return false }
            index += 1
            if first != UInt8(ascii: "0") {
                while let byte = current, isDigit(byte) { index += 1 }
            }
            if current == UInt8(ascii: ".") {
                index += 1
                guard let byte = current, isDigit(byte) else { return false }
                while let byte = current, isDigit(byte) { index += 1 }
            }
            if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
                index += 1
                if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { index += 1 }
                guard let byte = current, isDigit(byte) else { return false }
                while let byte = current, isDigit(byte) { index += 1 }
            }
            return true
        }

        /// Skips a string value, validating its escapes and control bytes.
        private mutating func skipString() -> Bool {
            index += 1
            while let byte = current {
                switch byte {
                case UInt8(ascii: "\""):
                    index += 1
                    return true
                case UInt8(ascii: "\\"):
                    index += 1
                    guard let escaped = current else { return false }
                    if escaped == UInt8(ascii: "u") {
                        guard hex4(at: index + 1) != nil else { return false }
                        index += 5
                    } else {
                        guard isSimpleEscape(escaped) else { return false }
                        index += 1
                    }
                case 0x00..<0x20:
                    return false
                default:
                    index += 1
                }
            }
            return false
        }

        /// Decodes a string (the cursor is on its opening quote).
        private mutating func decodeString() -> String? {
            index += 1
            var units: [UInt16] = []
            var runStart = index
            func flushRun(_ end: Int) {
                guard end > runStart else { return }
                let run = UnsafeBufferPointer(rebasing: bytes[runStart..<end])
                units.append(contentsOf: String(decoding: run, as: UTF8.self).utf16)
            }
            while let byte = current {
                switch byte {
                case UInt8(ascii: "\""):
                    flushRun(index)
                    index += 1
                    return String(decoding: units, as: UTF16.self)
                case UInt8(ascii: "\\"):
                    flushRun(index)
                    index += 1
                    guard let escaped = current else { return nil }
                    switch escaped {
                    case UInt8(ascii: "u"):
                        guard let unit = hex4(at: index + 1) else { return nil }
                        units.append(unit)
                        index += 5
                    case UInt8(ascii: "\""): units.append(0x22); index += 1
                    case UInt8(ascii: "\\"): units.append(0x5C); index += 1
                    case UInt8(ascii: "/"): units.append(0x2F); index += 1
                    case UInt8(ascii: "b"): units.append(0x08); index += 1
                    case UInt8(ascii: "f"): units.append(0x0C); index += 1
                    case UInt8(ascii: "n"): units.append(0x0A); index += 1
                    case UInt8(ascii: "r"): units.append(0x0D); index += 1
                    case UInt8(ascii: "t"): units.append(0x09); index += 1
                    default: return nil
                    }
                    runStart = index
                case 0x00..<0x20:
                    return nil
                default:
                    index += 1
                }
            }
            return nil
        }

        private func hex4(at start: Int) -> UInt16? {
            guard start + 4 <= bytes.count else { return nil }
            var value: UInt16 = 0
            for offset in 0..<4 {
                let byte = bytes[start + offset]
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

        private func isDigit(_ byte: UInt8) -> Bool {
            byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }

        private func isSimpleEscape(_ byte: UInt8) -> Bool {
            switch byte {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"),
                 UInt8(ascii: "b"), UInt8(ascii: "f"), UInt8(ascii: "n"),
                 UInt8(ascii: "r"), UInt8(ascii: "t"):
                return true
            default:
                return false
            }
        }
    }
}
