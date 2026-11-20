import Foundation
import RVFileStore
import RVHistory

/// Why an owner config write did not happen. Nothing was written in either
/// case.
public enum OwnerConfigWriteError: Error, Sendable, Equatable {
    /// The file exists but rv will not rewrite it: it cannot be read, or its
    /// text or shape is not one the writing store can rewrite without
    /// dropping or changing what it holds. Only the owner can say what was
    /// meant, so they fix the file by hand.
    case unreadable
    /// The directory could not be made owner-only, the new contents could
    /// not be rendered, or the file could not be put in place.
    case unwritable
}

/// The one locked read-modify-write of an owner config file in the rv
/// config directory (`config.json`, `config.toml`, `allowlist.toml`).
///
/// A store supplies only how its file parses and renders; each write
/// supplies the change and the audit event that names it. `update` then,
/// under the file's lock:
/// 1. reads the prior file strictly: a missing file is `empty`, but one
///    that cannot be read, or that `parse` rejects, throws `unreadable`
///    (never "empty", which would replace what the owner keeps there);
/// 2. applies `mutate` to a copy and renders it;
/// 3. commits the change event write-ahead (`ConfigChangeAudit.commit`), so
///    a loosening change the audit log cannot hold is not written;
/// 4. runs `beforeWrite`, then replaces the file atomically with one that is
///    owner-only from creation (`OwnerOnlyFile.write`), in a directory made
///    owner-only (0700) before the lock is taken.
struct OwnerConfigFile<Document> {
    var url: URL
    var lockURL: URL
    /// What a missing file holds.
    var empty: Document
    /// The document the file's bytes hold; nil refuses the write.
    var parse: (Data) -> Document?
    /// The bytes for a document; nil fails the write.
    var render: (Document) -> Data?

    /// `lockURL` defaults to `<file>.lock`.
    init(
        url: URL, lockURL: URL? = nil, empty: Document,
        parse: @escaping (Data) -> Document?, render: @escaping (Document) -> Data?
    ) {
        self.url = url
        self.lockURL = lockURL ?? url.appendingPathExtension("lock")
        self.empty = empty
        self.parse = parse
        self.render = render
    }

    var configDirectory: URL { url.deletingLastPathComponent() }

    /// `audit` gets the document before and after `mutate` and returns the
    /// event for the change, or nil when nothing the audit trail tracks
    /// changed (the file is still rewritten). `mutate` may throw; nothing is
    /// written then. A lock failure throws `ExclusiveFileLock.LockError`.
    func update(
        audit: (_ before: Document, _ after: Document) -> AuditEvent?,
        beforeWrite: () throws -> Void = {},
        mutate: (inout Document) throws -> Void
    ) throws {
        try prepareDirectory()
        try ExclusiveFileLock.withLock(at: lockURL) {
            let before = try readPrior()
            var after = before
            try mutate(&after)
            guard let data = render(after) else { throw OwnerConfigWriteError.unwritable }
            func apply() throws {
                try beforeWrite()
                guard OwnerOnlyFile.write(data, to: url) else { throw OwnerConfigWriteError.unwritable }
            }
            guard let event = audit(before, after) else { return try apply() }
            try ConfigChangeAudit.commit(event, configDirectory: configDirectory, apply)
        }
    }

    /// The prior document; the caller holds the lock, so it is the file the
    /// write replaces.
    private func readPrior() throws(OwnerConfigWriteError) -> Document {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return empty
        } catch {
            throw .unreadable
        }
        guard let document = parse(data) else { throw .unreadable }
        return document
    }

    /// Creates the directory and makes it owner-only, as it already is when
    /// rv made it: `OwnerOnlyFile.write` only sets the mode on a directory
    /// it creates.
    private func prepareDirectory() throws(OwnerConfigWriteError) {
        do {
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configDirectory.path)
        } catch {
            throw .unwritable
        }
    }
}
