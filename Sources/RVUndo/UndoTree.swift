#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Why a copy was not kept, or not kept whole. Each one reads as the note
/// `rv undo` shows.
public enum UndoSkip: Error, Sendable, Equatable {
    case tooBig(bytes: UInt64)
    case tooManyFiles(count: Int)
    case outOfTime
    case lowDisk(free: UInt64)
    case outsideRepository(String)
    case wholeRepository
    case secret(String)
    case notInRepository
    case missing(String)
    case gitRunsRepoCommands
    case gitUnavailable
    case gitFailed(String)
    case io(String, errno: Int32)

    /// One plain line.
    public var note: String {
        switch self {
        case .tooBig(let bytes):
            "Too big to keep a copy (\(UndoSize.words(bytes)); the limit is \(UndoSize.words(UndoLimits.maxBytes)))."
        case .tooManyFiles(let count):
            "Too many files to keep a copy (over \(count))."
        case .outOfTime:
            "Keeping a copy took too long, so rv let the command go without one."
        case .lowDisk(let free):
            "Not enough free disk to keep a copy (\(UndoSize.words(free)) free)."
        case .outsideRepository(let path):
            "Not copied: \(path) is outside the repository."
        case .wholeRepository:
            "Not copied: that is the whole repository."
        case .secret(let path):
            "Not copied: \(path) is a secrets file."
        case .notInRepository:
            "Not in a repository, so rv kept no copy."
        case .missing(let path):
            "Nothing to copy at \(path)."
        case .gitRunsRepoCommands:
            "This repository runs its own commands when git saves (filter), so rv kept no copy."
        case .gitUnavailable:
            "git was not found, so rv kept no copy."
        case .gitFailed(let what):
            "git could not keep a copy (\(what))."
        case .io(let path, let code):
            "Could not copy \(path) (\(String(cString: strerror(code))))."
        }
    }
}

/// `2.1 MB`, `512 KB`, `300 B`.
public enum UndoSize {
    public static func words(_ bytes: UInt64) -> String {
        let units: [(UInt64, String)] = [(1 << 30, "GB"), (1 << 20, "MB"), (1 << 10, "KB")]
        for (size, name) in units where bytes >= size {
            let value = Double(bytes) / Double(size)
            return value >= 10 ? "\(Int(value.rounded())) \(name)" : String(format: "%.1f \(name)", value)
        }
        return "\(bytes) B"
    }
}

/// What a walk found or copied.
public struct UndoTally: Sendable, Equatable, Codable {
    public var files: Int = 0
    public var entries: Int = 0
    public var bytes: UInt64 = 0
    /// Newlines in the regular files copied byte by byte. Nil when any
    /// file was cloned instead (nothing was read).
    public var lines: Int? = 0

    public init() {}

    mutating func add(_ other: UndoTally) {
        files += other.files
        entries += other.entries
        bytes += other.bytes
        lines = lines.flatMap { mine in other.lines.map { mine + $0 } }
    }
}

/// Bounds one walk: size, entry count, and a deadline.
struct UndoBudget {
    var maxBytes: UInt64 = UndoLimits.maxBytes
    var maxEntries: Int = UndoLimits.maxEntries
    var deadline: ContinuousClock.Instant

    func check(_ tally: UndoTally) throws(UndoSkip) {
        if tally.bytes > maxBytes { throw .tooBig(bytes: tally.bytes) }
        if tally.entries > maxEntries { throw .tooManyFiles(count: maxEntries) }
        if ContinuousClock.now >= deadline { throw .outOfTime }
    }
}

/// A file descriptor this scope owns. Closed exactly once, by `deinit`.
struct UndoFD: ~Copyable {
    let raw: Int32

    init(_ raw: Int32) { self.raw = raw }

    deinit { close(raw) }
}

/// Walks and copies trees with descriptors: every step opens relative to
/// an already-open directory with `O_NOFOLLOW`, so a symlink is copied as
/// a link and never followed, and swapping a directory for a link midway
/// fails the open instead of leading the walk somewhere else. Copies keep
/// the source's permission bits exactly (never wider), and every new file
/// is created exclusively, so nothing that exists is ever overwritten.
enum UndoTree {
    static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    /// Opens an absolute directory path whose last component is not a link.
    static func openDirectory(_ path: String) throws(UndoSkip) -> UndoFD {
        let fd = open(path, directoryFlags)
        guard fd >= 0 else { throw .io(path, errno: errno) }
        return UndoFD(fd)
    }

    /// Counts what copying `name` in `parent` would take, within `budget`.
    static func scan(_ name: String, in parent: borrowing UndoFD, shown: String, budget: UndoBudget)
        throws(UndoSkip) -> UndoTally {
        var tally = UndoTally()
        try scan(name, in: parent.raw, shown: shown, budget: budget, into: &tally)
        return tally
    }

    private static func scan(
        _ name: String, in parent: Int32, shown: String, budget: UndoBudget, into tally: inout UndoTally
    ) throws(UndoSkip) {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw .io(shown, errno: errno) }
        tally.entries += 1
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            tally.files += 1
            tally.bytes += UInt64(max(0, info.st_size))
        case S_IFDIR:
            let fd = openat(parent, name, directoryFlags)
            guard fd >= 0 else { throw .io(shown, errno: errno) }
            let directory = UndoFD(fd)
            for child in try names(in: directory, shown: shown) {
                try scan(child, in: directory.raw, shown: shown + "/" + child, budget: budget, into: &tally)
            }
        default:
            break
        }
        try budget.check(tally)
    }

    /// Copies `name` in `source` to the same name in `destination`, byte
    /// by byte, within `budget`.
    static func copy(
        _ name: String, from source: borrowing UndoFD, to destination: borrowing UndoFD, shown: String,
        budget: UndoBudget
    ) throws(UndoSkip) -> UndoTally {
        var tally = UndoTally()
        try copy(name, from: source.raw, to: destination.raw, shown: shown, budget: budget, into: &tally)
        return tally
    }

    private static func copy(
        _ name: String, from source: Int32, to destination: Int32, shown: String, budget: UndoBudget,
        into tally: inout UndoTally
    ) throws(UndoSkip) {
        var info = stat()
        guard fstatat(source, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw .io(shown, errno: errno) }
        let mode = mode_t(info.st_mode & 0o777)
        tally.entries += 1
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            let target = try linkTarget(name, in: source, shown: shown)
            guard symlinkat(target, destination, name) == 0 else { throw .io(shown, errno: errno) }
        case S_IFREG:
            try copyFile(name, from: source, to: destination, mode: mode, shown: shown, budget: budget, into: &tally)
        case S_IFDIR:
            let fd = openat(source, name, directoryFlags)
            guard fd >= 0 else { throw .io(shown, errno: errno) }
            let from = UndoFD(fd)
            guard mkdirat(destination, name, 0o700) == 0 else { throw .io(shown, errno: errno) }
            let made = openat(destination, name, directoryFlags)
            guard made >= 0 else { throw .io(shown, errno: errno) }
            let to = UndoFD(made)
            for child in try names(in: from, shown: shown) {
                try copy(child, from: from.raw, to: to.raw, shown: shown + "/" + child, budget: budget, into: &tally)
            }
            // Last, so a read-only directory still took its children.
            _ = fchmod(to.raw, mode)
        default:
            // Sockets, pipes and devices hold nothing a copy brings back.
            break
        }
        try budget.check(tally)
    }

    private static func copyFile(
        _ name: String, from source: Int32, to destination: Int32, mode: mode_t, shown: String, budget: UndoBudget,
        into tally: inout UndoTally
    ) throws(UndoSkip) {
        let input = openat(source, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard input >= 0 else { throw .io(shown, errno: errno) }
        let from = UndoFD(input)
        var info = stat()
        // The open must still be a regular file (not swapped for a FIFO).
        guard fstat(from.raw, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw .io(shown, errno: EINVAL) }
        // Created with no access at all, then given the source's bits:
        // never readable by anyone the source was not.
        let output = openat(destination, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0))
        guard output >= 0 else { throw .io(shown, errno: errno) }
        let to = UndoFD(output)
        let (src, sink) = (from.raw, to.raw)
        var lines = 0
        var copied: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(src, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw .io(shown, errno: errno)
            }
            if count == 0 { break }
            var written = 0
            while written < count {
                let step = buffer.withUnsafeBytes { bytes in
                    write(sink, bytes.baseAddress.map { $0 + written }, count - written)
                }
                if step < 0 {
                    if errno == EINTR { continue }
                    throw .io(shown, errno: errno)
                }
                written += step
            }
            for byte in buffer[0..<count] where byte == 0x0A { lines += 1 }
            copied += UInt64(count)
            if tally.bytes + copied > budget.maxBytes { throw .tooBig(bytes: tally.bytes + copied) }
            if ContinuousClock.now >= budget.deadline { throw .outOfTime }
        }
        guard fchmod(to.raw, mode) == 0 else { throw .io(shown, errno: errno) }
        tally.files += 1
        tally.bytes += copied
        tally.lines = tally.lines.map { $0 + lines }
    }

    private static func linkTarget(_ name: String, in directory: Int32, shown: String) throws(UndoSkip) -> String {
        let capacity = Int(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: capacity + 1)
        let count = readlinkat(directory, name, &buffer, capacity)
        guard count >= 0 else { throw .io(shown, errno: errno) }
        buffer[count] = 0
        return String(cString: buffer)
    }

    /// The entries of an open directory, without `.` and `..`.
    static func names(in directory: borrowing UndoFD, shown: String) throws(UndoSkip) -> [String] {
        let copy = dup(directory.raw)
        guard copy >= 0 else { throw .io(shown, errno: errno) }
        guard let stream = fdopendir(copy) else {
            let code = errno
            close(copy)
            throw .io(shown, errno: code)
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: tuple.pointee)) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names.sorted()
    }

    /// Makes every directory of `relative` under `root` (0700), and opens
    /// the last. Components must be plain names; none may be a link.
    static func makeDirectories(_ components: [String], under root: borrowing UndoFD, shown: String)
        throws(UndoSkip) -> UndoFD {
        var current = dup(root.raw)
        guard current >= 0 else { throw .io(shown, errno: errno) }
        for component in components {
            if mkdirat(current, component, 0o700) != 0, errno != EEXIST {
                let code = errno
                close(current)
                throw .io(shown, errno: code)
            }
            let next = openat(current, component, directoryFlags)
            let code = errno
            close(current)
            guard next >= 0 else { throw .io(shown, errno: code) }
            current = next
        }
        return UndoFD(current)
    }

    /// Free bytes on the filesystem holding `path`.
    static func freeBytes(at path: String) -> UInt64? {
        var info = statvfs()
        guard statvfs(path, &info) == 0 else { return nil }
        return UInt64(info.f_bavail) * UInt64(info.f_frsize)
    }

    /// True when something (a link included) is at `name` in `directory`.
    static func exists(_ name: String, in directory: borrowing UndoFD) -> Bool {
        var info = stat()
        return fstatat(directory.raw, name, &info, AT_SYMLINK_NOFOLLOW) == 0
    }
}

/// Copy-on-write clones. macOS (APFS) only; elsewhere never clones.
enum UndoClone {
    static func clone(_ name: String, from source: borrowing UndoFD, to destination: borrowing UndoFD) -> Bool {
        #if os(macOS)
        // CLONE_NOFOLLOW: a link is cloned as the link. A directory clones
        // whole, links inside it stay links. Fails across volumes (EXDEV)
        // or off APFS: the caller copies bytes instead.
        return clonefileat(source.raw, name, destination.raw, name, UInt32(CLONE_NOFOLLOW)) == 0
        #else
        return false
        #endif
    }
}
