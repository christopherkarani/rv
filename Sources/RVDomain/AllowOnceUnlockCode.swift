/// Six lowercase hex characters minted for `rv allow-once`.
public struct AllowOnceUnlockCode: Hashable, Sendable, Equatable {
    public let rawValue: String

    /// True when `code` is exactly six lowercase hex characters.
    public static func isValid(_ code: String) -> Bool {
        guard code.count == 6 else { return false }
        return code.unicodeScalars.allSatisfy { scalar in
            (scalar >= "0" && scalar <= "9") || (scalar >= "a" && scalar <= "f")
        }
    }

    public init?(validating rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}
