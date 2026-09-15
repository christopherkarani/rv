import Foundation
import RVDomain

public enum DenialPathRedaction {
    /// Replace a home prefix with `~`. Does not invent a home.
    public static func redact(_ path: String, home: HomePath?) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let home else { return trimmed }
        let homePath = home.rawValue
        if trimmed == homePath { return "~" }
        if trimmed.hasPrefix(homePath + "/") {
            return "~" + trimmed.dropFirst(homePath.count)
        }
        if trimmed.hasPrefix("$HOME") {
            return "~" + trimmed.dropFirst(5)
        }
        if trimmed.hasPrefix("${HOME}") {
            return "~" + trimmed.dropFirst(7)
        }
        return trimmed
    }
}
