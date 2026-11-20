#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization

/// One hardened append primitive for the append-only JSONL ledgers.
///
/// Guarantees: a `<name>.lock` sidecar `flock`ed with an EINTR retry, under
/// an in-process lock for that sidecar file (for filesystems that count
/// `flock` per process, where threads would not exclude each other, and so
/// this process's writers queue on one deadline; one log's writers never
/// wait for another's); the target opens only after exclusion is held, with
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

    /// A lock sidecar by file identity, so every path to one log shares
    /// one in-process lock.
    private struct Sidecar: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    /// The sidecars a writer in this process holds. Held only to insert or
    /// remove one, never across a wait.
    private static let heldSidecars = Mutex<Set<Sidecar>>([])

    /// Takes `sidecar`'s in-process lock, retrying until `deadline` (nil:
    /// until it is free). A deadline already passed is one attempt.
    private static func hold(_ sidecar: Sidecar, until deadline: ContinuousClock.Instant?) -> Bool {
        while true {
            if heldSidecars.withLock({ $0.insert(sidecar).inserted }) {
                return true
            }
            if let deadline, ContinuousClock.now >= deadline {
                return false
            }
            usleep(1_000)
        }
    }

    private static func release(_ sidecar: Sidecar) {
        heldSidecars.withLock { _ = $0.remove(sidecar) }
    }

    /// Opens (creating) `url`'s `<name>.lock` sidecar and reads its identity.
    private static func openSidecar(_ url: URL) -> Result<(fd: Int32, sidecar: Sidecar), AppendError> {
        // O_NONBLOCK: a FIFO or device planted at the sidecar fails here
        // instead of hanging the writer; it must be a regular file.
        let fd = url.appendingPathExtension("lock").path.withCString { path in
            open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        }
        guard fd >= 0 else {
            return .failure(.lock(errno: errno))
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            close(fd)
            return .failure(.lock(errno: code))
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            return .failure(.lock(errno: EINVAL))
        }
        return .success((fd, Sidecar(
            device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(truncatingIfNeeded: info.st_ino))))
    }

    /// Runs `body` holding `url`'s in-process writer lock, as a contending
    /// writer would (tests). The sidecar's directory must exist.
    static func holdingProcessLock(at url: URL, _ body: () -> Void) {
        guard case .success(let opened) = openSidecar(url) else { return }
        _ = hold(opened.sidecar, until: nil)
        defer {
            close(opened.fd)
            release(opened.sidecar)
        }
        body()
    }

    /// Appends `line` (a newline is added when absent) as one whole record.
    /// `lockTimeout` bounds the whole wait, for this process's writers and
    /// another process's lock alike (non-blocking attempts against one
    /// deadline, then `.lock(errno: EWOULDBLOCK)`); nil waits.
    public static func append(
        _ line: Data,
        to url: URL,
        sync: Bool = true,
        lockTimeout: Duration? = nil
    ) throws(AppendError) {
        try exclusively(at: url, lockTimeout: lockTimeout) { locked in
            appendLocked(line, to: locked, sync: sync)
        }.get()
    }

    /// Runs `body` with cross-thread and cross-process exclusion for writers
    /// of `url`. The lock lives on a `<name>.lock` sidecar so maintenance
    /// can atomically replace the log: `body` opens the target only after
    /// exclusion is held, so no append is lost to a rename, and lock-free
    /// readers always see the old or the new file whole, never a partial
    /// rewrite. Returns nil when the lock cannot be taken. Not reentrant:
    /// `body` must not call `append` or `withExclusiveLock`. `lockTimeout`
    /// bounds the wait for another process's lock, as for `append`.
    public static func withExclusiveLock<T: Sendable>(
        at url: URL,
        lockTimeout: Duration? = nil,
        body: (URL) -> T
    ) -> T? {
        try? exclusively(at: url, lockTimeout: lockTimeout) { locked in .success(body(locked)) }.get()
    }

    private static func exclusively<T: Sendable>(
        at url: URL,
        lockTimeout: Duration? = nil,
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
        let fd: Int32
        let sidecar: Sidecar
        switch openSidecar(url) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let opened):
            (fd, sidecar) = opened
        }
        func locked(until deadline: ContinuousClock.Instant?) -> Result<T, AppendError> {
            if let failure = lock(fd, until: deadline) {
                return .failure(failure)
            }
            defer { _ = flock(fd, LOCK_UN) }
            return body(url)
        }
        // One deadline for both locks, so contention in this process does
        // not stack a fresh timeout per waiting writer. A zero timeout is
        // one non-blocking attempt at each.
        let deadline = lockTimeout.map { ContinuousClock.now.advanced(by: $0) }
        guard hold(sidecar, until: deadline) else {
            // Never entered: this descriptor took no lock. Closing it is
            // harmless where each open has its own `flock` (local Darwin
            // and Linux filesystems). Where locks are counted per process
            // (some network filesystems) it can drop the holder's lock, as
            // in AuditLog: a waiter only gets here by timing out.
            close(fd)
            return .failure(.lock(errno: EWOULDBLOCK))
        }
        defer { release(sidecar) }
        // Closed before the entry is given up: where `flock` is counted
        // per process, closing a descriptor that held the lock drops it for
        // every thread, the next one to take it included.
        defer { close(fd) }
        return locked(until: deadline)
    }

    /// Runs under `exclusively`.
    private static func appendLocked(_ line: Data, to url: URL, sync: Bool) -> Result<Void, AppendError> {
        let fd = url.path.withCString { path in
            open(path, O_CREAT | O_APPEND | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
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

    /// Excludes other processes. Callers already hold the path's in-process lock. Returns
    /// nil once the lock is held, else the failure with `errno` captured
    /// immediately at the failing `flock`.
    private static func lock(_ fd: Int32, until deadline: ContinuousClock.Instant?) -> AppendError? {
        if let deadline {
            while true {
                if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                    return nil
                }
                let code = errno
                guard code == EWOULDBLOCK || code == EINTR else {
                    return .lock(errno: code)
                }
                guard ContinuousClock.now < deadline else {
                    return .lock(errno: EWOULDBLOCK)
                }
                usleep(1_000)
            }
        }
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
