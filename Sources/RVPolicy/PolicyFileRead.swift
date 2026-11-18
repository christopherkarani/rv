#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain

/// Reads a policy file the way evaluation may: never blocking on a FIFO or
/// device, never reading past a size cap. Evaluation re-reads policy on
/// every hook, so a file that could hang or balloon the read must fail
/// closed instead.
///
/// Following a symlink (`followSymlinks`) is safe for the policy layers:
/// the opened target must still be a regular file within the cap, and the
/// layers merge restrict-only under the ceiling. The ceiling itself is
/// read without following.
enum PolicyFileRead {
    enum Failure: Error, Sendable, Equatable {
        /// A path component is not a directory, so no file exists there.
        case notDirectory
        /// Present but refused.
        case refused(PolicyLoadStatus.Problem)
    }

    /// The file's UTF-8 text. Nil only when nothing exists at `url` (ENOENT).
    /// Throws `Failure`.
    static func text(at url: URL, maximumBytes: Int, followSymlinks: Bool) throws -> String? {
        guard let bytes = try bytes(at: url, maximumBytes: maximumBytes, followSymlinks: followSymlinks) else {
            return nil
        }
        guard let text = String(validating: bytes, as: UTF8.self) else { throw Failure.refused(.notUTF8) }
        return text
    }

    /// The file's bytes. Nil only when nothing exists at `url` (ENOENT).
    /// Throws `Failure`.
    static func bytes(at url: URL, maximumBytes: Int, followSymlinks: Bool) throws -> [UInt8]? {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | (followSymlinks ? 0 : O_NOFOLLOW))
        guard fd >= 0 else {
            switch errno {
            case ENOENT: return nil
            case ENOTDIR: throw Failure.notDirectory
            case ELOOP where followSymlinks == false: throw Failure.refused(.symlink)
            default: throw Failure.refused(.unreadable)
            }
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure.refused(.unreadable) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw Failure.refused(.notRegularFile) }
        guard info.st_size >= 0, Int(info.st_size) <= maximumBytes else { throw Failure.refused(.tooLarge) }
        var bytes = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw Failure.refused(.unreadable) }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
            // The file may grow after fstat.
            guard bytes.count <= maximumBytes else { throw Failure.refused(.tooLarge) }
        }
        return bytes
    }
}
