import Foundation
import RVDomain

/// Shared typed-JSON entry points for session-store adapters.
///
/// Every adapter fails the same way on malformed input: nil, never throw.
/// All entry points return `JSONValue`, never `Any`.
enum JSONParse {
    /// Data bytes as a JSON object. Scalars, arrays, and malformed input yield nil.
    static func object(_ data: Data) -> JSONValue? {
        guard let value = value(data), value.asObject != nil else { return nil }
        return value
    }

    /// String as a JSON object. Unencodable text yields nil.
    static func object(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return object(data)
    }

    /// Data bytes as a typed JSON value. Malformed input yields nil.
    static func value(_ data: Data) -> JSONValue? {
        if let direct = try? JSONDecoder().decode(JSONValue.self, from: data) {
            return direct
        }
        // `JSONDecoder` rejects top-level fragments, but command text and
        // tool-call payloads can be a bare scalar (`123`, `"ls"`, `true`).
        // Re-parse wrapped in an array and unwrap the single element; anything
        // else (empty, trailing garbage, multi-element) stays nil.
        let wrapped = Data("[".utf8) + data + Data("]".utf8)
        guard let elements = try? JSONDecoder().decode([JSONValue].self, from: wrapped),
              elements.count == 1
        else {
            return nil
        }
        return elements[0]
    }

    /// String as a typed JSON value. Unencodable text yields nil.
    static func value(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return value(data)
    }
}
