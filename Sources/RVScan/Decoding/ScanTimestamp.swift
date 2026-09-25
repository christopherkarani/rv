import Foundation

/// Lenient ISO-8601 timestamp parsing shared by session-store adapters.
enum ScanTimestamp {
    /// ISO-8601 with/without fractional seconds; nil when absent/unparseable.
    static func parse(_ value: String?) -> Date? {
        guard let raw = value, raw.isEmpty == false else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
