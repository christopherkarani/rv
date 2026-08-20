import Foundation

/// JSON-safe analytics property values. Never command text or paths.
public enum AnalyticsPropertyValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case strings([String])

    public var jsonObject: Any {
        switch self {
        case .string(let value): value
        case .int(let value): value
        case .bool(let value): value
        case .strings(let value): value
        }
    }
}

public struct AnalyticsPayload: Sendable, Equatable {
    public var event: String
    public var distinctID: String
    public var properties: [String: AnalyticsPropertyValue]

    public init(event: String, distinctID: String, properties: [String: AnalyticsPropertyValue] = [:]) {
        self.event = event
        self.distinctID = distinctID
        self.properties = properties
    }

    public static let installEvent = "install"
    public static let dailyActiveEvent = "daily_active"
}
