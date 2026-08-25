import Foundation

/// Injectable operator home for session-store discovery.
/// Same validation as `RVPolicy.HomeDirectory` (non-empty path) without importing Policy (CON-002).
public struct ScanHome: Hashable, Sendable {
    public let path: String

    public init?(validating path: String) {
        guard path.isEmpty == false else { return nil }
        self.path = path
    }

    public var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }
}
