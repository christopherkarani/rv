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

    /// Reads `analytics.enabled` nested (`{"analytics": {"enabled": false}}`)
    /// or in the flat dotted form the README documents
    /// (`{"analytics.enabled": false}`), matching how `guard.mode` is read.
    /// When both forms are present and disagree, the opt-out wins.
    public static func load(from paths: AnalyticsPaths, fileManager: FileManager = .default) -> AnalyticsPreferences {
        guard let data = fileManager.contents(atPath: paths.configFile.path),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return .enabledByDefault
        }
        let nested = root["analytics"]?.asObject?["enabled"]?.bool
        let flat = root["analytics.enabled"]?.bool
        if nested == false || flat == false {
            return AnalyticsPreferences(isEnabled: false)
        }
        if nested == true || flat == true {
            return AnalyticsPreferences(isEnabled: true)
        }
        return .enabledByDefault
    }
}
