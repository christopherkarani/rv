import Foundation
import RVDomain

/// Timestamp coercions shared by the JSONL and SQLite extraction paths.
///
/// Every host's historical rules are preserved exactly:
/// - ISO-8601 strings with or without fractional seconds (Claude, Codex,
///   Cursor, Pi).
/// - Epoch seconds-or-millis numbers above `1_000_000_000_000` dividing by
///   1000 (Codex, Pi, Hermes, OpenClaw, OpenCode).
/// - Positivity guard (`raw > 0`) for Codex, Hermes, and OpenClaw only; Pi and
///   OpenCode date every number.
/// - JSON booleans coerce as 1/0 (the old `as? NSNumber` bridge), so
///   `true` dates to epoch+1s while `false` fails the positivity guard.
enum ScanTimestamp {
    /// Parse an ISO-8601 datetime, fractional first, then plain.
    /// Empty and unparseable strings yield nil.
    static func iso8601(_ raw: String) -> Date? {
        guard raw.isEmpty == false else { return nil }
        // Per-call construction is intentional: ISO8601DateFormatter is not
        // Sendable and tests exercise adapters concurrently, so a shared
        // static instance would race.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    /// Epoch seconds, or millis when above 1e12. Matches every host's
    /// historical threshold comparison (strictly greater).
    static func epoch(_ raw: Double, requirePositive: Bool = true) -> Date? {
        guard requirePositive == false || raw > 0 else { return nil }
        if raw > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: raw / 1000)
        }
        return Date(timeIntervalSince1970: raw)
    }

    /// Epoch coercion for a JSON value. Numbers convert (int-or-double both
    /// arrive as `.number`); booleans map to 1/0 exactly as the old `NSNumber`
    /// bridge did. Strings, nulls, objects, arrays, and nil never convert.
    static func epochValue(_ value: JSONValue?, requirePositive: Bool = true) -> Date? {
        switch value {
        case .number(let raw):
            return epoch(raw, requirePositive: requirePositive)
        case .bool(let flag):
            return epoch(flag ? 1 : 0, requirePositive: requirePositive)
        case .string, .object, .array, .null, nil:
            return nil
        }
    }

    /// Coerce one timestamp field: strings parse as ISO-8601, numbers as
    /// epoch when `allowEpoch`. A present-but-unparseable value yields nil and
    /// never falls through to another key.
    static func coerce(_ value: JSONValue?, allowEpoch: Bool, requirePositive: Bool = true) -> Date? {
        if let raw = value?.string {
            return iso8601(raw)
        }
        guard allowEpoch else { return nil }
        return epochValue(value, requirePositive: requirePositive)
    }

    /// First non-nil field value for `keys` in order. Matches the historical
    /// `object["timestamp"] ?? object["ts"]` selection: a present empty string
    /// (or null) wins over a later key and then coerces to nil.
    static func firstValue(keys: [String], in value: JSONValue) -> JSONValue? {
        for key in keys {
            if let found = value[key] {
                return found
            }
        }
        return nil
    }
}
