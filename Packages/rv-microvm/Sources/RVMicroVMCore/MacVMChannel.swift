import Darwin
import Foundation
import Synchronization

/// Frames over one connected stream socket. Sends are serialized, so the
/// output pump and the exit report never interleave bytes. Receiving is for
/// one reader thread.
public final class MacVMChannel: Sendable {
    public let descriptor: Int32
    private let writeLock = Mutex(())
    private let decoder = Mutex(MacVMFrameDecoder())

    public init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// False once the peer is gone.
    @discardableResult
    public func send(_ frame: MacVMFrame) -> Bool {
        let bytes = frame.encoded()
        return writeLock.withLock { _ in writeAll(descriptor, bytes) }
    }

    /// Next frame; nil at end of stream or on a read error.
    public func receive() throws(MacVMProtocolError) -> MacVMFrame? {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let pending = try decoder.withLock { decoder throws(MacVMProtocolError) in try decoder.next() }
            if let pending { return pending }
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            if count <= 0 { return nil }
            decoder.withLock { $0.append(Data(buffer[0..<count])) }
        }
    }

    /// Ends both directions; a blocked `receive` on either side returns nil.
    public func shutdown() {
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
    }
}

/// Writes every byte, retrying on EINTR. False on any other failure.
public func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return true }
        var offset = 0
        while offset < raw.count {
            let written = write(descriptor, base + offset, raw.count - offset)
            if written < 0, errno == EINTR { continue }
            if written <= 0 { return false }
            offset += written
        }
        return true
    }
}

/// Copies two connected sockets into each other until both directions end,
/// then closes both. EOF in one direction half-closes the peer.
public enum SocketBridge {
    public static func run(_ first: Int32, _ second: Int32) {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            copy(from: first, to: second)
            done.signal()
        }
        copy(from: second, to: first)
        done.wait()
        close(first)
        close(second)
    }

    private static func copy(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            if !writeAll(destination, Data(buffer[0..<count])) { break }
        }
        _ = shutdown(destination, SHUT_WR)
    }
}

/// `connect` to `127.0.0.1:port`; nil on failure.
public func connectLoopback(port: Int) -> Int32? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        close(fd)
        return nil
    }
    return fd
}
