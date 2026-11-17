import Foundation

/// Duplicate-key check for JSON text, for readers that must fail closed.
///
/// JSON parsers disagree on a repeated object key: Darwin
/// `JSONSerialization` and `JSONDecoder` keep the first, swift-corelibs
/// `JSONSerialization` keeps the last. A guard setting must not depend on
/// which parser reads it, so a reader that cares rejects such a document.
public enum JSONDuplicateKeys {
    /// Deepest object/array nesting the scan accepts. Deeper text fails
    /// closed: `JSONValue` decodes deep nesting slowly (500 levels take
    /// seconds, against the hook's 8 s budget), and no rv config nests
    /// anywhere near this.
    public static let maxNestingDepth = 64

    /// True only when `data` is UTF-8 JSON text (an optional leading BOM
    /// allowed) in which every object's keys are distinct. Keys compare
    /// after unescaping, so `"guard"` and `"gu\u0061rd"` collide.
    ///
    /// Fails closed: false for a duplicate key, nesting deeper than
    /// `maxNestingDepth`, unbalanced brackets, an unterminated string or
    /// key that does not decode, and any byte
    /// outside a string that UTF-8 JSON cannot hold there (which rejects
    /// UTF-16 and UTF-32 text). It does not otherwise validate the JSON;
    /// callers parse it as well.
    public static func allObjectKeysDistinct(_ data: Data) -> Bool {
        var scanner = Scanner(bytes: Array(data))
        return scanner.run()
    }

    private enum Frame {
        case object(keys: Set<String>, expectingKey: Bool)
        case array
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        var stack: [Frame] = []
        let decoder = JSONDecoder()

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func run() -> Bool {
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
            while index < bytes.count {
                guard step() else { return false }
            }
            return stack.isEmpty
        }

        /// Consumes one byte, or one whole string token.
        private mutating func step() -> Bool {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "{"):
                guard stack.count < JSONDuplicateKeys.maxNestingDepth else { return false }
                stack.append(.object(keys: [], expectingKey: true))
            case UInt8(ascii: "["):
                guard stack.count < JSONDuplicateKeys.maxNestingDepth else { return false }
                stack.append(.array)
            case UInt8(ascii: "}"):
                guard case .object = stack.popLast() else { return false }
            case UInt8(ascii: "]"):
                guard case .array = stack.popLast() else { return false }
            case UInt8(ascii: ","):
                setExpectingKey(true)
            case UInt8(ascii: ":"):
                setExpectingKey(false)
            case UInt8(ascii: "\""):
                return string()
            case 0x20, 0x09, 0x0A, 0x0D:
                break
            default:
                guard Self.scalarBytes.contains(byte) else { return false }
            }
            index += 1
            return true
        }

        private mutating func setExpectingKey(_ expecting: Bool) {
            guard case .object(let keys, _) = stack.last else { return }
            stack[stack.count - 1] = .object(keys: keys, expectingKey: expecting)
        }

        /// A string token from `index` (its opening quote) through its
        /// closing quote. Object keys are unescaped and recorded.
        private mutating func string() -> Bool {
            var end = index + 1
            while end < bytes.count, bytes[end] != UInt8(ascii: "\"") {
                end += bytes[end] == UInt8(ascii: "\\") ? 2 : 1
            }
            guard end < bytes.count else { return false }
            defer { index = end + 1 }
            guard case .object(var keys, true) = stack.last else { return true }
            guard let key = key(bytes[(index + 1)..<end]) else { return false }
            // Drop the stack's reference first, so `insert` grows the set in
            // place instead of copying it for every key.
            stack[stack.count - 1] = .array
            guard keys.insert(key).inserted else { return false }
            stack[stack.count - 1] = .object(keys: keys, expectingKey: true)
            return true
        }

        /// A key token's text between its quotes: the UTF-8 bytes as they
        /// stand, or unescaped by `JSONDecoder` when it has a backslash. Nil
        /// (the scan fails) for a key holding U+FEFF, raw or escaped: Darwin
        /// `JSONSerialization` drops a leading one and `JSONDecoder` keeps
        /// it, so the parsers disagree on whether two such keys collide.
        private func key(_ body: ArraySlice<UInt8>) -> String? {
            let text: String?
            if body.contains(UInt8(ascii: "\\")) {
                let token = [UInt8(ascii: "["), UInt8(ascii: "\"")] + body + [UInt8(ascii: "\""), UInt8(ascii: "]")]
                text = (try? decoder.decode([String].self, from: Data(token)))?.first
            } else {
                text = String(validating: body, as: UTF8.self)
            }
            guard let text, !text.unicodeScalars.contains(Self.byteOrderMark) else { return nil }
            return text
        }

        private static let byteOrderMark = Unicode.Scalar(0xFEFF)!

        /// Bytes of numbers and of `true`, `false`, `null`.
        private static let scalarBytes = Set("0123456789+-.eEtrufalsn".utf8)
    }
}
