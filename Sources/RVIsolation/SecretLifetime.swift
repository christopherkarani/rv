import Foundation

/// How often the gateway re-resolves a secret from its provider.
/// Written as a whole number of `s`, `m`, `h`, or `d`, from 1m to 30d.
public struct SecretRefreshInterval: Sendable, Equatable {
    public static let minimumSeconds = 60
    public static let maximumSeconds = 30 * 86_400
    static let units: [(suffix: Character, seconds: Int)] = [("d", 86_400), ("h", 3_600), ("m", 60), ("s", 1)]

    public let seconds: Int

    public init?(_ text: String) {
        guard let unit = text.last, let scale = Self.units.first(where: { $0.suffix == unit })?.seconds else {
            return nil
        }
        let digits = text.dropLast()
        guard digits.isEmpty == false, digits.count <= 7, digits.first != "0",
            digits.allSatisfy({ $0.isASCII && $0.isNumber }), let count = Int(digits)
        else { return nil }
        self.init(seconds: count * scale)
    }

    public init?(seconds: Int) {
        guard seconds >= Self.minimumSeconds, seconds <= Self.maximumSeconds else { return nil }
        self.seconds = seconds
    }

    /// The largest unit that divides the interval exactly.
    public var text: String {
        let unit = Self.units.first { seconds % $0.seconds == 0 } ?? ("s", 1)
        return "\(seconds / unit.seconds)\(unit.suffix)"
    }

    public var timeInterval: TimeInterval { TimeInterval(seconds) }
}

/// ISO-8601 expiry instants. A date alone means 00:00 UTC that day, so a
/// token that "expires on" a date is never used on it.
public enum SecretExpiry {
    /// Shapes accepted, with every digit written as 9. A date-time must carry its zone.
    private static let shapes: Set<String> = [
        "9999-99-99", "9999-99-99T99:99:99Z", "9999-99-99T99:99:99+99:99", "9999-99-99T99:99:99-99:99",
    ]

    public static func parse(_ text: String) -> Date? {
        let shape = String(text.map { $0.isASCII && $0.isNumber ? "9" : $0 })
        guard shapes.contains(shape) else { return nil }
        let numbers = text.split { ($0.isASCII && $0.isNumber) == false }.compactMap { Int($0) }
        let hour = numbers.count > 3 ? numbers[3] : 0
        let minute = numbers.count > 4 ? numbers[4] : 0
        let second = numbers.count > 5 ? numbers[5] : 0
        var offset = 0
        if numbers.count == 8 {
            guard numbers[6] < 24, numbers[7] < 60 else { return nil }
            offset = (text.dropFirst(19).first == "-" ? -1 : 1) * (numbers[6] * 3_600 + numbers[7] * 60)
        }
        guard hour < 24, minute < 60, second < 60 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let parts = DateComponents(
            year: numbers[0], month: numbers[1], day: numbers[2], hour: hour, minute: minute, second: second)
        // `date(from:)` rolls 2026-02-30 over to March; refuse it instead.
        guard parts.isValidDate(in: calendar), let local = calendar.date(from: parts) else { return nil }
        return local.addingTimeInterval(TimeInterval(-offset))
    }

    /// `2026-12-31` for a UTC midnight, otherwise `2026-12-31T18:00:00Z`.
    public static func text(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = utc
        let midnight = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400) == 0
        formatter.formatOptions = midnight ? [.withFullDate] : [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Whole days left, rounded down; negative once expired.
    public static func daysLeft(_ date: Date, now: Date) -> Int {
        Int((date.timeIntervalSince(now) / 86_400).rounded(.down))
    }

    private static let utc = TimeZone.gmt
}
