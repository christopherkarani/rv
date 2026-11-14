#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Single owner of the create-validate-chmod-open-flock-unlock protocol.
/// Moved from RVPolicy; semantics unchanged.
public enum ExclusiveFileLock {
    /// Runs `body` while holding LOCK_EX on the lock file at `lockURL`.
    /// Creates the lock file owner-only if missing; throws `LockError` on any failure.
    /// `nonBlocking` uses `LOCK_NB` so a held lock fails closed instead of waiting.
    public static func withLock<T>(
        at lockURL: URL,
        nonBlocking: Bool = false,
        _ body: () throws -> T
    ) throws -> T {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: lockURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue == true
        {
            throw LockError.lockFailed
        }
        var fd = lockURL.path.withCString { path in
            open(path, O_RDWR | O_CREAT, 0o600)
        }
        if fd < 0, errno == EACCES {
            // Pre-existing mode denied the owner write access. The owner can always
            // chmod its own file, so re-assert 0600 and retry once.
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: lockURL.path
                )
            } catch {
                throw LockError.lockFailed
            }
            fd = lockURL.path.withCString { path in
                open(path, O_RDWR | O_CREAT, 0o600)
            }
        }
        guard fd >= 0 else { throw LockError.lockFailed }
        defer { close(fd) }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: lockURL.path
            )
        } catch {
            throw LockError.lockFailed
        }
        let flags = nonBlocking ? (LOCK_EX | LOCK_NB) : LOCK_EX
        guard flock(fd, flags) == 0 else { throw LockError.lockFailed }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    /// Read-side twin of `withLock` that never touches the filesystem: opens
    /// an existing lock file read-only (no create, no chmod) and holds
    /// LOCK_EX across `body`. A missing lock file runs `body` unlocked, since
    /// creating one would be a write. A directory, a non-regular file, or
    /// any other open or `flock` failure throws `LockError`. `O_NONBLOCK`
    /// keeps a FIFO planted at the lock path from blocking the open before
    /// the regular-file check; it does not make `flock` non-blocking.
    public static func withExistingLock<T>(at lockURL: URL, _ body: () throws -> T) throws -> T {
        let fd = lockURL.path.withCString { path in
            open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        if fd < 0 {
            guard errno == ENOENT else { throw LockError.lockFailed }
            return try body()
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw LockError.lockFailed
        }
        guard flock(fd, LOCK_EX) == 0 else { throw LockError.lockFailed }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    /// Failures from `ExclusiveFileLock.withLock` and `withExistingLock`.
    public enum LockError: Error, Equatable, Sendable {
        /// Lock file setup, chmod, or `flock` failed.
        case lockFailed
    }
}
