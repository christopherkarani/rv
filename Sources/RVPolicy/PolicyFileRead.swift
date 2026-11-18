#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Reads a policy file the way evaluation may: never blocking on a FIFO or
/// device, never reading past a size cap. Evaluation re-reads policy on
/// every hook, so a file that could hang or balloon the read must fail
/// closed instead.
enum PolicyFileRead {
    enum Failure: Error, Sendable, Equatable {
        /// A path component is not a directory, so no file exists there.
        case notDirectory
        /// Present but not a readable regular file within the cap: a
        /// symlink (when not followed), FIFO, directory, device, EACCES,
        /// an oversized file, or invalid UTF-8.
        case invalid
    }

    /// The file's UTF-8 text. Nil only when nothing exists at `url` (ENOENT).
    static func text(at url: URL, maximumBytes: Int, followSymlinks: Bool) throws(Failure) -> String? {
        guard let bytes = try bytes(at: url, maximumBytes: maximumBytes, followSymlinks: followSymlinks) else {
            return nil
        }
        guard let text = String(validating: bytes, as: UTF8.self) else { throw .invalid }
        return text
    }

    /// The file's bytes. Nil only when nothing exists at `url` (ENOENT).
    static func bytes(at url: URL, maximumBytes: Int, followSymlinks: Bool) throws(Failure) -> [UInt8]? {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | (followSymlinks ? 0 : O_NOFOLLOW))
        guard fd >= 0 else {
            switch errno {
            case ENOENT: return nil
            case ENOTDIR: throw .notDirectory
            default: throw .invalid
            }
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            info.st_size >= 0, Int(info.st_size) <= maximumBytes
        else {
            throw .invalid
        }
        var bytes = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw .invalid }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
            // The file may grow after fstat.
            guard bytes.count <= maximumBytes else { throw .invalid }
        }
        return bytes
    }
}
