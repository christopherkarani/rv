#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import Synchronization

/// In-process occupancy for one canonical project path.
///
/// `flock` does not exclude a second thread in this process. This table does.
/// It dies with the process, so a recycled PID cannot keep a claim alive.
enum WorkspaceOwnerRegistry {
    enum Claim: Equatable, Sendable {
        case opening
        case owner(UUID)
    }

    private static let claims = Mutex<[String: Claim]>([:])

    static func current(_ path: String) -> Claim? {
        claims.withLock { $0[path] }
    }

    static func beginOpening(_ path: String) -> Bool {
        claims.withLock { map in
            guard map[path] == nil else { return false }
            map[path] = .opening
            return true
        }
    }

    static func adopt(_ path: String, owner: UUID) -> Bool {
        claims.withLock { map in
            guard map[path] == .opening else { return false }
            map[path] = .owner(owner)
            return true
        }
    }

    static func cancelOpening(_ path: String) {
        claims.withLock { map in
            if map[path] == .opening {
                map[path] = nil
            }
        }
    }

    static func remove(path: String, owner: UUID) {
        claims.withLock { map in
            if case .owner(let id) = map[path], id == owner {
                map[path] = nil
            }
        }
    }
}

/// Exclusive advisory lock whose kernel lifetime is the owning process.
///
/// The file stores a token and its device/inode are recorded in the lifecycle
/// log. A later process may reclaim the workspace only when it can lock this
/// same inode and the token still matches. PID reuse does not keep the lock.
final class WorkspaceOwnerLock: @unchecked Sendable {
    enum Acquisition: Sendable {
        case acquired(WorkspaceOwnerLock)
        case busy
        case missing
        case mismatched
        case unavailable
    }

    private var fd: Int32
    let path: String
    private(set) var token: UUID?
    let device: UInt64
    let inode: UInt64

    private init(fd: Int32, path: String, token: UUID?, device: UInt64, inode: UInt64) {
        self.fd = fd
        self.path = path
        self.token = token
        self.device = device
        self.inode = inode
    }

    deinit {
        release()
    }

    static func gatePath(directory: URL, canonicalProject: String) -> String {
        let digest = SHA256.hash(data: Data(canonicalProject.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory
            .appendingPathComponent("workspace-gates", isDirectory: true)
            .appendingPathComponent(name)
            .appendingPathExtension("lock")
            .path
    }

    /// `create` is false for recovery probes so a missing lock is not replaced.
    static func acquire(path: String, create: Bool) -> Acquisition {
        let parent = (path as NSString).deletingLastPathComponent
        if create {
            do {
                try FileManager.default.createDirectory(
                    atPath: parent,
                    withIntermediateDirectories: true
                )
            } catch {
                return .unavailable
            }
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: parent
            )
        }
        var flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW
        if create {
            flags |= O_CREAT
        }
        let fd = path.withCString { open($0, flags, 0o600) }
        if fd < 0 {
            if errno == ENOENT { return .missing }
            if errno == ELOOP || errno == ENOTDIR { return .mismatched }
            return .unavailable
        }
        if fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 {
            close(fd)
            return .unavailable
        }
        let operation = LOCK_EX | LOCK_NB
        if flock(fd, operation) != 0 {
            let error = errno
            close(fd)
            if error == EWOULDBLOCK || error == EAGAIN { return .busy }
            return .unavailable
        }
        if fchmod(fd, 0o600) != 0 {
            _ = flock(fd, LOCK_UN)
            close(fd)
            return .unavailable
        }
        var status = stat()
        if fstat(fd, &status) != 0 {
            _ = flock(fd, LOCK_UN)
            close(fd)
            return .unavailable
        }
        let kind = status.st_mode & S_IFMT
        if kind != S_IFREG {
            _ = flock(fd, LOCK_UN)
            close(fd)
            return .mismatched
        }
        let token = readToken(fd)
        return .acquired(
            WorkspaceOwnerLock(
                fd: fd,
                path: path,
                token: token,
                device: UInt64(status.st_dev),
                inode: UInt64(status.st_ino)
            )
        )
    }

    func matches(device: UInt64, inode: UInt64, token: UUID) -> Bool {
        self.device == device && self.inode == inode && self.token == token
    }

    func replaceToken(_ newToken: UUID) -> Bool {
        guard fd >= 0 else { return false }
        let text = Data((newToken.uuidString + "\n").utf8)
        if lseek(fd, 0, SEEK_SET) < 0 { return false }
        if ftruncate(fd, 0) != 0 { return false }
        let bytes = [UInt8](text)
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return write(fd, base.advanced(by: offset), bytes.count - offset)
            }
            if count > 0 {
                offset += count
                continue
            }
            if count < 0, errno == EINTR { continue }
            return false
        }
        if fsync(fd) != 0 { return false }
        guard fsyncParent() else { return false }
        token = newToken
        return true
    }

    func release() {
        if fd >= 0 {
            _ = flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }

    private func fsyncParent() -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        let directory = parent.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard directory >= 0 else { return false }
        defer { close(directory) }
        return fsync(directory) == 0
    }

    private static func readToken(_ fd: Int32) -> UUID? {
        if lseek(fd, 0, SEEK_SET) < 0 { return nil }
        var buffer = [UInt8](repeating: 0, count: 80)
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return read(fd, base, raw.count)
        }
        guard count > 0 else { return nil }
        let text = String(decoding: buffer.prefix(count), as: UTF8.self)
        guard let line = text.split(separator: "\n", omittingEmptySubsequences: false).first else {
            return nil
        }
        return UUID(uuidString: String(line))
    }
}
#endif
