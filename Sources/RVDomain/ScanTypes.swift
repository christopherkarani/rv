/// Hard caps for session-store walks (REQ-016).
public struct ScanBounds: Sendable, Equatable {
    public var maxDepth: Int
    public var maxFiles: Int
    public var maxTotalBytes: Int64
    public var maxFileBytes: Int64

    public init(
        maxDepth: Int = 8,
        maxFiles: Int = 10_000,
        maxTotalBytes: Int64 = 268_435_456,
        maxFileBytes: Int64 = 33_554_432
    ) {
        self.maxDepth = maxDepth
        self.maxFiles = maxFiles
        self.maxTotalBytes = maxTotalBytes
        self.maxFileBytes = maxFileBytes
    }

    /// REQ-016 package defaults.
    public static let `default` = ScanBounds()
}

/// Known host session-store kinds for forensics discovery.
public enum ScanHostID: String, Sendable, Equatable, Hashable {
    case claude
    case pi
    case grok
    case opencode
    case openclaw
}

/// Non-empty injectable home path for session-store discovery.
/// Fails on "". Not `RVPolicy.HomeDirectory`.
public struct ScanHome: Hashable, Sendable {
    public let path: String

    public init?(validating path: String) {
        guard path.isEmpty == false else { return nil }
        self.path = path
    }
}
