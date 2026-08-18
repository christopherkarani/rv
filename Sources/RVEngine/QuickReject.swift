import Foundation
import RVDomain

public enum QuickReject {
    public static func shouldSkip(
        matchingView: String,
        enabled: [PackSnapshot]
    ) -> Bool {
        if containsEmptyParenPair(matchingView) {
            return false
        }
        return !enabled.contains { pack in
            pack.keywords.contains { keywordHits($0, in: matchingView) }
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
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            guard let open = bytes[index...].firstIndex(of: UInt8(ascii: "(")) else {
                return false
            }
            var cursor = open + 1
            while cursor < bytes.count, isASCIIWhitespace(bytes[cursor]) {
                cursor += 1
            }
            if cursor < bytes.count, bytes[cursor] == UInt8(ascii: ")") {
                return true
            }
            index = open + 1
        }
        return false
    }
}

/// Word characters are ASCII alnum / `_` / `-`, matching the pack delimiter `[^[:alnum:]_-]`.
/// That keeps `.gitignore` and `digit` from lighting `git`, while `$(git reset --hard)` still hits.
private func asciiWordHit(_ keyword: String, in text: String) -> Bool {
    let haystack = Array(text.utf8)
    let needle = Array(keyword.utf8)
    guard !needle.isEmpty, haystack.count >= needle.count else { return false }
    var index = 0
    while index + needle.count <= haystack.count {
        if asciiEqualsCaseInsensitive(haystack[index..<(index + needle.count)], needle),
           !isASCIIWordByte(index == 0 ? nil : haystack[index - 1]),
           !isASCIIWordByte(
               index + needle.count == haystack.count ? nil : haystack[index + needle.count]
           )
        {
            return true
        }
        index += 1
    }
    return false
}

private func asciiEqualsCaseInsensitive(_ slice: ArraySlice<UInt8>, _ needle: [UInt8]) -> Bool {
    guard slice.count == needle.count else { return false }
    for (byte, expected) in zip(slice, needle) {
        if byte.lowercasedASCII != expected.lowercasedASCII {
            return false
        }
    }
    return true
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
