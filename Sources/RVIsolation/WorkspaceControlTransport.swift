#if os(macOS)
import Darwin
import Foundation

enum WorkspaceSocketError: Error, Equatable {
    case socket
    case bind
    case listen
    case connect
    case disconnected
    case timedOut
    case pathTooLong
    case permission
}

/// Same-account authorization. This is not organization or user RBAC.
enum WorkspacePeerPolicy {
    static func decide(peerUID: uid_t, ownerUID: uid_t) -> WorkspaceControlCode? {
        peerUID == ownerUID ? nil : .unauthorizedClient
    }
}

enum WorkspaceSocketMode {
    static func isOwnerDirectory(_ path: String) -> Bool {
        mode(path, expected: 0o700, kind: S_IFDIR)
    }

    static func isOwnerSocket(_ path: String) -> Bool {
        mode(path, expected: 0o600, kind: S_IFSOCK)
    }

    private static func mode(_ path: String, expected: Int, kind: mode_t) -> Bool {
        var status = stat()
        guard path.withCString({ lstat($0, &status) == 0 }) else { return false }
        guard (status.st_mode & S_IFMT) == kind else { return false }
        guard status.st_uid == getuid() else { return false }
        return Int(status.st_mode & 0o777) == expected
    }
}

struct WorkspaceSocketIdentity: Equatable {
    var device: UInt64
    var inode: UInt64
}

enum WorkspaceControlSocket {
    static let maxPathBytes = 103

    static func fits(_ path: String) -> Bool {
        path.utf8.count <= maxPathBytes && path.contains("\0") == false
    }

    static func identity(_ path: String) -> WorkspaceSocketIdentity? {
        var status = stat()
        guard path.withCString({ lstat($0, &status) == 0 }) else { return nil }
        guard (status.st_mode & S_IFMT) == S_IFSOCK else { return nil }
        return WorkspaceSocketIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }

    static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        return uid
    }

    static func openListener(path: String) -> Result<(Int32, WorkspaceSocketIdentity), WorkspaceSocketError> {
        guard fits(path) else { return .failure(.pathTooLong) }
        let parent = (path as NSString).deletingLastPathComponent
        guard prepareDirectory(parent) else { return .failure(.permission) }
        if FileManager.default.fileExists(atPath: path) {
            guard unlinkOwnedSocket(path) else { return .failure(.permission) }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.socket) }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) >= 0 else {
            close(fd)
            return .failure(.socket)
        }
        var addr = sockaddr_un()
        do {
            addr = try unixAddress(path)
        } catch {
            close(fd)
            return .failure(.pathTooLong)
        }
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            return .failure(.bind)
        }
        // fchmod on a Unix-domain socket returns EINVAL here. chmod the path.
        if fchmod(fd, 0o600) != 0, path.withCString({ chmod($0, 0o600) }) != 0 {
            close(fd)
            unlink(path)
            return .failure(.listen)
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            unlink(path)
            return .failure(.listen)
        }
        ignorePipe(fd)
        var named = stat()
        // macOS fstat on a bound Unix socket does not report the filesystem
        // inode clients see with lstat. Publish the lstat identity.
        guard path.withCString({ lstat($0, &named) == 0 }),
            (named.st_mode & S_IFMT) == S_IFSOCK,
            (named.st_mode & 0o777) == 0o600,
            named.st_uid == getuid()
        else {
            close(fd)
            unlink(path)
            return .failure(.permission)
        }
        return .success((
            fd,
            WorkspaceSocketIdentity(device: UInt64(named.st_dev), inode: UInt64(named.st_ino))
        ))
    }

    static func connect(path: String, timeout: TimeInterval) -> Result<Int32, WorkspaceSocketError> {
        guard fits(path) else { return .failure(.pathTooLong) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.socket) }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) >= 0 else {
            close(fd)
            return .failure(.socket)
        }
        guard setNonblocking(fd, true) else {
            close(fd)
            return .failure(.connect)
        }
        var addr: sockaddr_un
        do {
            addr = try unixAddress(path)
        } catch {
            close(fd)
            return .failure(.pathTooLong)
        }
        let started = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if started != 0 && errno != EINPROGRESS {
            close(fd)
            return .failure(.connect)
        }
        if started != 0 {
            var pollState = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let milliseconds = Int32(max(1, min(timeout * 1_000, Double(Int32.max))))
            let waited = poll(&pollState, 1, milliseconds)
            if waited == 0 {
                close(fd)
                return .failure(.timedOut)
            }
            if waited < 0 {
                close(fd)
                return .failure(.connect)
            }
            var error = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            let checked = withUnsafeMutablePointer(to: &error) { pointer in
                getsockopt(fd, SOL_SOCKET, SO_ERROR, pointer, &length)
            }
            guard checked == 0, error == 0 else {
                close(fd)
                return .failure(.connect)
            }
        }
        guard setNonblocking(fd, false) else {
            close(fd)
            return .failure(.connect)
        }
        ignorePipe(fd)
        return .success(fd)
    }

    static func writeFrame(fd: Int32, body: Data) -> Bool {
        guard body.count <= WorkspaceControlLimits.maxBodyBytes, body.isEmpty == false else {
            return false
        }
        var header = UInt32(body.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(body)
        return writeAll(fd: fd, data: frame)
    }

    static func readFrame(fd: Int32, timeout: TimeInterval?) -> Result<Data, WorkspaceSocketError> {
        let header: Data
        switch readExact(fd: fd, count: 4, timeout: timeout) {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            header = data
        }
        switch WorkspaceControlCodec.headerCount(header) {
        case .failure:
            return .failure(.disconnected)
        case .success(let count):
            return readExact(fd: fd, count: count, timeout: timeout)
        }
    }

    static func unlinkOwnedSocket(_ path: String) -> Bool {
        var status = stat()
        let exists = path.withCString { lstat($0, &status) == 0 }
        if exists == false { return true }
        let kind = status.st_mode & S_IFMT
        guard kind == S_IFSOCK || kind == S_IFLNK else { return false }
        return path.withCString { unlink($0) == 0 }
    }

    static func prepareDirectory(_ path: String) -> Bool {
        do {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return false
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: path
        )
        return WorkspaceSocketMode.isOwnerDirectory(path)
    }

    private static func unixAddress(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count + 1 <= maxPath else { throw WorkspaceSocketError.pathTooLong }
        path.withCString { source in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                let dest = UnsafeMutableRawPointer(sunPath).assumingMemoryBound(to: CChar.self)
                _ = strncpy(dest, source, maxPath - 1)
            }
        }
        return addr
    }

    private static func ignorePipe(_ fd: Int32) {
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func setNonblocking(_ fd: Int32, _ enabled: Bool) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return false }
        let next = enabled ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK)
        return fcntl(fd, F_SETFL, next) >= 0
    }

    private static func writeAll(fd: Int32, data: Data) -> Bool {
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
            }
            if count > 0 {
                offset += count
                continue
            }
            if count < 0, errno == EINTR { continue }
            return false
        }
        return true
    }

    private static func readExact(
        fd: Int32,
        count: Int,
        timeout: TimeInterval?
    ) -> Result<Data, WorkspaceSocketError> {
        var data = Data(count: count)
        var offset = 0
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while offset < count {
            if let deadline {
                let remain = deadline.timeIntervalSinceNow
                if remain <= 0 { return .failure(.timedOut) }
                var state = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let milliseconds = Int32(max(1, min(remain * 1_000, Double(Int32.max))))
                let waited = poll(&state, 1, milliseconds)
                if waited == 0 { return .failure(.timedOut) }
                if waited < 0 {
                    if errno == EINTR { continue }
                    return .failure(.disconnected)
                }
            }
            let n = data.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: offset), count - offset)
            }
            if n > 0 {
                offset += n
                continue
            }
            if n < 0, errno == EINTR { continue }
            return .failure(.disconnected)
        }
        return .success(data)
    }
}
#endif
