import Foundation

/// Whether text carries a copy of a real value, for refusing a placeholder
/// launch. Stricter than `rv run`'s `SecretRunEnvironment.copies`: there a
/// hit drops an inherited variable, so a short value must not take
/// unrelated ones with it; here a hit refuses a launch whose signed
/// literals carry the secret, and nothing else is lost.
///
/// A value of `SecretLeakScanner.minimumValueBytes` or more is found
/// anywhere inside the text: as is, base64 (standard or URL-safe, padded or
/// not, at any byte offset of the encoded text), hex (either case), or
/// percent-encoded (and those encodings inside percent-encoded text). A
/// shorter value is found only as the whole text, as is or trimmed of
/// whitespace.
///
/// Not found: a value split across variables or arguments, base64 broken
/// across lines, and any other encoding, cipher or transformation.
/// Compared in memory; nothing is printed.
enum SecretValueCopy {
    static func found(in text: String, realValues: [SecretValue]) -> Bool {
        let whole = Array(text.utf8)
        let trimmed = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let real = realValues.map { $0.revealed() }
        if real.contains(where: { $0 == whole || $0 == trimmed }) { return true }
        let haystacks = [whole, percentDecoded(whole)]
        let folded = haystacks.map(asciiLowercased)
        return real.filter { $0.count >= SecretLeakScanner.minimumValueBytes }.contains { value in
            let plain = [value] + base64(value)
            let hex = Array(value.map { String(format: "%02x", $0) }.joined().utf8)
            return haystacks.contains { haystack in plain.contains { contains($0, in: haystack) } }
                || folded.contains { contains(hex, in: $0) }
        }
    }

    /// The full base64 groups of `value` for each of the three byte offsets
    /// it can sit at in a longer encoded text, standard and URL-safe. Full
    /// groups carry no padding, and depend on nothing around the value.
    static func base64(_ value: [UInt8]) -> [[UInt8]] {
        (0..<3).flatMap { offset -> [[UInt8]] in
            let tail = value.dropFirst(offset)
            let groups = tail.prefix(tail.count - tail.count % 3)
            guard groups.isEmpty == false else { return [] }
            let standard = Data(groups).base64EncodedString()
            let safe = standard.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            return [Array(standard.utf8), Array(safe.utf8)]
        }
    }

    /// Every `%XX` with two hex digits replaced by its byte; the rest as is.
    static func percentDecoded(_ bytes: [UInt8]) -> [UInt8] {
        var decoded: [UInt8] = []
        decoded.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%"), index + 2 < bytes.count,
                let high = hexDigit(bytes[index + 1]), let low = hexDigit(bytes[index + 2])
            {
                decoded.append(high << 4 | low)
                index += 3
            } else {
                decoded.append(bytes[index])
                index += 1
            }
        }
        return decoded
    }

    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    private static func asciiLowercased(_ bytes: [UInt8]) -> [UInt8] {
        bytes.map { (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) ? $0 + 32 : $0 }
    }

    private static func contains(_ needle: [UInt8], in haystack: [UInt8]) -> Bool {
        SecretLeakScanner.occurrences(of: needle, in: haystack).isEmpty == false
    }
}
