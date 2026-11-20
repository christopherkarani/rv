#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// The most `readRegularFile` reads by default.
package let regularFileReadLimit = 16 << 20

/// The whole file at `url` when it is a regular file of at most `limit`
/// bytes, or nil. Symlinks are followed, as `Data(contentsOf:)` follows
/// them, but the open is `O_NONBLOCK`, so a FIFO or device planted at the
/// path fails at once instead of hanging a reader that has to answer (the
/// hook-local evaluator inside the C hook's deadline, or rvd).
package func readRegularFile(_ url: URL, limit: Int = regularFileReadLimit) -> Data? {
    let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
    }
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= limit else { return nil }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else { return nil }
        if count == 0 { return data }
        data.append(contentsOf: buffer[0..<count])
        // Grown since the fstat.
        guard data.count <= limit else { return nil }
    }
}
