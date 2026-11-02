#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// A binary a secret's `binaries` list allows, as the file was when the
/// lease was made. A different file at the path, or the same one changed,
/// no longer matches. The change time is kept rather than the modification
/// time: `utimes` can restore an mtime, but nothing in user space sets ctime.
struct GatewayBinaryPin: Sendable, Equatable {
    var path: String
    var device: UInt64
    var inode: UInt64
    var size: Int64
    var changedSeconds: Int64
    var changedNanoseconds: Int64

    /// The regular file `configured` resolves to now, symlinks followed:
    /// the kernel reports a process's executable by its real path.
    static func pin(_ configured: String) -> GatewayBinaryPin? {
        guard let resolved = realpath(configured, nil) else { return nil }
        defer { free(resolved) }
        return identity(String(cString: resolved))
    }

    func matches(_ executable: String) -> Bool {
        executable == path && Self.identity(path) == self
    }

    private static func identity(_ path: String) -> GatewayBinaryPin? {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        #if canImport(Darwin)
        let changed = info.st_ctimespec
        #else
        let changed = info.st_ctim
        #endif
        return GatewayBinaryPin(
            path: path, device: UInt64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
            changedSeconds: Int64(changed.tv_sec), changedNanoseconds: Int64(changed.tv_nsec))
    }
}

enum GatewayBinaryVerdict: Equatable, Sendable {
    case allowed
    case mismatch
    /// A process in the chain could not be read, or changed while it was.
    case unverifiable
}

#if os(macOS)
enum GatewayBinaryScan {
    /// OpenShell walks the same depth.
    static let maximumAncestors = 64

    /// Allowed when `holder`, or an ancestor up to and including `leader`,
    /// runs a pinned binary. Every process walked is re-checked by start
    /// time afterwards, so a pid that exited and was reused mid-walk fails.
    static func verdict(holder: pid_t, leader: pid_t, pins: [GatewayBinaryPin]) -> GatewayBinaryVerdict {
        var walked: [(pid: pid_t, seconds: UInt64, microseconds: UInt64)] = []
        var allowed = false
        var pid = holder
        for _ in 0..<maximumAncestors {
            guard case .found(let info) = ProcessGroupRecovery.lookup(pid), let path = executablePath(pid) else {
                return .unverifiable
            }
            walked.append((pid, info.pbi_start_tvsec, info.pbi_start_tvusec))
            if pins.contains(where: { $0.matches(path) }) {
                allowed = true
                break
            }
            if pid == leader || info.pbi_ppid <= 1 { break }
            pid = pid_t(info.pbi_ppid)
        }
        for process in walked {
            guard case .found(let info) = ProcessGroupRecovery.lookup(process.pid),
                info.pbi_start_tvsec == process.seconds, info.pbi_start_tvusec == process.microseconds
            else { return .unverifiable }
        }
        return allowed ? .allowed : .mismatch
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
#endif
