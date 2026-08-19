/// T1-normalized command text a result was decided on. Distinct from raw `ShellCommand`.
public struct MatchingView: RawRepresentable, Hashable, Sendable, Equatable, Codable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var isEmpty: Bool { rawValue.isEmpty }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
