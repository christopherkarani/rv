import Foundation

/// Files under `~/.config/rv` owned by analytics.
public struct AnalyticsPaths: Sendable, Equatable {
    public var configDirectory: URL

    public init(configDirectory: URL) {
        self.configDirectory = configDirectory
    }

    public var configFile: URL {
        configDirectory.appendingPathComponent("config.json", isDirectory: false)
    }

    public var identityFile: URL {
        configDirectory.appendingPathComponent("analytics-id", isDirectory: false)
    }

    public var countersFile: URL {
        configDirectory.appendingPathComponent("analytics-counters.json", isDirectory: false)
    }

    public var installSentFile: URL {
        configDirectory.appendingPathComponent("analytics-install-sent", isDirectory: false)
    }

    public var hostsFile: URL {
        configDirectory.appendingPathComponent("analytics-hosts.json", isDirectory: false)
    }

    /// Files `rv uninstall` must delete when present (prefs + identity + counters).
    public var uninstallArtifacts: [URL] {
        [configFile, identityFile, countersFile, installSentFile, hostsFile]
    }

    /// Derives config directory from `$HOME/.config/rv`. Returns nil when HOME is unset.
    public static func liveFromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AnalyticsPaths? {
        guard let home = environment["HOME"], home.isEmpty == false else { return nil }
        let url = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("rv", isDirectory: true)
        return AnalyticsPaths(configDirectory: url)
    }
}
