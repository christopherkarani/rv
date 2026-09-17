import Foundation

/// PostHog project credentials. Write key may be public; empty disables network.
public enum AnalyticsCredentials: Sendable {
    /// Bundled project API key. Leave empty in open trees; set for release builds.
    public static let bundledAPIKey = ""

    /// PostHog US ingest host. Invalid only if the constant string is edited badly.
    public static let defaultHost = ingestURL(from: "https://us.i.posthog.com")

    /// Parses an ingest URL. File-root is the last-resort fallback if `raw` is not a URL.
    package static func ingestURL(from raw: String) -> URL {
        URL(string: raw) ?? URL(fileURLWithPath: "/")
    }

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let override = environment["RV_POSTHOG_API_KEY"], override.isEmpty == false {
            return override
        }
        return bundledAPIKey
    }

    public static func host(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let raw = environment["RV_POSTHOG_HOST"],
           raw.isEmpty == false,
           let url = URL(string: raw)
        {
            return url
        }
        return defaultHost
    }
}
