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

    /// Why a configured path cannot be pinned. Each reason names what to list instead.
    enum Unpinnable: Error, Equatable, Sendable {
        case notAFile
        /// The file starts with `#!`: the kernel reports its interpreter as
        /// the running binary, so no process ever runs as this path.
        case script
        /// An Xcode developer-tool shim: it execs the real tool in the same
        /// process, so no process ever runs as this path. `real` is the tool it forwards to.
        case developerShim(real: String)

        var reason: String {
            switch self {
            case .notAFile: "is not a file on this host"
            case .script:
                "is a script, and the kernel reports its interpreter as the running binary; list the interpreter or "
                    + "the program that runs it instead"
            case .developerShim(let real):
                "is an Xcode developer-tool shim that runs \(real) in the same process, so nothing ever runs as it; "
                    + "list \(real) instead (`xcrun --find` prints it)"
            }
        }
    }

    /// The regular file `configured` resolves to now, symlinks followed:
    /// the kernel reports a process's executable by its real path. Scripts
    /// and developer shims are refused: nothing would ever match them.
    static func pin(
        _ configured: String, shimDirectory: String = "/usr/bin",
        developerDirectories: [String] = Self.developerDirectories()
    ) -> Result<GatewayBinaryPin, Unpinnable> {
        guard let resolved = realpath(configured, nil) else { return .failure(.notAFile) }
        defer { free(resolved) }
        let path = String(cString: resolved)
        guard let pinned = identity(path) else { return .failure(.notAFile) }
        if startsWithShebang(path) { return .failure(.script) }
        let directory = shimDirectory.hasSuffix("/") ? shimDirectory : shimDirectory + "/"
        if path.hasPrefix(directory), !path.dropFirst(directory.count).contains("/") {
            let name = String(path.dropFirst(directory.count))
            for developer in developerDirectories {
                let real = developer + "/usr/bin/" + name
                if access(real, X_OK) == 0 { return .failure(.developerShim(real: real)) }
            }
        }
        return .success(pinned)
    }

    /// The developer directories `xcrun` can forward to: `DEVELOPER_DIR`, what
    /// `xcode-select` points at, and the Command Line Tools. Read without
    /// spawning anything.
    static func developerDirectories() -> [String] {
        var directories: [String] = []
        if let selected = getenv("DEVELOPER_DIR") { directories.append(String(cString: selected)) }
        if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
            directories.append(link)
        }
        directories.append("/Library/Developer/CommandLineTools")
        return directories
    }

    private static func startsWithShebang(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 2)).map { $0 == Data("#!".utf8) } ?? false
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
/// A process holding the connection, with the start time read before its
/// descriptors were, so a pid reused in between is caught.
struct GatewayHolder: Equatable, Sendable {
    var pid: pid_t
    var startSeconds: UInt64
    var startMicroseconds: UInt64
}

enum GatewayBinaryScan {
    /// OpenShell walks the same depth.
    static let maximumAncestors = 64

    /// One process of a walk, as first read.
    struct Link: Equatable, Sendable {
        var pid: pid_t
        var parent: UInt32
        var seconds: UInt64
        var microseconds: UInt64
    }

    /// Allowed when `holder`, or an ancestor up to and including `leader`,
    /// runs a pinned binary. `unverifiable` when the holder is not the
    /// process whose descriptors were read, when the walk ends before the
    /// leader or launchd, or when any process walked changed meanwhile.
    static func verdict(
        holder: GatewayHolder, leader: pid_t, pins: [GatewayBinaryPin], limit: Int = maximumAncestors
    ) -> GatewayBinaryVerdict {
        var walked: [Link] = []
        var allowed = false
        var ended = false
        var pid = holder.pid
        for _ in 0..<limit {
            guard case .found(let info) = ProcessGroupRecovery.lookup(pid), let path = executablePath(pid) else {
                return .unverifiable
            }
            let link = Link(pid: pid, parent: info.pbi_ppid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
            if walked.isEmpty, link.seconds != holder.startSeconds || link.microseconds != holder.startMicroseconds {
                return .unverifiable
            }
            walked.append(link)
            if pins.contains(where: { $0.matches(path) }) {
                allowed = true
                break
            }
            if pid == leader || info.pbi_ppid <= 1 {
                ended = true
                break
            }
            pid = pid_t(info.pbi_ppid)
        }
        guard allowed || ended, ordered(walked) else { return .unverifiable }
        for process in walked {
            guard case .found(let info) = ProcessGroupRecovery.lookup(process.pid),
                info.pbi_start_tvsec == process.seconds, info.pbi_start_tvusec == process.microseconds,
                info.pbi_ppid == process.parent
            else { return .unverifiable }
        }
        return allowed ? .allowed : .mismatch
    }

    /// A parent cannot have started after its child: one that did is a pid
    /// reused after the child's real parent exited.
    static func ordered(_ walked: [Link]) -> Bool {
        zip(walked, walked.dropFirst()).allSatisfy { child, parent in
            (parent.seconds, parent.microseconds) <= (child.seconds, child.microseconds)
        }
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
#endif
