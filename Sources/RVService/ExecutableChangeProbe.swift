#if canImport(Darwin)
import Darwin
import MachO
#elseif canImport(Glibc)
import Glibc
#endif

/// On-disk identity of one file: an atomic replace changes the inode, an
/// in-place rewrite changes size or mtime, and deletion makes it unreadable.
struct FileIdentity: Sendable, Equatable {
    var device: UInt64
    var inode: UInt64
    var size: Int64
    var modifiedSeconds: Int64
    var modifiedNanoseconds: Int64

    static func read(path: String) -> FileIdentity? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        #if canImport(Darwin)
        let modified = status.st_mtimespec
        #else
        let modified = status.st_mtim
        #endif
        return FileIdentity(
            device: UInt64(truncatingIfNeeded: status.st_dev),
            inode: UInt64(truncatingIfNeeded: status.st_ino),
            size: Int64(status.st_size),
            modifiedSeconds: Int64(modified.tv_sec),
            modifiedNanoseconds: Int64(modified.tv_nsec)
        )
    }
}

/// Detects that the running `rvd` binary was replaced on disk (upgrade or
/// rebuild). Clients pin the on-disk sibling's code identity, so a stale
/// daemon's replies are all rejected; it must exit so launchd starts the new
/// binary on the next connect. Records identity once at startup.
final class ExecutableChangeProbe: Sendable {
    let path: String
    private let original: FileIdentity
    private let identity: @Sendable (String) -> FileIdentity?

    init?(
        path: String,
        identity: @escaping @Sendable (String) -> FileIdentity? = { FileIdentity.read(path: $0) }
    ) {
        guard let original = identity(path) else { return nil }
        self.path = path
        self.original = original
        self.identity = identity
    }

    /// True when the file at `path` no longer matches the startup identity.
    func hasChanged() -> Bool {
        identity(path) != original
    }

    /// Probe over the resolved path of the running executable. Nil when the
    /// path cannot be resolved; the caller then never reports a change.
    static func running() -> ExecutableChangeProbe? {
        guard let path = resolvedExecutablePath() else { return nil }
        return ExecutableChangeProbe(path: path)
    }

    private static func resolvedExecutablePath() -> String? {
        guard let raw = rawExecutablePath() else { return nil }
        guard let resolved = realpath(raw, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    #if canImport(Darwin)
    private static func rawExecutablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
    #else
    private static func rawExecutablePath() -> String? {
        "/proc/self/exe"
    }
    #endif
}
