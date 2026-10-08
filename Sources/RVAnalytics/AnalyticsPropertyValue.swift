import Foundation

/// JSON-safe analytics property values. Never command text or paths.
public enum AnalyticsPropertyValue: Sendable, Equatable, Codable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case strings([String])

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .strings(let value):
            try container.encode(value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String].self) {
            self = .strings(value)
        } else {
            throw DecodingError.typeMismatch(
                AnalyticsPropertyValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected a bool, int, string, or string array."
                )
            )
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
