#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

public enum OwnerOnlyFileError: Error, Sendable, Equatable {
    case unsafe(String)
    case unreadable
    case oversized
}

enum CheckedFileReadError: Error, Sendable, Equatable {
    case unsafe(String)
    case unreadable
    case oversized
}

/// Reads and atomic writes for rv configuration that only its owner may change.
public enum OwnerOnlyFile {
    /// Nil when the file does not exist. Anything that is not a regular,
    /// owner-owned, non-group/world-writable file is refused. A
    /// `confidential` read also refuses group/world-readable files.
    public static func read(_ url: URL, maximumBytes: Int, confidential: Bool = false) -> Result<Data?, OwnerOnlyFileError> {
        // O_NONBLOCK so a FIFO cannot hang open() before the S_ISREG check.
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return .success(nil) }
            if errno == ELOOP { return .failure(.unsafe("symlink")) }
            return .failure(.unreadable)
        }
        defer { close(fd) }
        switch checkedRead(fd: fd, maximumBytes: maximumBytes, confidential: confidential) {
        case .success(let (data, _)): return .success(data)
        case .failure(.unsafe(let reason)): return .failure(.unsafe(reason))
        case .failure(.oversized): return .failure(.oversized)
        case .failure(.unreadable): return .failure(.unreadable)
        }
    }

    /// Shared trust checks + bounded read for an already-open descriptor
    /// (opened `O_NOFOLLOW | O_NONBLOCK`): regular file, owner-owned, not
    /// group/world-writable, `st_size` checked before allocating. Used by
    /// `read` above and by the dotenv reader, which canonicalizes first.
    static func checkedRead(
        fd: Int32, maximumBytes: Int, confidential: Bool = false
    ) -> Result<(Data, stat), CheckedFileReadError> {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .failure(.unreadable) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .failure(.unsafe("not a regular file")) }
        guard info.st_uid == getuid() else { return .failure(.unsafe("owned by another user")) }
        guard (info.st_mode & 0o022) == 0 else { return .failure(.unsafe("group or world writable")) }
        if confidential, (info.st_mode & 0o044) != 0 { return .failure(.unsafe("group or world readable")) }
        guard info.st_size <= maximumBytes else { return .failure(.oversized) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size) + 1)
        var count = 0
        while count < bytes.count {
            let n = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return posixRead(fd, base + count, raw.count - count)
            }
            if n < 0, errno == EINTR { continue }
            guard n >= 0 else { return .failure(.unreadable) }
            if n == 0 { break }
            count += n
        }
        guard count <= maximumBytes else { return .failure(.oversized) }
        // Bind the returned identity to the bytes actually read: a writer
        // during the loop must not yield a torn buffer carrying the
        // pre-read generation's stat.
        var after = stat()
        guard fstat(fd, &after) == 0 else { return .failure(.unreadable) }
        guard sameGeneration(info, after), count == Int(info.st_size) else {
            return .failure(.unsafe("changed while reading"))
        }
        return .success((Data(bytes.prefix(count)), after))
    }

    private static func sameGeneration(_ lhs: stat, _ rhs: stat) -> Bool {
        #if canImport(Darwin)
        let lhsTime = lhs.st_mtimespec
        let rhsTime = rhs.st_mtimespec
        #else
        let lhsTime = lhs.st_mtim
        let rhsTime = rhs.st_mtim
        #endif
        return lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
            && lhs.st_uid == rhs.st_uid && lhs.st_mode == rhs.st_mode
            && lhs.st_size == rhs.st_size
            && lhsTime.tv_sec == rhsTime.tv_sec && lhsTime.tv_nsec == rhsTime.tv_nsec
    }

    /// Temp file (0600) + fsync + rename in the same directory, which is
    /// created 0700 when missing.
    public static func write(_ data: Data, to url: URL) -> Bool {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return false
        }
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        var written = 0
        while written < data.count {
            let n = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return posixWrite(fd, base + written, raw.count - written)
            }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            written += n
        }
        let synced = fsync(fd) == 0
        close(fd)
        guard written == data.count, synced, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        // The rename itself is only durable once the directory is synced;
        // without it a crash can resurrect the previous file (for the serial
        // watermark, that re-opens the rollback window).
        let directoryFD = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard directoryFD >= 0 else { return false }
        let directorySynced = fsync(directoryFD) == 0
        close(directoryFD)
        return directorySynced
    }
}

private func posixRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.read(fd, buffer, count)
    #else
    Glibc.read(fd, buffer, count)
    #endif
}

private func posixWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.write(fd, buffer, count)
    #else
    Glibc.write(fd, buffer, count)
    #endif
}
