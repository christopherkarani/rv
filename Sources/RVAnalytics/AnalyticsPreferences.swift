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
    ///
    /// On only for an unambiguous boolean true: at least one form is present,
    /// and every form that is present is the boolean `true`. Off for a missing,
    /// unreadable or undecodable config; a key repeated anywhere in the
    /// document; an `analytics` value that is not an object; or either form
    /// present with anything but `true` (`false`, `null`, a string, a number,
    /// an array or an object).
    public static func load(from paths: AnalyticsPaths, fileManager: FileManager = .default) -> AnalyticsPreferences {
        guard let data = fileManager.contents(atPath: paths.configFile.path),
              JSONDuplicateKeys.allObjectKeysDistinct(data),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return .disabledByDefault
        }
        let analytics = root["analytics"]
        if let analytics, analytics.asObject == nil {
            return .disabledByDefault
        }
        let present = [analytics?["enabled"], root["analytics.enabled"]].compactMap { $0 }
        guard present.isEmpty == false, present.allSatisfy({ $0.bool == true }) else {
            return .disabledByDefault
        }
        return AnalyticsPreferences(isEnabled: true)
    }
}
