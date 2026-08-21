import Foundation

enum RobotJSON {
    static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func encodeArray(_ rows: [[String: String]]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
