#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization

/// One hardened append primitive for the append-only JSONL ledgers.
///
/// Guarantees: a `<name>.lock` sidecar taken under a process-wide mutex
/// (macOS `flock` does not exclude threads of one process) with an EINTR
/// retry; the target opens only after exclusion is held, with
/// `O_APPEND | O_CLOEXEC | O_NOFOLLOW`, so a symlink at the ledger path is
/// refused and a compaction rename cannot strand an append on a replaced
/// inode; the opened file must be regular; new files are 0600 and a created
/// parent directory is 0700; a torn trailing line is closed before the
/// record lands; `fsync` runs unless the caller opts out per call.
public enum JSONLAppendLog {
    /// Why an append did not land. Callers fail closed; the stage (and errno
    /// where one exists) is for their diagnostics.
    public enum AppendError: Error, Equatable, Sendable {
        /// The parent directory could not be created.
        case directory
        /// The `<name>.lock` sidecar could not be opened (`ELOOP` for a
        /// symlink) or `flock`ed. `errno` is captured at the failing call.
        case lock(errno: Int32)
        /// The ledger could not be opened (`ELOOP` for a symlink).
        case open(errno: Int32)
        /// The ledger path is not a regular file.
        case notRegularFile
        /// Closing a torn line or writing the record failed.
        case write(errno: Int32)
        /// `fsync` failed.
        case sync(errno: Int32)
    }

    private static let processLock = Mutex<Void>(())

    /// Appends `line` (a newline is added when absent) as one whole record.
    public static func append(_ line: Data, to url: URL, sync: Bool = true) throws(AppendError) {
        try exclusively(at: url) { locked in
            appendLocked(line, to: locked, sync: sync)
        }.get()
    }

    /// Runs `body` with cross-thread and cross-process exclusion for writers
    /// of `url`. The lock lives on a `<name>.lock` sidecar so maintenance
    /// can atomically replace the log: `body` opens the target only after
    /// exclusion is held, so no append is lost to a rename, and lock-free
    /// readers always see the old or the new file whole, never a partial
    /// rewrite. Returns nil when the lock cannot be taken. Not reentrant:
    /// `body` must not call `append` or `withExclusiveLock`.
    public static func withExclusiveLock<T: Sendable>(
        at url: URL,
        body: (URL) -> T
    ) -> T? {
        try? exclusively(at: url) { locked in .success(body(locked)) }.get()
    }

    private static func exclusively<T: Sendable>(
        at url: URL,
        body: (URL) -> Result<T, AppendError>
    ) -> Result<T, AppendError> {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return .failure(.directory)
        }
        let lockURL = url.appendingPathExtension("lock")
        var openError: Int32 = 0
        let fd = lockURL.path.withCString { path -> Int32 in
            let opened = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            if opened < 0 {
                openError = errno
            }
            return opened
        }
        guard fd >= 0 else {
            return .failure(.lock(errno: openError))
        }
        defer { close(fd) }
        return processLock.withLock { _ in
            if let failure = lock(fd) {
                return .failure(failure)
            }
            defer { _ = flock(fd, LOCK_UN) }
            return body(url)
        }
    }

    /// Runs under `exclusively`.
    private static func appendLocked(_ line: Data, to url: URL, sync: Bool) -> Result<Void, AppendError> {
        let fd = url.path.withCString { path in
            open(path, O_CREAT | O_APPEND | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard fd >= 0 else {
            return .failure(.open(errno: errno))
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return .failure(.notRegularFile)
        }
        var record = line
        if record.last != UInt8(ascii: "\n") {
            record.append(UInt8(ascii: "\n"))
        }
        guard closeTornLine(fd), writeAll(fd, record) else {
            return .failure(.write(errno: errno))
        }
        if sync, !syncFile(fd) {
            return .failure(.sync(errno: errno))
        }
        return .success(())
    }

    /// Excludes other processes. Callers already hold `processLock`. Returns
    /// nil once the lock is held, else the failure with `errno` captured
    /// immediately at the failing `flock`.
    private static func lock(_ fd: Int32) -> AppendError? {
        var code: Int32 = EINTR
        for _ in 0..<16 {
            if flock(fd, LOCK_EX) == 0 {
                return nil
            }
            code = errno
            if code != EINTR {
                break
            }
        }
        return .lock(errno: code)
    }

    /// If the log does not end on a record boundary, close that partial line.
    private static func closeTornLine(_ fd: Int32) -> Bool {
        let end = lseek(fd, 0, SEEK_END)
        if end < 0 {
            return false
        }
        if end == 0 {
            return true
        }
        var last = UInt8(0)
        var interrupts = 0
        while true {
            var readError: Int32 = 0
            let count = withUnsafeMutablePointer(to: &last) { pointer -> Int in
                let read = pread(fd, pointer, 1, end - 1)
                if read < 0 {
                    readError = errno
                }
                return read
            }
            if count == 1 {
                break
            }
            if count < 0, readError == EINTR, interrupts < 16 {
                interrupts += 1
                continue
            }
            return false
        }
        if last == UInt8(ascii: "\n") {
            return true
        }
        return writeAll(fd, Data([UInt8(ascii: "\n")]))
    }

    /// Writes `data` in full. A short write is finished or closed with a newline
    /// so the next append cannot be concatenated onto a partial JSON line.
    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var offset = 0
        var interrupts = 0
        while offset < bytes.count {
            var writeError: Int32 = 0
            let count = bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                let wrote = write(fd, base.advanced(by: offset), bytes.count - offset)
                if wrote < 0 {
                    writeError = errno
                }
                return wrote
            }
            if count > 0 {
                offset += count
                interrupts = 0
                continue
            }
            if count < 0, writeError == EINTR, interrupts < 16 {
                interrupts += 1
                continue
            }
            if offset > 0 {
                var newline = UInt8(ascii: "\n")
                _ = withUnsafePointer(to: &newline) { pointer in
                    write(fd, pointer, 1)
                }
            }
            return false
        }
        return true
    }

    private static func syncFile(_ fd: Int32) -> Bool {
        for _ in 0..<16 {
            if fsync(fd) == 0 {
                return true
            }
            if errno != EINTR {
                return false
            }
        }
        return false
    }
}
