import Foundation
import RVDomain

/// Merge / inspect / uninstall for the single `managed_hooks_path` key in
/// `$HOME/.config/muse/settings.json`.
///
/// Unlike the hooks-block merges, this touches exactly one top-level key and
/// never the user's own `hooks` block. Fail-closed throughout: a missing,
/// malformed, or wrong-schema settings file is unmergeable (setup skips, it
/// never writes a file that would break muse startup), and a foreign key
/// value is occupied (never overwritten, even under `--force`).
enum MuseSettingsMerge {
    static let settingsFileName = "settings.json"
    static let managedHooksKey = "managed_hooks_path"
    static let schemaVersion = 1

    /// Classification of settings bytes against our hooks path.
    enum State: Equatable, Sendable {
        /// Key points at our hooks file.
        case ours
        /// Key points elsewhere; occupied, never overwrite.
        case foreignKey
        /// Valid settings, key absent; setup merges the key.
        case missingKey
        /// Missing file, malformed JSON, non-object root, or wrong/missing
        /// `schema_version`; setup skips, never writes or seeds.
        case unmergeable
    }

    /// Sibling settings path for a hooks-file destination.
    static func settingsPath(hooksPath: String) -> String {
        (hooksPath as NSString).deletingLastPathComponent + "/" + settingsFileName
    }

    /// Classifies `data` (`nil` = missing file) against `hooksPath`.
    static func inspect(_ data: Data?, hooksPath: String) -> State {
        guard let data,
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let root = value.asObject,
              root["schema_version"]?.int == schemaVersion
        else {
            return .unmergeable
        }
        guard let keyed = root[managedHooksKey] else {
            return .missingKey
        }
        guard let path = keyed.string, path.isEmpty == false else {
            return .unmergeable
        }
        return path == hooksPath ? .ours : .foreignKey
    }

    /// Sets `managed_hooks_path` to `hooksPath` when the key is absent.
    /// Returns merged bytes and whether content changed. All other keys are
    /// preserved; rendering matches the house merge output (sorted keys,
    /// pretty printed). Unmergeable or already-keyed settings return the
    /// input unchanged with `wrote: false` — never throws for expected
    /// states, so setup skips instead of failing the run.
    static func merge(existingData: Data?, hooksPath: String) -> (data: Data, wrote: Bool) {
        guard let existingData,
              let value = try? JSONDecoder().decode(JSONValue.self, from: existingData),
              let root = value.asObject,
              root["schema_version"]?.int == schemaVersion,
              root[managedHooksKey] == nil,
              let rendered = render(root: rootWithKey(root, hooksPath: hooksPath))
        else {
            return (existingData ?? Data(), false)
        }
        return (rendered, true)
    }

    /// Removes `managed_hooks_path` only when it points at `hooksPath`.
    /// Foreign keys and unmergeable bytes are returned unchanged.
    static func strip(existingData: Data, hooksPath: String) -> (data: Data, changed: Bool) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: existingData),
              var root = value.asObject,
              root[managedHooksKey]?.string == hooksPath
        else {
            return (existingData, false)
        }
        root.removeValue(forKey: managedHooksKey)
        guard let rendered = render(root: root) else {
            return (existingData, false)
        }
        return (rendered, true)
    }

    private static func rootWithKey(_ root: [String: JSONValue], hooksPath: String) -> [String: JSONValue] {
        var next = root
        next[managedHooksKey] = .string(hooksPath)
        return next
    }

    private static func render(root: [String: JSONValue]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try? encoder.encode(JSONValue.object(root))
    }
}
