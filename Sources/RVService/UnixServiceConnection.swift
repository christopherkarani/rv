#if os(Linux)
import Foundation
import Glibc
import Synchronization

/// One client connection to rvd's Unix socket, for the Swift CLI on Linux:
/// the same framing as the C front door and the Python SDK (4-byte
/// big-endian length, then a JSON body).
///
/// Before any request leaves this process the peer must be the sibling
/// `rvd` running as the same user (`SO_PEERCRED` plus `/proc/<pid>/exe`),
/// exactly the check the C client makes. That matters most for owner
/// confirmation, which carries the owner's password: it must never reach a
/// process that merely bound the socket path.
///
/// Requests are serialized and reuse one connection; any I/O error closes it
/// and the next request reconnects.
public final class UnixServiceConnection: Sendable {
    public enum TransportFailure: Error {
        /// `io` carries the errno of the failed send/recv (ECONNRESET for EOF),
        /// so a socket timeout (EAGAIN) is told apart from a dropped peer.
        case noSocketPath, connect(Int32), untrustedDaemon, io(Int32), frameTooLarge
    }

    static let maxFrameBytes = 16 * 1024 * 1024
    public static let connectTimeoutMs = 1_000

    private let socketPath: String
    private let connection = Mutex<Int32?>(nil)

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Closes the connection; the next request reconnects.
    public func invalidate() {
        connection.withLock { fd in
            if let open = fd { close(open) }
            fd = nil
        }
    }

    deinit {
        invalidate()
    }

    public func roundTrip(_ body: Data, timeoutMs: Int) throws -> Data {
        try connection.withLock { slot -> Data in
            let fd: Int32
            if let open = slot {
                fd = open
            } else {
                fd = try Self.connect(path: socketPath)
                slot = fd
            }
            do {
                Self.setTimeouts(fd, milliseconds: timeoutMs)
                try Self.writeFrame(fd, body)
                return try Self.readFrame(fd)
            } catch {
                close(fd)
                slot = nil
                throw error
            }
        }
    }

    private static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard fd >= 0 else { throw TransportFailure.connect(errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            close(fd)
            throw TransportFailure.noSocketPath
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        setTimeouts(fd, milliseconds: connectTimeoutMs)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            close(fd)
            throw TransportFailure.connect(code)
        }
        guard isSiblingDaemon(fd) else {
            close(fd)
            throw TransportFailure.untrustedDaemon
        }
        return fd
    }

    /// The connected peer runs as this user and is the `rvd` next to this
    /// executable. Mirrors `rv_verify_unix_daemon` in the C front door.
    public static func isSiblingDaemon(_ fd: Int32) -> Bool {
        var credentials = PeerCredentials()
        var length = socklen_t(MemoryLayout<PeerCredentials>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length) == 0,
              length == socklen_t(MemoryLayout<PeerCredentials>.size),
              credentials.pid > 0, credentials.uid == geteuid()
        else { return false }
        guard let peer = resolvedLink("/proc/\(credentials.pid)/exe"),
              let me = resolvedLink("/proc/self/exe")
        else { return false }
        let sibling = URL(fileURLWithPath: me).deletingLastPathComponent().appendingPathComponent("rvd").path
        guard let siblingReal = realPath(sibling), let peerReal = realPath(peer) else { return false }
        return siblingReal == peerReal
    }

    /// Linux `struct ucred`, which Glibc's Swift module hides behind
    /// `_GNU_SOURCE`: pid, uid, gid, each 32 bits.
    private struct PeerCredentials {
        var pid: pid_t = 0
        var uid: uid_t = 0
        var gid: gid_t = 0
    }

    private static func resolvedLink(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(path, &buffer, Int(PATH_MAX))
        guard count > 0, count < Int(PATH_MAX) else { return nil }
        buffer[count] = 0
        return String(cString: buffer)
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func setTimeouts(_ fd: Int32, milliseconds: Int) {
        var value = timeval(tv_sec: milliseconds / 1000, tv_usec: Int((milliseconds % 1000) * 1000))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func writeFrame(_ fd: Int32, _ body: Data) throws {
        guard body.count <= maxFrameBytes else { throw TransportFailure.frameTooLarge }
        let length = UInt32(body.count).bigEndian
        var frame = Data(withUnsafeBytes(of: length) { Data($0) })
        frame.append(body)
        try frame.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                guard let base = raw.baseAddress else { throw TransportFailure.io(EINVAL) }
                let written = Glibc.send(fd, base + offset, raw.count - offset, Int32(MSG_NOSIGNAL))
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw TransportFailure.io(written < 0 ? errno : ECONNRESET) }
                offset += written
            }
        }
    }

    private static func readFrame(_ fd: Int32) throws -> Data {
        let header = try readExact(fd, 4)
        let length = header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard length > 0, Int(length) <= maxFrameBytes else { throw TransportFailure.frameTooLarge }
        return try readExact(fd, Int(length))
    }

    private static func readExact(_ fd: Int32, _ count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { raw in
            while offset < count {
                guard let base = raw.baseAddress else { throw TransportFailure.io(EINVAL) }
                let got = recv(fd, base + offset, count - offset, 0)
                if got < 0, errno == EINTR { continue }
                // EOF leaves errno untouched: report it as a reset, never a stale value.
                guard got > 0 else { throw TransportFailure.io(got < 0 ? errno : ECONNRESET) }
                offset += got
            }
        }
        return data
    }
}
#endif
