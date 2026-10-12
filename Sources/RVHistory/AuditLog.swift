#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Native writer for `audit.jsonl`: one `AuditEvent` per line, owner-only,
/// appended under an exclusive lock so concurrent writers never interleave.
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
        let fd = open(fileURL(configDirectory: configDirectory).path,
                      O_CREAT | O_APPEND | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return false }
        defer { _ = flock(fd, LOCK_UN) }
        return data.withUnsafeBytes { raw -> Bool in
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
}
