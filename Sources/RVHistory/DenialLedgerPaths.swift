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

    public var lockURL: URL {
        configDirectory.appendingPathComponent("blocks.lock", isDirectory: false)
    }

    public var uninstallArtifacts: [URL] {
        // The .tmp entry covers save()'s crash window: temp-file + rename(2)
        // can leave blocks.jsonl.tmp behind, which uninstall must not orphan.
        [fileURL, lockURL, fileURL.appendingPathExtension("tmp")]
    }
}
