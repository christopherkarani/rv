import Foundation
import RVDomain
import RVFileStore

/// Shared read/update for `~/.config/rv/config.json` object keys.
/// `update` is the only writer; it serializes load-mutate-write under
/// `ExclusiveFileLock` on `lockURL(for:)` (cross-process and cross-thread:
/// each call opens its own descriptor, so `flock` excludes in-process callers too).
enum MachineConfigJSONError: Error, Equatable {
    /// `config.json` exists but does not decode as a JSON object.
    case notAnObject
}

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

    /// `update` for writers that must not drop keys they cannot read: the
    /// existing file (a missing one is `{}`) must decode as a JSON object,
    /// checked under the lock, or `notAnObject` is thrown and nothing is
    /// written. `mutate` may throw; nothing is written then either.
    static func updateExistingObject(
        file: URL,
        mutate: (inout [String: JSONValue]) throws -> Void
    ) throws {
        try prepareDirectory(of: file)
        try ExclusiveFileLock.withLock(at: lockURL(for: file)) {
            var root = try loadObject(from: file)
            try mutate(&root)
            try write(root, to: file)
        }
    }

    private static func loadObject(from file: URL) throws -> [String: JSONValue] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let data = try Data(contentsOf: file)
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let root = value.asObject
        else {
            throw MachineConfigJSONError.notAnObject
        }
        return root
    }

    private static func write(_ root: [String: JSONValue], to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(JSONValue.object(root)) else {
            throw SafetyStoreError.invalidFile
        }
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
