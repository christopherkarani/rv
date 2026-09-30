/// Lossless-enough in-memory JSON representation for session-store readers.
///
/// Replaces `[String: Any]` / `Any` as the JSON funnel: consumers read
/// through typed accessors (`subscript(key:)`, `.string`, `.int`, …) instead
/// of `as?` cast chains, so a mistyped read is nil rather than a trap and a
/// missing key can never be confused with a present null.
///
/// Numbers decode as `.number(Double)`. Integers that fit `Double` exactly
/// round-trip through `.int`; integers beyond 2^53 decode as `.string`
/// holding the decimal digits (documented fallback: `UInt64` payloads such
/// as `18446744073709551615` survive as text instead of a rounded double).
public enum JSONValue: Sendable, Equatable, Codable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    /// Object member, or nil when `self` is not an object or the key is
    /// absent. A present null member yields `.some(.null)`, never nil.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    /// Array element, or nil when `self` is not an array or `index` is out
    /// of bounds. Never traps.
    public subscript(index: Int) -> JSONValue? {
        guard case .array(let array) = self, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// String payload, or nil for any other case.
    public var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    /// Integer payload, failing closed: nil for fractional doubles,
    /// non-finite doubles, out-of-`Int`-range magnitudes, and non-numbers.
    public var int: Int? {
        guard case .number(let raw) = self else { return nil }
        return Int(exactly: raw)
    }

    /// Numeric payload, or nil for any other case.
    public var double: Double? {
        guard case .number(let raw) = self else { return nil }
        return raw
    }

    /// Boolean payload, or nil for any other case.
    public var bool: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    /// True only for `.null`.
    public var isNull: Bool {
        guard case .null = self else { return false }
        return true
    }

    /// Object payload, or nil for any other case.
    public var asObject: [String: JSONValue]? {
        guard case .object(let object) = self else { return nil }
        return object
    }

    /// Array payload, or nil for any other case.
    public var asArray: [JSONValue]? {
        guard case .array(let array) = self else { return nil }
        return array
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        // Integers before Double: a whole JSON number must survive as an
        // exact `.number` (and `.int`) rather than a rounded double. Values
        // beyond `Double`'s exact-integer range fall back to `.string` digits.
        if let value = try? container.decode(Int64.self) {
            self = Double(value).isExactlyIntegerEqual(to: value)
                ? .number(Double(value))
                : .string(String(value))
            return
        }
        if let value = try? container.decode(UInt64.self) {
            self = Double(value).isExactlyIntegerEqual(to: value)
                ? .number(Double(value))
                : .string(String(value))
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.typeMismatch(
            JSONValue.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected a JSON value."
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let object):
            try container.encode(object)
        case .array(let array):
            try container.encode(array)
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

private extension Double {
    /// True when `self` holds `value` with no rounding (magnitude within
    /// 2^53 and exactly representable).
    func isExactlyIntegerEqual(to value: Int64) -> Bool {
        Int64(exactly: self) == value
    }

    func isExactlyIntegerEqual(to value: UInt64) -> Bool {
        UInt64(exactly: self) == value
    }
}
