#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

public enum FileLockedStoreError: Error, Equatable, Sendable {
    case lockFailed
    case encodeFailed
    case ioFailed
}

/// Generic JSONL persistence interpreter: `LOCK_EX` mutual exclusion,
/// temp-file + `rename(2)` atomicity, owner-only permissions.
///
/// Synchronous so it is callable from actor-isolated methods and from sync
/// ledger code. The `withLock` body is synchronous and non-`Sendable` so
/// actor-isolated caches stay accessible inside the critical section.
public struct FileLockedJSONLStore<Record: Codable & Sendable>: Sendable {
    public var fileURL: URL
    public var lockURL: URL
    public var directoryURL: URL

    public init(fileURL: URL, lockURL: URL, directoryURL: URL) {
        self.fileURL = fileURL
        self.lockURL = lockURL
        self.directoryURL = directoryURL
    }

    /// Non-throwing torn-line-tolerant load. Missing file → `[]`;
    /// undecodable, empty, or whitespace-only lines are skipped.
    public func load() -> [Record] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8)
        else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let raw = line.trimmingCharacters(in: .whitespaces)
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
    public func save(_ records: [Record]) throws -> Void {
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
                throw FileLockedStoreError.encodeFailed
            }
            guard let line = String(data: data, encoding: .utf8) else {
                throw FileLockedStoreError.encodeFailed
            }
            lines.append(line)
        }
        let body = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        let temp = fileURL.appendingPathExtension("tmp")
        do {
            try body.write(to: temp, atomically: true, encoding: .utf8)
        } catch {
            throw FileLockedStoreError.ioFailed
        }
        do {
            try setOwnerOnlyFile(temp)
        } catch {
            throw FileLockedStoreError.ioFailed
        }
        let renamed: Int32 = fileURL.withUnsafeFileSystemRepresentation { dest in
            temp.withUnsafeFileSystemRepresentation { src in
                guard let dest, let src else { return Int32(-1) }
                return rename(src, dest)
            }
        }
        guard renamed == 0 else { throw FileLockedStoreError.ioFailed }
        do {
            try setOwnerOnlyFile(fileURL)
        } catch {
            throw FileLockedStoreError.ioFailed
        }
    }

    /// Runs `body` while holding `LOCK_EX` on the lock file. Prepares the
    /// directory (0700) first so the lock file's parent exists. Only lock
    /// failures map to `.lockFailed`; body errors rethrow untouched.
    public func withLock<T>(nonBlocking: Bool = false, _ body: () throws -> T) throws -> T {
        try prepareDirectory()
        do {
            return try ExclusiveFileLock.withLock(
                at: lockURL,
                nonBlocking: nonBlocking,
                body
            )
        } catch let error as ExclusiveFileLock.LockError {
            switch error {
            case .lockFailed:
                throw FileLockedStoreError.lockFailed
            }
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
            throw FileLockedStoreError.ioFailed
        }
    }

    private func setOwnerOnlyFile(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
