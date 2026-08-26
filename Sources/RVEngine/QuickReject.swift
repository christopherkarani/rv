import Foundation
import RVDomain

public enum QuickReject {
    public static func shouldSkip(
        matchingView: MatchingView,
        enabled: [PackSnapshot]
    ) -> Bool {
        let text = matchingView.rawValue
        if containsEmptyParenPair(text) {
            return false
        }
        return !enabled.contains { pack in
            pack.keywords.contains { keywordHits($0, in: text) }
        }
    }

    public static func keywordHits(_ keyword: String, in text: String) -> Bool {
        if keyword.unicodeScalars.allSatisfy({
            $0.isASCII && (97...122).contains($0.value)
        }) {
            return asciiWordHit(keyword, in: text)
        }
        return text.contains(keyword)
    }

    public static func containsEmptyParenPair(_ text: String) -> Bool {
        withUTF8Buffer(text) { bytes in
            var index = 0
            while index < bytes.count {
                if bytes[index] == UInt8(ascii: "(") {
                    var cursor = index + 1
                    while cursor < bytes.count, isASCIIWhitespace(bytes[cursor]) {
                        cursor += 1
                    }
                    if cursor < bytes.count, bytes[cursor] == UInt8(ascii: ")") {
                        return true
                    }
                }
                index += 1
            }
            return false
        }
    }
}

/// Word characters are ASCII alnum / `_` / `-`, matching the pack delimiter `[^[:alnum:]_-]`.
/// That keeps `.gitignore` and `digit` from lighting `git`, while `$(git reset --hard)` still hits.
private func asciiWordHit(_ keyword: String, in text: String) -> Bool {
    withUTF8Buffer(text) { haystack in
        withUTF8Buffer(keyword) { needle in
            let needleCount = needle.count
            guard needleCount > 0, haystack.count >= needleCount else { return false }

            for start in 0...(haystack.count - needleCount) {
                if asciiEqualsCaseInsensitive(haystack, start: start, needle: needle) {
                    let before: UInt8? = start == 0 ? nil : haystack[start - 1]
                    let after: UInt8? = start + needleCount == haystack.count
                        ? nil
                        : haystack[start + needleCount]
                    if !isASCIIWordByte(before), !isASCIIWordByte(after) {
                        return true
                    }
                }
            }
            return false
        }
    }
}

private func asciiEqualsCaseInsensitive(
    _ haystack: UnsafeBufferPointer<UInt8>,
    start: Int,
    needle: UnsafeBufferPointer<UInt8>
) -> Bool {
    for offset in 0..<needle.count {
        if haystack[start + offset].lowercasedASCII != needle[offset].lowercasedASCII {
            return false
        }
    }
    return true
}

private func withUTF8Buffer<Result>(
    _ text: String,
    _ body: (UnsafeBufferPointer<UInt8>) -> Result
) -> Result {
    if let result = text.utf8.withContiguousStorageIfAvailable(body) {
        return result
    }
    let count = text.utf8.count
    return text.withCString { cString in
        let bytes = UnsafeBufferPointer(
            start: UnsafeRawPointer(cString).assumingMemoryBound(to: UInt8.self),
            count: count
        )
        return body(bytes)
    }
}

private func isASCIIWordByte(_ byte: UInt8?) -> Bool {
    guard let byte else { return false }
    return (48...57).contains(byte)
        || (65...90).contains(byte)
        || (97...122).contains(byte)
        || byte == 95
        || byte == 45
}

extension UInt8 {
    fileprivate var lowercasedASCII: UInt8 {
        (65...90).contains(self) ? self + 32 : self
    }
}

private func isASCIIWhitespace(_ byte: UInt8) -> Bool {
    byte == 9 || byte == 10 || byte == 13 || byte == 32
}
