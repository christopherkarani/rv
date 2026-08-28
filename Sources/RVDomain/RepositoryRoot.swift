/// Nonempty repository root used as the filesystem security boundary.
/// Absence is `RepositoryRoot?`; an empty string is not representable.
public struct RepositoryRoot: RawRepresentable, Hashable, Sendable, Codable {
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
        guard let validated = RepositoryRoot(validating: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid RepositoryRoot"
            )
        }
        self = validated
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
