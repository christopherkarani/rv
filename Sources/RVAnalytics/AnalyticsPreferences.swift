import Foundation

/// User preference for analytics. Missing key means enabled (opt-out).
public struct AnalyticsPreferences: Sendable, Equatable {
    public var isEnabled: Bool

    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    /// Missing config means analytics is on (opt-out, not opt-in).
    public static let enabledByDefault = AnalyticsPreferences(isEnabled: true)

    public static func load(from paths: AnalyticsPaths, fileManager: FileManager = .default) -> AnalyticsPreferences {
        guard let data = fileManager.contents(atPath: paths.configFile.path) else {
            return .enabledByDefault
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .enabledByDefault
        }
        guard let analytics = root["analytics"] as? [String: Any] else {
            return .enabledByDefault
        }
        if let enabled = analytics["enabled"] as? Bool {
            return AnalyticsPreferences(isEnabled: enabled)
        }
        return .enabledByDefault
    }
}
