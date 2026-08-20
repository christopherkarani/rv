import Foundation

/// Stable anonymous distinct id for PostHog.
public struct AnalyticsIdentity: Sendable, Equatable {
    public var distinctID: String

    public init(distinctID: String) {
        self.distinctID = distinctID
    }

    public static func loadOrCreate(
        in paths: AnalyticsPaths,
        fileManager: FileManager = .default,
        newID: () -> String = { UUID().uuidString.lowercased() }
    ) throws -> AnalyticsIdentity {
        if let existing = fileManager.contents(atPath: paths.identityFile.path),
           let text = String(data: existing, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           text.isEmpty == false
        {
            return AnalyticsIdentity(distinctID: text)
        }
        try fileManager.createDirectory(
            at: paths.configDirectory,
            withIntermediateDirectories: true
        )
        let id = newID()
        try Data(id.utf8).write(to: paths.identityFile, options: .atomic)
        return AnalyticsIdentity(distinctID: id)
    }
}
