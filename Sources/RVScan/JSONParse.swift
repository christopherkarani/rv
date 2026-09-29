import Foundation

/// Shared untyped-JSON entry points for session-store adapters.
///
/// Centralizes the `data(using:) + JSONSerialization + cast` triple so every
/// adapter fails the same way on malformed input: nil, never throw.
enum JSONParse {
    /// Data bytes as a JSON object. Scalars, arrays, and malformed input yield nil.
    static func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// String as a JSON object. Unencodable text yields nil.
    static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return object(data)
    }

    /// Data bytes as an untyped JSON value. Malformed input yields nil.
    static func value(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data)
    }

    /// String as an untyped JSON value. Unencodable text yields nil.
    static func value(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return value(data)
    }
}
