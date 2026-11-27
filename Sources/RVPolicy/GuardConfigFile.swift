import Foundation
import RVDomain
import RVFileStore

/// Shell reader for the guard keys of `~/.config/rv/config.json`. Decoding
/// and resolution are pure (`GuardConfig(_:)`, `GuardModeResolution`); this
/// is the one place the file is read for them.
extension GuardConfig {
    /// The guard config in `<configDirectory>/config.json`. A missing or
    /// unreadable file is `.empty` (enforce); so is any file
    /// `GuardConfig(jsonData:)` rejects, and anything but a regular file
    /// (a FIFO there fails at once instead of hanging the evaluation).
    public static func read(configDirectory: URL) -> GuardConfig {
        let file = configDirectory.appendingPathComponent("config.json")
        guard let data = readRegularFile(file) else { return .empty }
        return GuardConfig(jsonData: data)
    }

    /// The guard config under `home`'s rv config directory; `.empty` when
    /// there is no home.
    public static func read(home: HomeDirectory?) -> GuardConfig {
        guard let home else { return .empty }
        return read(configDirectory: RVPolicyPaths.configDirectory(home: home))
    }
}
