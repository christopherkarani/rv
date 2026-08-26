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
        let bytes = text.utf8
        var index = bytes.startIndex
        while index != bytes.endIndex {
            if bytes[index] == UInt8(ascii: "(") {
                var cursor = bytes.index(after: index)
                while cursor != bytes.endIndex, isASCIIWhitespace(bytes[cursor]) {
                    cursor = bytes.index(after: cursor)
                }
                if cursor != bytes.endIndex, bytes[cursor] == UInt8(ascii: ")") {
                    return true
                }
            }
            index = bytes.index(after: index)
        }
        return false
    }
}

/// Word characters are ASCII alnum / `_` / `-`, matching the pack delimiter `[^[:alnum:]_-]`.
/// That keeps `.gitignore` and `digit` from lighting `git`, while `$(git reset --hard)` still hits.
private func asciiWordHit(_ keyword: String, in text: String) -> Bool {
    let haystack = text.utf8
    let needle = keyword.utf8
    let needleCount = needle.count
    guard needleCount > 0, haystack.count >= needleCount else { return false }

    var start = haystack.startIndex
    while start != haystack.endIndex {
        guard let matchEnd = haystack.index(
            start,
            offsetBy: needleCount,
            limitedBy: haystack.endIndex
        ) else {
            break
        }

        if asciiEqualsCaseInsensitive(haystack[start..<matchEnd], needle) {
            let before: UInt8? = start == haystack.startIndex
                ? nil
                : haystack[haystack.index(before: start)]
            let after: UInt8? = matchEnd == haystack.endIndex ? nil : haystack[matchEnd]
            if !isASCIIWordByte(before), !isASCIIWordByte(after) {
                return true
            }
        }
        start = haystack.index(after: start)
    }
    return false
}

private func asciiEqualsCaseInsensitive<H: Collection, N: Collection>(
    _ slice: H,
    _ needle: N
) -> Bool where H.Element == UInt8, N.Element == UInt8 {
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
