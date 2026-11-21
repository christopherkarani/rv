import Foundation
import RVDomain
import RVFileStore
import RVHistory

/// `~/.config/rv/config.json`: a lenient reader and the file's writes.
/// Every write goes through `OwnerConfigFile` under `lockURL(for:)`
/// (cross-process and cross-thread: each write opens its own descriptor,
/// so `flock` excludes in-process callers too).
enum MachineConfigJSON {
    static func load(from file: URL) -> [String: JSONValue] {
        guard let data = readRegularFile(file) else { return [:] }
        return (try? JSONDecoder().decode(JSONValue.self, from: data))?.asObject ?? [:]
    }

    /// Lock sibling shared by every `config.json` writer: `<file>.lock`.
    static func lockURL(for file: URL) -> URL {
        file.appendingPathExtension("lock")
    }

    /// `config.json` as an owner config file. The prior file must decode as
    /// a JSON object whose text `JSONDuplicateKeys` accepts, or the write is
    /// refused (`OwnerConfigWriteError.unreadable`): that rejects a repeated
    /// key, a key holding U+FEFF, nesting past `maxNestingDepth`, and text
    /// that is not UTF-8, the text `GuardConfig(jsonData:)` reads as
    /// enforce. `JSONDecoder` keeps the first copy of a repeated key, so
    /// rewriting such text could store the copy that reads as observe.
    static func file(_ url: URL) -> OwnerConfigFile<[String: JSONValue]> {
        OwnerConfigFile(url: url, lockURL: lockURL(for: url), empty: [:], parse: rewritableObject, render: render)
    }

    private static func rewritableObject(_ data: Data) -> [String: JSONValue]? {
        guard JSONDuplicateKeys.allObjectKeysDistinct(data) else { return nil }
        return (try? JSONDecoder().decode(JSONValue.self, from: data))?.asObject
    }

    private static func render(_ root: [String: JSONValue]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try? encoder.encode(JSONValue.object(root))
    }

    /// One value a store writes in `config.json`, and how its changes read
    /// in the audit trail.
    struct Setting: Sendable {
        /// Object keys from the root, e.g. `["guard", "hosts", "claude"]`;
        /// joined with `.` they are the audited setting name.
        var keyPath: [String]
        /// How a stored value reads as the event's `prior` and `new`; nil is
        /// a missing key. Equal readings record no event.
        var describe: @Sendable (JSONValue?) -> String
        /// Which way replacing the stored value (nil when missing) with the
        /// new one moves the gate.
        var direction: @Sendable (_ prior: JSONValue?, _ new: JSONValue) -> ConfigChangeAudit.Direction

        var name: String { keyPath.joined(separator: ".") }
    }

    /// Stores `value` at `setting.keyPath`; every other key is kept. Each
    /// key on the way must hold an object or nothing (an object is then
    /// created): any other value is refused (`unreadable`), since replacing
    /// it would drop what the owner keeps there. Records `config.changed`
    /// (`setting.name`) write-ahead when the described value changes.
    /// `beforeWrite` runs after that record and before the file moves.
    static func set(
        _ value: JSONValue, for setting: Setting, in url: URL, beforeWrite: () throws -> Void = {}
    ) throws {
        guard setting.keyPath.isEmpty == false else { throw OwnerConfigWriteError.unwritable }
        try file(url).update(
            audit: { before, _ in
                let stored = storedValue(at: setting.keyPath, in: before)
                let prior = setting.describe(stored)
                let new = setting.describe(value)
                guard prior != new else { return nil }
                return ConfigChangeAudit.setting(
                    setting.name, from: prior, to: new, direction: setting.direction(stored, value))
            },
            beforeWrite: beforeWrite,
            mutate: { root in try store(value, at: setting.keyPath[...], in: &root) })
    }

    private static func storedValue(at keyPath: [String], in root: [String: JSONValue]) -> JSONValue? {
        var current: JSONValue? = .object(root)
        for key in keyPath {
            current = current?[key]
        }
        return current
    }

    private static func store(
        _ value: JSONValue, at keyPath: ArraySlice<String>, in object: inout [String: JSONValue]
    ) throws(OwnerConfigWriteError) {
        guard let key = keyPath.first else { return }
        let rest = keyPath.dropFirst()
        guard rest.isEmpty == false else {
            object[key] = value
            return
        }
        var child: [String: JSONValue] = [:]
        if let existing = object[key] {
            guard let existingObject = existing.asObject else { throw .unreadable }
            child = existingObject
        }
        try store(value, at: rest, in: &child)
        object[key] = .object(child)
    }
}
