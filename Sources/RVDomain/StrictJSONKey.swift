import Foundation

/// Open key set for strict JSON decoding: every member survives into
/// `allKeys` so the unknown-field check can see it. (A `String` enum
/// would silently drop unknowns from `allKeys`, hiding smuggled members.)
///
/// Shared by the owner-only operator stores (bindings, resource policy,
/// file values, Vault approle) and the MCP envelope, so the fail-closed
/// contract reads the same everywhere.
public struct StrictJSONKey: CodingKey {
    /// Member name.
    public let stringValue: String
    /// Strict documents never use indexed keys.
    public let intValue: Int?

    /// Names one member.
    public init(_ value: String) {
        stringValue = value
        intValue = nil
    }

    /// Names one member. Never fails: openness is the point.
    public init?(stringValue: String) {
        self.init(stringValue)
    }

    /// Strict documents never use indexed keys.
    public init?(intValue: Int) {
        nil
    }
}

/// Rejects unknown members: every key outside `allowed` fails the decode
/// closed, naming the smuggled field.
public func rejectUnknownKeys(
    _ container: KeyedDecodingContainer<StrictJSONKey>, allowed: Set<String>
) throws {
    for key in container.allKeys where allowed.contains(key.stringValue) == false {
        throw DecodingError.dataCorruptedError(
            forKey: key, in: container,
            debugDescription: "unknown field: \(key.stringValue)"
        )
    }
}

/// Decodes an optional member: a missing key reads as nil, an explicit null
/// fails closed, otherwise the value decodes as `T`. Mirrors Effect's
/// `optional`, where only a missing key is absent.
public func decodeStrictOptional<T: Decodable>(
    _ type: T.Type, forKey key: StrictJSONKey,
    in container: KeyedDecodingContainer<StrictJSONKey>
) throws -> T? {
    guard container.contains(key) else { return nil }
    if try container.decodeNil(forKey: key) {
        throw DecodingError.dataCorruptedError(
            forKey: key, in: container, debugDescription: "null is not absent"
        )
    }
    return try container.decode(T.self, forKey: key)
}
