public struct PackID: RawRepresentable, Hashable, Sendable, Equatable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init?(validating rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let validated = PackID(validating: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid PackID"
            )
        }
        self = validated
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let coreFilesystem = PackID(rawValue: "core.filesystem")
    public static let coreGit = PackID(rawValue: "core.git")
    public static let coreSecrets = PackID(rawValue: "core.secrets")

    public static func isValid(_ rawValue: String) -> Bool {
        let scalars = Array(rawValue.unicodeScalars)
        guard let first = scalars.first, first.isASCII, first.isLowercaseASCIILetter else {
            return false
        }
        var index = 1
        var sawDot = false
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "." {
                if sawDot { return false }
                sawDot = true
                let next = index + 1
                guard next < scalars.count else { return false }
                let child = scalars[next]
                guard child.isASCII, child.isLowercaseASCIILetter else { return false }
                index += 2
                continue
            }
            guard scalar.isASCII, scalar.isPackIDBody else { return false }
            index += 1
        }
        return true
    }
}

extension Unicode.Scalar {
    fileprivate var isLowercaseASCIILetter: Bool {
        (97...122).contains(value)
    }

    fileprivate var isPackIDBody: Bool {
        isLowercaseASCIILetter || (48...57).contains(value) || self == "_"
    }
}
