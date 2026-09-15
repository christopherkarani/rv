/// Nonempty operator / injectable HOME.
/// Absence is `HomePath?`; an empty string is not representable.
/// Distinct from `WorkingDirectory` (honor-key cwd) and `RepositoryRoot`.
public struct HomePath: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    /// Fails on "". Non-empty strings pass unchanged.
    public init?(validating rawValue: String) {
        guard rawValue.isEmpty == false else { return nil }
        self.rawValue = rawValue
    }

    public init?(rawValue: String) {
        self.init(validating: rawValue)
    }

    /// Scan call-site alias (`ScanHome.path`).
    public var path: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let validated = HomePath(validating: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid HomePath"
            )
        }
        self = validated
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
