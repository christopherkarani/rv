#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Staged-bytes write policy: one `write(2)` attempt, or the
/// `EINTR`-retrying full-write loop.
public enum OwnerOnlyFileWritePolicy: Sendable {
    /// One `write(2)` attempt; a short write or interruption fails the
    /// staging. The sink reconciles on its next mutation.
    case once
    /// Loop until every byte lands, retrying `EINTR`.
    case all
}

/// Shared atomic-write core for owner-only JSON stores.
///
/// Every caller stages through the same discipline: a uniquely named temp
/// file (`O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC`, mode `0600`) under an
/// already-open directory fd, the staged-bytes write, an `fchmod` 0600
/// reassertion, and a `renameat` commit with unlink-on-failure. The temp
/// name carries a caller tag (`sink`, `migrate`) plus pid plus a random
/// hex nonce, so concurrent writers never share a name.
///
/// Parameterized by write policy and retry count so each call site keeps
/// its deliberate divergence: the integration sink stages single-attempt
/// (`.once`, one attempt, no `EEXIST` retry, no dev/ino recheck — the sink
/// reconciles on its next mutation), while the migration rewrite loops
/// (`.all`, eight attempts with `EEXIST` retry) behind a dev/ino identity
/// recheck. The policy/attempts arguments ARE the divergence record; no
/// caller may silently change its pair.
public enum OwnerOnlyFileWrite {
    /// One staged temp file: the open fd plus its directory-relative name.
    /// The caller owns the fd and closes it after committing.
    public struct StagedFile: Sendable {
        public let fd: Int32
        public let name: String

        public init(fd: Int32, name: String) {
            self.fd = fd
            self.name = name
        }
    }

    /// Stages `bytes` in a uniquely named 0600 temp file under `dirFd`.
    /// `attempts` counts total open attempts; an `EEXIST` collision retries
    /// while attempts remain, any other failure returns nil after cleanup.
    /// A failed bytes-write or chmod cleans up and returns nil without
    /// retrying: only name collisions retry, never IO failures.
    public static func stage(
        bytes: Data,
        fileName: String,
        tag: String,
        inDirectory dirFd: Int32,
        policy: OwnerOnlyFileWritePolicy,
        attempts: Int
    ) -> StagedFile? {
        for _ in 0..<max(attempts, 1) {
            let nonce = String(UInt64.random(in: 0...UInt64.max), radix: 16)
            let name = ".\(fileName).\(tag)-\(getpid())-\(nonce)"
            let fd = name.withCString {
                openat(dirFd, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            }
            if fd < 0 {
                if errno == EEXIST { continue }
                return nil
            }
            guard writeBytes(bytes, to: fd, policy: policy), fchmod(fd, 0o600) == 0 else {
                _ = name.withCString { unlinkat(dirFd, $0, 0) }
                close(fd)
                return nil
            }
            return StagedFile(fd: fd, name: name)
        }
        return nil
    }

    /// Commits a staged file over `fileName` via `renameat`. On failure the
    /// temp is unlinked and false returns; the live file is untouched.
    /// Never closes `staged.fd`: the caller owns it.
    public static func commit(
        staged: StagedFile,
        as fileName: String,
        inDirectory dirFd: Int32
    ) -> Bool {
        let renamed = staged.name.withCString { temp in
            fileName.withCString { live in
                renameat(dirFd, temp, dirFd, live)
            }
        }
        guard renamed == 0 else {
            _ = staged.name.withCString { unlinkat(dirFd, $0, 0) }
            return false
        }
        return true
    }

    /// Re-checks that the live file is still the regular owner-owned file
    /// the caller just read (`expectedDevice`/`expectedInode` from its
    /// fstat). A concurrent swap — or a symlink planted where the file
    /// belongs — fails closed. Migration call sites only; the sink never
    /// rechecks (its next mutation reconciles instead).
    public static func verifyIdentity(
        fileName: String,
        inDirectory dirFd: Int32,
        expectedDevice: UInt64,
        expectedInode: UInt64
    ) -> Bool {
        let current = fileName.withCString {
            openat(dirFd, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard current >= 0 else { return false }
        defer { close(current) }
        var status = stat()
        guard fstat(current, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFREG,
            status.st_uid == getuid(),
            UInt64(status.st_dev) == expectedDevice,
            UInt64(status.st_ino) == expectedInode
        else {
            return false
        }
        return true
    }

    /// Writes `bytes` to `fd` under `policy`.
    public static func writeBytes(
        _ bytes: Data,
        to fd: Int32,
        policy: OwnerOnlyFileWritePolicy
    ) -> Bool {
        switch policy {
        case .once:
            return writeOnce(bytes, to: fd)
        case .all:
            return writeAll(bytes: bytes, to: fd)
        }
    }

    /// One write attempt. Empty input succeeds trivially (zero bytes to
    /// write); otherwise the bridged base pointer is always addressable,
    /// so there is no nil-base branch to cover.
    private static func writeOnce(_ bytes: Data, to fd: Int32) -> Bool {
        if bytes.isEmpty { return true }
        return write(fd, (bytes as NSData).bytes, bytes.count) == bytes.count
    }

    private static func writeAll(bytes: Data, to fd: Int32) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 { offset += written; continue }
            if written == 0 { return false }
            if errno == EINTR { continue }
            return false
        }
        return true
    }
}
