import Foundation
import RVDomain

/// Shell reader for the guard keys of `~/.config/rv/config.json`. Decoding
/// and resolution are pure (`GuardConfig(_:)`, `GuardModeResolution`); this
/// is the one place the file is read for them.
extension GuardConfig {
    /// The guard config in `<configDirectory>/config.json`. A missing,
    /// unreadable or non-object file is `.empty` (enforce).
    public static func read(configDirectory: URL) -> GuardConfig {
        let file = configDirectory.appendingPathComponent("config.json")
        return GuardConfig(.object(MachineConfigJSON.load(from: file)))
    }

    /// The guard config under `home`'s rv config directory; `.empty` when
    /// there is no home.
    public static func read(home: HomeDirectory?) -> GuardConfig {
        guard let home else { return .empty }
        return read(configDirectory: RVPolicyPaths.configDirectory(home: home))
    }
}
