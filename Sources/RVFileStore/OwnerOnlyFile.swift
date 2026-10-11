#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Owner-only file read failure. Fixed labels; never paths or contents.
///
/// Callers map these onto their own error types: the stores agree on the
/// low-level outcomes but disagree on what each means (an operator store
/// with a missing file loads its empty default; Vault denies), so every
/// distinguishable outcome is its own case.
public enum OwnerOnlyFileError: Error, Sendable, Equatable {
    /// The directory or file does not exist.
    case missing
    /// The directory or file could not be opened (permissions, symlink,
    /// or wrong type). Distinct from `.unsafeLocation`, which is the
    /// fstat verdict, so callers map each arm exactly once.
    case inaccessible
    /// The directory or file failed the owner-only checks.
    case unsafeLocation
    /// The file could not be read.
    case unreadable
    /// The file exceeds the size cap.
    case oversized
}

/// Shared owner-only file reader for the operator stores.
///
/// Discipline, identical for every caller: open the directory
/// (`O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC`), require owner-owned
/// without group/other write, open the file relative to it
/// (`O_RDONLY|O_NOFOLLOW|O_CLOEXEC`), require a regular owner-owned file
/// with no group/other permission bits (`& 0o177 == 0`), enforce the size
/// cap before and after the `EINTR`-retrying read loop. Returns the exact
/// file bytes; decoding stays with the caller (pure `decode` split), as
/// does the error mapping.
public enum OwnerOnlyFile {
    /// Reads `fileName` under `configDirectory` through the owner-only
    /// discipline, capped at `maximumBytes`.
    public static func loadBytes(
        fileName: String,
        from configDirectory: URL,
        maximumBytes: Int
    ) -> Result<Data, OwnerOnlyFileError> {
        let directory = configDirectory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        if directory < 0 {
            return .failure(errno == ENOENT ? .missing : .inaccessible)
        }
        defer { close(directory) }
        var directoryStatus = stat()
        guard fstat(directory, &directoryStatus) == 0,
            directoryStatus.st_uid == getuid(),
            (directoryStatus.st_mode & 0o022) == 0
        else {
            return .failure(.unsafeLocation)
        }
        let file = fileName.withCString {
            openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if file < 0 {
            return .failure(errno == ENOENT ? .missing : .inaccessible)
        }
        defer { close(file) }
        var fileStatus = stat()
        guard fstat(file, &fileStatus) == 0,
            (fileStatus.st_mode & S_IFMT) == S_IFREG,
            fileStatus.st_uid == getuid(),
            (fileStatus.st_mode & 0o177) == 0
        else {
            return .failure(.unsafeLocation)
        }
        guard fileStatus.st_size >= 0, fileStatus.st_size <= Int64(maximumBytes) else {
            return .failure(.oversized)
        }
        var bytes = [UInt8](repeating: 0, count: maximumBytes + 1)
        var count = 0
        while count < bytes.count {
            let remaining = bytes.count - count
            let result = bytes.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return -1 }
                return read(file, base.advanced(by: count), remaining)
            }
            if result > 0 { count += result; continue }
            if result == 0 { break }
            if errno == EINTR { continue }
            return .failure(.unreadable)
        }
        guard count <= maximumBytes else { return .failure(.oversized) }
        return .success(Data(bytes.prefix(count)))
    }
}
