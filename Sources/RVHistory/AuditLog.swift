#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import Synchronization

/// Native writer for `audit.jsonl`: one `AuditEvent` per line, owner-only.
///
/// An in-process lock for the log is taken before `flock`, so the append
/// does not rest on `flock` excluding another thread of this process (it
/// does between separate opens on a local filesystem; a network one may
/// count the lock per process). The line is `fsync`ed before success, so a
/// crash cannot drop an append that already returned true.
public enum AuditLog {
    public static func fileURL(configDirectory: URL) -> URL {
        configDirectory.appendingPathComponent(AuditLedger.Source.audit.rawValue, isDirectory: false)
    }

    /// How long an append waits for the log's locks when the caller names
    /// no bound of its own.
    public static let defaultLockTimeout: Duration = .seconds(2)

    /// Each line's `prev` is the SHA-256 of the line before it (see `AuditChain`).
    /// A torn last line is closed with a newline first, so it stays one bad line.
    ///
    /// `lockTimeout` bounds the wait for the in-process and cross-process
    /// locks (non-blocking retries): a stopped process holding the log must
    /// not hang a caller that has to answer, or every thread waiting behind
    /// it. It is bounded unless the caller says otherwise: false, with
    /// nothing written, when it passes. Nil waits as long as it takes.
    @discardableResult
    public static func append(
        _ event: AuditEvent, configDirectory: URL, lockTimeout: Duration? = defaultLockTimeout
    ) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
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
        let deadline = lockTimeout.map { ContinuousClock.now.advanced(by: $0) }
        let fd = open(url.path, O_CREAT | O_APPEND | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        var identity = stat()
        guard fstat(fd, &identity) == 0 else {
            close(fd)
            return false
        }
        let log = AppendLock.Log(
            device: UInt64(truncatingIfNeeded: identity.st_dev), inode: UInt64(truncatingIfNeeded: identity.st_ino))
        // This process's lock for the log, then the file's. The first is
        // per log: a thread waiting for a log another process holds, or
        // writing a long line, keeps no other log in this process waiting.
        var entered = false
        let written = AppendLock.withLock(log, until: deadline) {
            entered = true
            // Closed before the log's entry is given up: where `flock` is
            // counted per process, closing a descriptor that held the lock
            // drops it for every thread, the next one to take it included.
            defer { close(fd) }
            guard lock(fd, until: deadline) else { return false }
            defer { _ = flock(fd, LOCK_UN) }
            guard let tail = lastLine(fd) else { return false }
            var chained = event
            chained.prev = tail.hash
            chained.chainHead = nil
            guard let raw = try? encoder.encode(chained), let encoded = escapingHazards(raw) else { return false }
            // A line the verifier or the next append's tail scan would
            // reject is never written: refusing keeps the chain usable. The
            // scan reads at most `maximumLineBytes` back from the end, which
            // must include the newline before the last line.
            guard encoded.count < AuditChain.maximumLineBytes else { return false }
            var data = Data()
            if tail.isTorn { data.append(UInt8(ascii: "\n")) }
            data.append(encoded)
            data.append(UInt8(ascii: "\n"))
            guard writeAll(fd, data) else { return false }
            return sync(fd)
        }
        // Never entered: this descriptor held no lock.
        if entered == false { close(fd) }
        return written
    }

    /// The encoded line with every display hazard (ESC, bidi controls, tag
    /// characters, …) written as a JSON `\u` escape, so a terminal showing
    /// the file shows the text as it is. JSONEncoder escapes C0 controls
    /// already; the hazards above U+007F only ever appear inside strings,
    /// so the result is the same JSON value.
    static func escapingHazards(_ encoded: Data) -> Data? {
        guard let text = String(data: encoded, encoding: .utf8) else { return nil }
        guard text.unicodeScalars.contains(where: { $0.value >= 0x7F && DisplayedText.needsEscape($0) }) else {
            return encoded
        }
        var escaped = ""
        escaped.unicodeScalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x7F, DisplayedText.needsEscape(scalar) {
                for unit in String(scalar).utf16 { escaped += String(format: "\\u%04x", unit) }
            } else {
                escaped.unicodeScalars.append(scalar)
            }
        }
        return Data(escaped.utf8)
    }

    /// Hash of the last line (genesis for an empty file) and whether it lacks
    /// its newline. Scans back for the line start, then hashes forward.
    /// The scan is bounded: a tail longer than the verifier's line cap is
    /// already a break, and rescanning it on every append (under the
    /// log's locks) would stall its writers — appends refuse instead.
    private static func lastLine(_ fd: Int32) -> (hash: String, isTorn: Bool)? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        let size = Int64(info.st_size)
        guard size > 0 else { return (AuditChain.genesis, false) }
        guard let final = readBytes(fd, at: size - 1, count: 1)?.first else { return nil }
        let end = final == UInt8(ascii: "\n") ? size - 1 : size
        var start = end
        let chunk: Int64 = 4096
        let earliest = max(Int64(0), end - Int64(AuditChain.maximumLineBytes))
        scan: while start > earliest {
            let from = max(earliest, start - chunk)
            guard let bytes = readBytes(fd, at: from, count: Int(start - from)) else { return nil }
            if let newline = bytes.lastIndex(of: UInt8(ascii: "\n")) {
                start = from + Int64(newline) + 1
                break scan
            }
            start = from
            if start == earliest, earliest > 0 { return nil }
        }
        var digest = RVSHA256Digest()
        var offset = start
        while offset < end {
            guard let bytes = readBytes(fd, at: offset, count: Int(min(chunk * 16, end - offset))) else { return nil }
            digest.update(bytes)
            offset += Int64(bytes.count)
        }
        return (digest.digest().map { String(format: "%02x", $0) }.joined(), end == size)
    }

    private static func readBytes(_ fd: Int32, at offset: Int64, count: Int) -> [UInt8]? {
        guard count > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let n = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return pread(fd, base + filled, count - filled, off_t(offset) + off_t(filled))
            }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return nil }
            filled += n
        }
        return bytes
    }

    /// Threads in this process appending to one log, for a filesystem
    /// whose `flock` would not exclude them. One lock per log, named by the
    /// file's device and inode (so by the file, however its path was
    /// spelled).
    /// An enum, not a class: RVHistory is outside the preflight reference-type allowlist.
    private enum AppendLock {
        struct Log: Hashable {
            var device: UInt64
            var inode: UInt64
        }

        /// The logs a thread holds: waiting for the file's lock, or appending.
        private static let busy = Mutex<Set<Log>>([])

        /// `false` when `deadline` passes before `log` is free. Tries at
        /// least once, whatever the deadline.
        static func withLock(_ log: Log, until deadline: ContinuousClock.Instant?, _ body: () -> Bool) -> Bool {
            while busy.withLock({ $0.insert(log).inserted }) == false {
                if let deadline, ContinuousClock.now >= deadline { return false }
                usleep(retryMicroseconds)
            }
            defer { busy.withLock { _ = $0.remove(log) } }
            return body()
        }
    }

    private static let retryMicroseconds: useconds_t = 5_000

    /// Excludes other processes and, on a local filesystem, this one's
    /// other opens of the file. Callers already hold the log's
    /// `AppendLock`. With a deadline,
    /// non-blocking attempts until it passes.
    private static func lock(_ fd: Int32, until deadline: ContinuousClock.Instant?) -> Bool {
        if let deadline {
            while true {
                if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
                guard errno == EWOULDBLOCK || errno == EINTR else { return false }
                guard ContinuousClock.now < deadline else { return false }
                usleep(retryMicroseconds)
            }
        }
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
