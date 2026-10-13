#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization

/// Native writer for `audit.jsonl`: one `AuditEvent` per line, owner-only.
///
/// An in-process lock is taken before `flock` because macOS `flock` does not
/// exclude another thread in this process. The line is `fsync`ed before
/// success, so a crash cannot drop an append that already returned true.
public enum AuditLog {
    public static func fileURL(configDirectory: URL) -> URL {
        configDirectory.appendingPathComponent(AuditLedger.Source.audit.rawValue, isDirectory: false)
    }

    @discardableResult
    public static func append(_ event: AuditEvent, configDirectory: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(event) else { return false }
        data.append(UInt8(ascii: "\n"))
        do {
            try FileManager.default.createDirectory(
                at: configDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return false
        }
        let url = fileURL(configDirectory: configDirectory)
        return AppendLock.withLock {
            let fd = open(url.path, O_CREAT | O_APPEND | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            guard lock(fd) else { return false }
            defer { _ = flock(fd, LOCK_UN) }
            guard writeAll(fd, data) else { return false }
            return sync(fd)
        }
    }

    /// Threads in this process. macOS `flock` does not exclude them.
    /// An enum, not a class: RVHistory is outside the preflight reference-type allowlist.
    private enum AppendLock {
        private static let mutex = Mutex<Void>(())

        static func withLock<T: Sendable>(_ body: () -> T) -> T {
            mutex.withLock { _ in body() }
        }
    }

    /// Excludes other processes. Callers already hold `AppendLock`.
    private static func lock(_ fd: Int32) -> Bool {
        for _ in 0..<16 {
            if flock(fd, LOCK_EX) == 0 {
                return true
            }
            if errno != EINTR {
                return false
            }
        }
        return false
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var written = 0
            while written < raw.count {
                let n = write(fd, base + written, raw.count - written)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return false }
                written += n
            }
            return true
        }
    }

    private static func sync(_ fd: Int32) -> Bool {
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
