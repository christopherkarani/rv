import Darwin
import Foundation

/// Bidirectional byte bridge between two connected stream sockets.
public enum SocketBridge {
    /// A peer that vanishes must surface as `EPIPE` from `write`, never as a
    /// process-killing SIGPIPE.
    public static func suppressSigpipe(_ descriptor: Int32) {
        var one: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Copies both directions until each side ends, then closes both
    /// descriptors. Returns only after both copy loops have finished.
    public static func bridge(client: Int32, upstream: Int32) {
        suppressSigpipe(client)
        suppressSigpipe(upstream)
        let group = DispatchGroup()
        group.enter()
        Thread.detachNewThread {
            copy(from: client, to: upstream)
            group.leave()
        }
        copy(from: upstream, to: client)
        group.wait()
        close(client)
        close(upstream)
    }

    /// One direction, blocking. EOF or a write error (EPIPE included) ends
    /// the copy; both shut down the read side of the source so the opposite
    /// direction's peer is released, and half-close the destination.
    static func copy(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        outer: while true {
            let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { write(destination, $0.baseAddress! + offset, count - offset) }
                if written < 0, errno == EINTR { continue }
                if written <= 0 {
                    // Destination is gone (EPIPE/ECONNRESET): stop reading
                    // the source too, so its writer sees the close.
                    shutdown(source, SHUT_RD)
                    break outer
                }
                offset += written
            }
        }
        shutdown(destination, SHUT_WR)
    }
}
