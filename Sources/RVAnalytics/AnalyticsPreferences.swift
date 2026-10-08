import Foundation
import RVDomain

/// User preference for analytics. Missing key means enabled (opt-out).
public struct AnalyticsPreferences: Sendable, Equatable {
    public var isEnabled: Bool

    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    /// Missing config means analytics is on (opt-out, not opt-in).
    public static let enabledByDefault = AnalyticsPreferences(isEnabled: true)

    public static func load(from paths: AnalyticsPaths, fileManager: FileManager = .default) -> AnalyticsPreferences {
        guard let data = fileManager.contents(atPath: paths.configFile.path),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let analytics = root["analytics"]?.asObject
        else {
            return .enabledByDefault
        }
        if let enabled = analytics["enabled"]?.bool {
            return AnalyticsPreferences(isEnabled: enabled)
        }
        return .enabledByDefault
    }
}
