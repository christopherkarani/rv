#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A connected stream socket whose peer has already sent `bytes` and hung
/// up, so a parser reading from it sees exactly those bytes then EOF. The
/// writer never blocks: when the socket buffer fills, the tail is dropped
/// and `delivered` says how much the reader will see.
struct FuzzSocket {
    let fd: Int32
    let delivered: [UInt8]

    static func feeding(_ bytes: [UInt8]) -> FuzzSocket? {
        var fds: [Int32] = [-1, -1]
        let made = fds.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            #if os(Linux)
            return socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, base)
            #else
            return socketpair(AF_UNIX, SOCK_STREAM, 0, base)
            #endif
        }
        guard made == 0 else { return nil }
        var size: Int32 = 256 * 1024
        for fd in fds {
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        let writer = fds[1]
        _ = fcntl(writer, F_SETFL, fcntl(writer, F_GETFL) | O_NONBLOCK)
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { write(writer, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            sent += count
        }
        _ = closeDescriptor(writer)
        return FuzzSocket(fd: fds[0], delivered: Array(bytes.prefix(sent)))
    }

    func close() {
        _ = closeDescriptor(fd)
    }
}

private func closeDescriptor(_ fd: Int32) -> Int32 {
    close(fd)
}
