import Foundation
import RVDomain
import RVFileStore

/// Shared read/update for `~/.config/rv/config.json` object keys.
/// `update` is the only writer; it serializes load-mutate-write under
/// `ExclusiveFileLock` on `lockURL(for:)` (cross-process and cross-thread:
/// each call opens its own descriptor, so `flock` excludes in-process callers too).
enum MachineConfigJSON {
    static func load(from file: URL) -> [String: JSONValue] {
        guard let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let root = value.asObject
        else {
            return [:]
        }
        return root
    }

    /// Lock sibling shared by every `config.json` writer: `<file>.lock`.
    static func lockURL(for file: URL) -> URL {
        file.appendingPathExtension("lock")
    }

    static func update(file: URL, mutate: (inout [String: JSONValue]) -> Void) throws {
        try prepareDirectory(of: file)
        try ExclusiveFileLock.withLock(at: lockURL(for: file)) {
            var root = load(from: file)
            mutate(&root)
            try write(root, to: file)
        }
    }

    private static func write(_ root: [String: JSONValue], to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(JSONValue.object(root)) else {
            throw SafetyStoreError.invalidFile
        }
        try prepareDirectory(of: file)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )
    }

    private static func prepareDirectory(of file: URL) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }
}
