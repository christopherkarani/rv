import Foundation

public struct DenialLedgerPaths: Sendable, Equatable {
    public var configDirectory: URL

    public init(configDirectory: URL) {
        self.configDirectory = configDirectory
    }

    public var fileURL: URL {
        configDirectory.appendingPathComponent("blocks.jsonl", isDirectory: false)
    }

    public var configFile: URL {
        configDirectory.appendingPathComponent("config.json", isDirectory: false)
    }

    public var uninstallArtifacts: [URL] {
        [fileURL]
    }
}
