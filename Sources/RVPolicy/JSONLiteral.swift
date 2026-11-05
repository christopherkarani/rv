import Foundation

/// The managed-policy adapter at the `JSONSpellingParser` seam. The parser
/// and the `domainValue()` conversion live in that module; this name keeps
/// the fail-closed, nil-on-any-error interface `ManagedPolicy` and
/// `ManagedSerialRecord` already use.
typealias JSONLiteral = JSONSpellingValue

extension JSONSpellingValue {
    /// Strict parse, nil on any error. Depth 63 at the parser interface is
    /// this adapter's historical boundary: 64 nested empty containers, or 63
    /// around a scalar. Host-config adapters keep their own depth.
    static func parse(_ data: Data) -> JSONSpellingValue? {
        try? JSONSpellingParser.parse(data, maximumDepth: 63, lenient: false)
    }

    /// `0` or a decimal integer with no leading zero. Nil when it does not fit in `Int`.
    static func nonNegativeInteger(_ token: String) -> Int? {
        guard token == "0" || (token.first != "0" && token.allSatisfy(isDigit) && token.isEmpty == false) else {
            return nil
        }
        return Int(token)
    }

    static func quoted(_ text: String) -> String {
        var output = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
        return output
    }

    private static func isDigit(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue else { return false }
        return ascii >= UInt8(ascii: "0") && ascii <= UInt8(ascii: "9")
    }
}
