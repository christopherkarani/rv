import Foundation

enum RobotJSON {
    /// Encodes Presentation-owned field order. Not a schema builder.
    static func encode(_ fields: [(String, String)]) -> String {
        let body = fields.map { key, value in
            "\"\(key)\":\"\(escape(value))\""
        }.joined(separator: ",")
        return "{\(body)}"
    }

    static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func encodeArray(_ rows: [[String: String]]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func escape(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                out += "\\\""
            case "\\":
                out += "\\\\"
            case "\n":
                out += "\\n"
            case "\r":
                out += "\\r"
            case "\t":
                out += "\\t"
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
