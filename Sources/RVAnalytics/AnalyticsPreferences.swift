import Foundation
import RVDomain

/// User preference for analytics. Opt-in: on only when config.json says
/// `analytics.enabled` is true; anything else means off.
public struct AnalyticsPreferences: Sendable, Equatable {
    public var isEnabled: Bool

    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    /// No opt-in means analytics is off (opt-in, not opt-out).
    public static let disabledByDefault = AnalyticsPreferences(isEnabled: false)

    /// Reads `analytics.enabled` nested (`{"analytics": {"enabled": true}}`)
    /// or in the flat dotted form the README documents
    /// (`{"analytics.enabled": true}`), matching how `guard.mode` is read.
    /// A missing, unreadable or undecodable config, a missing or non-boolean
    /// key, or a key repeated anywhere in the document reads as off. When both
    /// forms are present and disagree, off wins.
    public static func load(from paths: AnalyticsPaths, fileManager: FileManager = .default) -> AnalyticsPreferences {
        guard let data = fileManager.contents(atPath: paths.configFile.path),
              JSONDuplicateKeys.allObjectKeysDistinct(data),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return .disabledByDefault
        }
        let nested = root["analytics"]?.asObject?["enabled"]?.bool
        let flat = root["analytics.enabled"]?.bool
        if nested == false || flat == false {
            return .disabledByDefault
        }
        if nested == true || flat == true {
            return AnalyticsPreferences(isEnabled: true)
        }
        return .disabledByDefault
    }
}
