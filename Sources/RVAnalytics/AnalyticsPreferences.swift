import Foundation

/// User preference for analytics. Missing key means enabled (opt-out).
public struct AnalyticsPreferences: Sendable, Equatable {
    public var isEnabled: Bool

    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    public static let optOutDefault = AnalyticsPreferences(isEnabled: true)

    public static func load(from paths: AnalyticsPaths, fileManager: FileManager = .default) -> AnalyticsPreferences {
        guard let data = fileManager.contents(atPath: paths.configFile.path) else {
            return .optOutDefault
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .optOutDefault
        }
        guard let analytics = root["analytics"] as? [String: Any] else {
            return .optOutDefault
        }
        if let enabled = analytics["enabled"] as? Bool {
            return AnalyticsPreferences(isEnabled: enabled)
        }
        return .optOutDefault
    }
}
