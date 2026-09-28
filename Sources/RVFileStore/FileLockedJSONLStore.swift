#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Failures from `FileLockedJSONLStore` operations.
public enum FileLockedJSONLStoreError: Error, Equatable, Sendable {
    /// Lock acquisition failed (unusable lock path, or a held lock under `nonBlocking`).
    case lockFailed
    /// A record failed JSON encoding; nothing was written.
    case encodeFailed
    /// Any filesystem I/O failure (permissions, missing parent, temp write, rename).
    case ioFailed
}

/// Generic JSONL persistence interpreter: `LOCK_EX` mutual exclusion,
/// temp-file + `rename(2)` atomicity, owner-only permissions.
///
/// Synchronous so it is callable from actor-isolated methods and from sync
/// ledger code. The `withLock` body is synchronous and non-`Sendable` so
/// actor-isolated caches stay accessible inside the critical section.
public struct FileLockedJSONLStore<Record: Codable & Sendable>: Sendable {
    /// Rows file. Must live in `directoryURL`.
    public let fileURL: URL
    /// Lock file. Must live in `directoryURL` so directory prep covers its parent.
    public let lockURL: URL
    /// Directory created (0700) by `save`/`withLock`. Assumed parent of `fileURL`/`lockURL`.
    public let directoryURL: URL

    /// Creates a store for `fileURL`, locking via `lockURL`.
    /// Both URLs must be inside `directoryURL`.
    public init(fileURL: URL, lockURL: URL, directoryURL: URL) {
        self.fileURL = fileURL
        self.lockURL = lockURL
        self.directoryURL = directoryURL
    }

    /// Creates a store rooted at `baseDirectory`: rows at `<base>/<fileName>`,
    /// lock at `<base>/<fileName>.lock`.
    public init(baseDirectory: URL, fileName: String) {
        let fileURL = baseDirectory.appendingPathComponent(fileName)
        self.init(
            fileURL: fileURL,
            lockURL: fileURL.appendingPathExtension("lock"),
            directoryURL: baseDirectory
        )
    }

    /// Non-throwing torn-line-tolerant load. Any read failure (missing
    /// file, permission denied, unreadable path) → `[]`; lines with invalid
    /// UTF-8 and undecodable, empty, or whitespace-only lines are skipped.
    /// Fail-open: callers cannot distinguish an empty store from a corrupt one.
    public func load() -> [Record] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Split the raw Data on LF bytes (stdlib: identical on Darwin and
        // corelibs) so one invalid byte drops only its own line instead of
        // the whole file: JSONEncoder never escapes U+2028/U+2029/VT/FF/NEL,
        // so those must not act as line separators. Byte-wise split keeps
        // CRLF loadable — the CR stays on the line and is stripped below.
        // Character-wise split cannot be used here: CRLF is a single
        // Character and would swallow the LF.
        return data.split(separator: 0x0A).compactMap { bytes in
            guard let line = String(bytes: bytes, encoding: .utf8) else {
                return nil
            }
            var withoutCR = line[...]
            while withoutCR.hasSuffix("\r") {
                withoutCR = withoutCR.dropLast()
            }
            let raw = withoutCR.trimmingCharacters(in: .whitespaces)
            guard raw.isEmpty == false,
                  let lineData = raw.data(using: .utf8),
                  let record = try? decoder.decode(Record.self, from: lineData)
            else {
                return nil
            }
            return record
        }
    }

    /// Atomic save: temp-file + `rename(2)`, 0600 on temp and final, 0700 on
    /// the directory. Codec is iso8601 + sortedKeys; trailing `\n` iff non-empty.
    ///
    /// Takes no lock: callers must hold `withLock` across load-modify-save.
    /// Concurrent saves without the lock race on the shared `<file>.tmp`.
    /// Full-file rewrite per call: sized for small rule stores, not append-heavy logs.
    public func save(_ records: [Record]) throws {
        try prepareDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var lines: [String] = []
        lines.reserveCapacity(records.count)
        for record in records {
            let data: Data
            do {
                data = try encoder.encode(record)
            } catch {
                throw FileLockedJSONLStoreError.encodeFailed
            }
            guard let line = String(data: data, encoding: .utf8) else {
                throw FileLockedJSONLStoreError.encodeFailed
            }
            lines.append(line)
        }
        let body = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        let temp = fileURL.appendingPathExtension("tmp")
        // Created 0600 from the first byte (no default-permission window) and
        // truncated, never exclusive: a stale tmp from a crashed save must not
        // block the next one. Single write + single rename; Foundation's own
        // temp+rename would double both.
        let fd = temp.path.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o600) }
        guard fd >= 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw FileLockedJSONLStoreError.ioFailed
        }
        let written = Data(body.utf8).withUnsafeBytes { raw in
            writeAll(fd: fd, bytes: raw)
        }
        let closed = close(fd) == 0
        guard written, closed else {
            try? FileManager.default.removeItem(at: temp)
            throw FileLockedJSONLStoreError.ioFailed
        }
        do {
            try setOwnerOnlyFile(temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw FileLockedJSONLStoreError.ioFailed
        }
        let renamed: Int32 = fileURL.withUnsafeFileSystemRepresentation { dest in
            temp.withUnsafeFileSystemRepresentation { src in
                guard let dest, let src else { return Int32(-1) }
                return rename(src, dest)
            }
        }
        guard renamed == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw FileLockedJSONLStoreError.ioFailed
        }
        do {
            try setOwnerOnlyFile(fileURL)
        } catch {
            throw FileLockedJSONLStoreError.ioFailed
        }
    }

    /// Runs `body` while holding `LOCK_EX` on the lock file. Prepares the
    /// directory (0700) first so the lock file's parent exists. Only lock
    /// failures map to `.lockFailed`; body errors rethrow untouched.
    /// Blocking wait ignores `Task` cancellation; callers needing
    /// cancellation should use `nonBlocking` with a `checkCancellation`
    /// retry loop.
    public func withLock<T>(nonBlocking: Bool = false, _ body: () throws -> T) throws -> T {
        try prepareDirectory()
        do {
            return try ExclusiveFileLock.withLock(
                at: lockURL,
                nonBlocking: nonBlocking
            ) {
                do {
                    return try body()
                } catch let lockError as ExclusiveFileLock.LockError {
                    throw BodyLockError(error: lockError)
                }
            }
        } catch let passthrough as BodyLockError {
            throw passthrough.error
        } catch is ExclusiveFileLock.LockError {
            throw FileLockedJSONLStoreError.lockFailed
        }
    }

    private func prepareDirectory() throws {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
        } catch {
            throw FileLockedJSONLStoreError.ioFailed
        }
    }

    private func setOwnerOnlyFile(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

/// Boxes a body-thrown `LockError` so `withLock` rethrows it untouched
/// instead of mapping it to `FileLockedJSONLStoreError.lockFailed`.
private struct BodyLockError: Error {
    let error: ExclusiveFileLock.LockError
}

/// Full `write(2)` loop with `EINTR` retry; `false` on short write or error.
private func writeAll(fd: Int32, bytes: UnsafeRawBufferPointer) -> Bool {
    var offset = 0
    while offset < bytes.count {
        guard let base = bytes.baseAddress else { return false }
        let written = write(fd, base.advanced(by: offset), bytes.count - offset)
        if written < 0 {
            if errno == EINTR { continue }
            return false
        }
        if written == 0 { return false }
        offset += written
    }
    return true
}
