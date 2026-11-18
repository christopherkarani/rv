import Foundation
import RVDomain
import RVFileStore
import RVHistory

/// Shared read/update for `~/.config/rv/config.json` object keys.
/// `update` is the only writer; it serializes load-mutate-write under
/// `ExclusiveFileLock` on `lockURL(for:)` (cross-process and cross-thread:
/// each call opens its own descriptor, so `flock` excludes in-process callers too).
public enum MachineConfigJSONError: Error, Sendable, Equatable {
    /// `config.json` exists but rv will not rewrite it: `JSONDuplicateKeys`
    /// rejects its text (a repeated key, a key holding U+FEFF, nesting past
    /// `maxNestingDepth`, or text that is not UTF-8), or, for
    /// `updateExistingObject`, it does not decode as a JSON object.
    case unreadableConfig
}

enum MachineConfigJSON {
    static func load(from file: URL) -> [String: JSONValue] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return object(in: data) ?? [:]
    }

    private static func object(in data: Data) -> [String: JSONValue]? {
        (try? JSONDecoder().decode(JSONValue.self, from: data))?.asObject
    }

    /// Throws `unreadableConfig` for text `JSONDuplicateKeys` rejects, the
    /// text `GuardConfig(jsonData:)` reads as enforce: `JSONDecoder` keeps
    /// the first copy of a repeated key, so rewriting it could store the
    /// copy that reads as observe.
    private static func requireRewritable(_ data: Data) throws(MachineConfigJSONError) {
        guard JSONDuplicateKeys.allObjectKeysDistinct(data) else { throw .unreadableConfig }
    }

    /// `update`'s prior object: `load`'s reading, except that text
    /// `requireRewritable` rejects throws.
    private static func loadRewritable(from file: URL) throws -> [String: JSONValue] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        try requireRewritable(data)
        return object(in: data) ?? [:]
    }

    /// Lock sibling shared by every `config.json` writer: `<file>.lock`.
    static func lockURL(for file: URL) -> URL {
        file.appendingPathExtension("lock")
    }

    /// The audit event for a write, from the object before and after
    /// `mutate`; nil when nothing the audit trail tracks changed.
    typealias ChangeEvent = (_ before: [String: JSONValue], _ after: [String: JSONValue]) -> AuditEvent?

    /// A file that does not decode as an object is replaced by `{}` plus
    /// `mutate`; text `JSONDuplicateKeys` rejects throws `unreadableConfig`
    /// and nothing is written.
    static func update(
        file: URL, audit: ChangeEvent? = nil, mutate: (inout [String: JSONValue]) -> Void
    ) throws {
        try prepareDirectory(of: file)
        try ExclusiveFileLock.withLock(at: lockURL(for: file)) {
            let before = try loadRewritable(from: file)
            var root = before
            mutate(&root)
            try write(root, to: file, audit: audit?(before, root))
        }
    }

    /// `update` for writers that must not drop keys they cannot read: the
    /// existing file (a missing one is `{}`) must decode as a JSON object
    /// that `JSONDuplicateKeys` accepts, checked under the lock, or
    /// `unreadableConfig` is thrown and nothing is written. `mutate` may throw; nothing is written then either.
    ///
    /// `beforeWrite` runs after the audit event is recorded and before the
    /// file moves, for a side effect that must not happen unrecorded.
    static func updateExistingObject(
        file: URL,
        audit: ChangeEvent? = nil,
        beforeWrite: () throws -> Void = {},
        mutate: (inout [String: JSONValue]) throws -> Void
    ) throws {
        try prepareDirectory(of: file)
        try ExclusiveFileLock.withLock(at: lockURL(for: file)) {
            let before = try loadObject(from: file)
            var root = before
            try mutate(&root)
            try write(root, to: file, audit: audit?(before, root), beforeWrite: beforeWrite)
        }
    }

    private static func loadObject(from file: URL) throws -> [String: JSONValue] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let data = try Data(contentsOf: file)
        try requireRewritable(data)
        guard let root = object(in: data) else { throw MachineConfigJSONError.unreadableConfig }
        return root
    }

    /// Writes `root`; with an `audit` event, write-ahead through
    /// `ConfigChangeAudit.commit`, so a change the log cannot hold is not
    /// written. The caller holds the lock, so prior and new are exact.
    private static func write(
        _ root: [String: JSONValue], to file: URL, audit: AuditEvent?, beforeWrite: () throws -> Void = {}
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(JSONValue.object(root)) else {
            throw SafetyStoreError.invalidFile
        }
        func apply() throws {
            try beforeWrite()
            try replace(file, with: data)
        }
        guard let audit else { return try apply() }
        try ConfigChangeAudit.commit(audit, configDirectory: file.deletingLastPathComponent(), apply)
    }

    private static func replace(_ file: URL, with data: Data) throws {
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
