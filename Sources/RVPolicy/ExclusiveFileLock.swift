#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Internal. Single owner of the create-validate-chmod-open-flock-unlock protocol.
enum ExclusiveFileLock {
    /// Runs `body` while holding LOCK_EX on the lock file at `lockURL`.
    /// Creates the lock file owner-only if missing; throws `LockError` on any failure.
    /// `nonBlocking` uses `LOCK_NB` so a held lock fails closed instead of waiting.
    static func withLock<T>(at lockURL: URL, nonBlocking: Bool = false, _ body: () throws -> T) throws -> T {
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
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: lockURL.path
            )
            fd = lockURL.path.withCString { path in
                open(path, O_RDWR | O_CREAT, 0o600)
            }
        }
        guard fd >= 0 else { throw LockError.lockFailed }
        defer { close(fd) }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: lockURL.path
        )
        let flags = nonBlocking ? (LOCK_EX | LOCK_NB) : LOCK_EX
        guard flock(fd, flags) == 0 else { throw LockError.lockFailed }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    enum LockError: Error, Equatable {
        case lockFailed
    }
}
