import Foundation

/// The operator HOME newtype: root of `~/.config/rv`.
/// Absence is `HomeDirectory?`; an empty string ("no usable HOME") is not representable.
public struct HomeDirectory: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    /// Fails on "" (the current sentinel). Non-empty strings pass unchanged.
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
        guard let validated = HomeDirectory(validating: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid HomeDirectory"
            )
        }
        self = validated
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The single sanctioned environment read. nil when HOME is unset or empty.
    public static func process() -> HomeDirectory? {
        HomeDirectory(validating: ProcessInfo.processInfo.environment["HOME"] ?? "")
    }
}
