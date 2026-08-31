/// Nonempty host session or turn identifier on a hook request.
/// Absence is `SessionID?`; an empty string is not representable.
public struct SessionID: RawRepresentable, Hashable, Sendable, Equatable, Codable {
    public let rawValue: String

    /// Fails on "". Non-empty strings pass unchanged.
    public init?(validating rawValue: String) {
        guard rawValue.isEmpty == false else { return nil }
        self.rawValue = rawValue
    }

    public init?(rawValue: String) {
        self.init(validating: rawValue)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let validated = SessionID(validating: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid SessionID"
            )
        }
        self = validated
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
