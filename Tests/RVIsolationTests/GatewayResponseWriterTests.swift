#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import Testing
@testable import RVIsolation

@Suite("Gateway response writer")
struct GatewayResponseWriterTests {
    /// The scrubber holds a body's last byte back while it could begin the
    /// secret, and `finish` writes it as the last chunk. When that write
    /// times out against a full socket, the terminator must not follow: the
    /// client would read a well-formed body missing its last byte.
    @Test(.timeLimit(.minutes(1)))
    func aTailThatCannotBeWrittenIsNotFollowedByTheTerminator() throws {
        var ends: [Int32] = [0, 0]
        #if canImport(Darwin)
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0)
        var one: Int32 = 1
        _ = setsockopt(ends[0], SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #else
        try #require(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &ends) == 0)
        #endif
        let (writerEnd, readerEnd) = (ends[0], ends[1])
        defer { close(readerEnd) }
        var sendTimeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(writerEnd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        let secret = Array("sk-live-REAL-0123456789".utf8)
        let writer = GatewayResponseWriter(
            fd: writerEnd, method: "GET", scrub: [(secret, Array("sk-placeholder".utf8))])
        writer.head(status: 200, headers: [(name: "Content-Type", value: "text/plain")])
        // "s" could begin the secret, so it is held back for `finish`.
        #expect(writer.body(Data("hello s".utf8)))
        try Self.fill(writerEnd)
        // Drained from 1.5 s: after the tail's write has timed out, before
        // a terminator written after it would.
        let drained = DispatchSemaphore(value: 0)
        let received = Received()
        let started = DispatchTime.now()
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 1.5)
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                let n = buffer.withUnsafeMutableBytes { read(readerEnd, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                received.append(buffer.prefix(n))
            }
            drained.signal()
        }
        writer.finish()
        let finished = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
        close(writerEnd)
        #expect(drained.wait(timeout: .now() + 10) == .success)
        let tail = received.suffix(5)
        #expect(tail != Array("0\r\n\r\n".utf8), "a body missing its tail ended like a complete one")
        #expect(finished < 1.4, "finish wrote again after the tail's write failed (\(finished) s)")
    }

    /// Fills the socket's buffer until a write would block.
    private static func fill(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL, 0)
        try #require(flags >= 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, flags) }
        for size in [65_536, 1] {
            let filler = [UInt8](repeating: UInt8(ascii: "f"), count: size)
            while true {
                let n = filler.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, GatewaySocket.sendFlags) }
                if n < 0, errno == EINTR { continue }
                if n <= 0 { break }
            }
        }
    }
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    func append(_ more: ArraySlice<UInt8>) {
        lock.lock()
        bytes += more
        lock.unlock()
    }

    func suffix(_ count: Int) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return Array(bytes.suffix(count))
    }
}
