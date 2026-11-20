#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization

/// A file's on-disk identity: device, inode, size, and modification and
/// status-change times to the nanosecond. An upgrade that replaces the file
/// changes the inode; one that rewrites it in place changes mtime and ctime,
/// and ctime cannot be set back from user space.
public struct ExecutableIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modified: [Int]
    let changed: [Int]

    public init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        device = UInt64(info.st_dev)
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        #if canImport(Darwin)
        modified = [info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec]
        changed = [info.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec]
        #else
        modified = [info.st_mtim.tv_sec, info.st_mtim.tv_nsec]
        changed = [info.st_ctim.tv_sec, info.st_ctim.tv_nsec]
        #endif
    }
}

/// A file's code hash, recomputed only when its `ExecutableIdentity`
/// changes. Peer checks hash the sibling's bytes on every message; this
/// keeps that to once per install.
final class CodeHashCache: Sendable {
    private struct Entry {
        let identity: ExecutableIdentity
        let hash: Data
    }

    private let hash: @Sendable (String) -> Data?
    private let entries = Mutex<[String: Entry]>([:])

    init(hash: @escaping @Sendable (String) -> Data?) {
        self.hash = hash
    }

    func hash(ofPath path: String) -> Data? {
        guard let before = ExecutableIdentity(path: path) else { return nil }
        if let cached = entries.withLock({ $0[path] }), cached.identity == before {
            return cached.hash
        }
        guard let fresh = hash(path) else { return nil }
        // A file that changed while it was hashed is answered but not kept.
        if ExecutableIdentity(path: path) == before {
            entries.withLock { $0[path] = Entry(identity: before, hash: fresh) }
        }
        return fresh
    }
}
