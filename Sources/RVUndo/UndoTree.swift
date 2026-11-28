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
    case tooDeep(levels: Int)
    case lowDisk(free: UInt64)
    case outsideRepository(String)
    case wholeRepository
    case secret(String)
    case notInRepository
    case missing(String)
    case unmergedFiles
    case unsafeRepository(String)
    case hardLinked(String)
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
        case .tooDeep(let levels):
            "Too deeply nested to keep a copy (over \(levels) levels)."
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
        case .unmergedFiles:
            "A merge is half done here (unmerged files), so rv kept no copy."
        case .unsafeRepository(let why):
            "rv will not run git in this repository (\(why)), so it kept no copy."
        case .hardLinked(let path):
            "Not copied: \(path) has other hard links (it may be another file, such as a secret)."
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

/// Bounds one walk: size, entry count, depth and a deadline, plus what
/// the walk must leave out (secrets) and whether it may clone.
struct UndoBudget {
    var maxBytes: UInt64 = UndoLimits.maxBytes
    var maxEntries: Int = UndoLimits.maxEntries
    var maxDepth: Int = UndoLimits.maxDepth
    var deadline: ContinuousClock.Instant
    /// True for a path (as shown: relative to the walk's root) rv's
    /// secret-path matcher names. Such an entry is never read or copied.
    var isSecret: (String) -> Bool = { _ in false }
    /// Clone regular files (APFS) instead of copying their bytes.
    var clones = false

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
    /// Entries the budget names as secrets, and files with other hard
    /// links, are left out, with their notes in `secrets`.
    static func scan(
        _ name: String, in parent: borrowing UndoFD, shown: String, budget: UndoBudget, secrets: inout [String]
    ) throws(UndoSkip) -> UndoTally {
        var tally = UndoTally()
        try scan(name, in: parent.raw, shown: shown, depth: 0, budget: budget, into: &tally, secrets: &secrets)
        return tally
    }

    private static func scan(
        _ name: String, in parent: Int32, shown: String, depth: Int, budget: UndoBudget,
        into tally: inout UndoTally, secrets: inout [String]
    ) throws(UndoSkip) {
        guard depth <= budget.maxDepth else { throw .tooDeep(levels: UndoLimits.maxDepth) }
        if budget.isSecret(shown) {
            secrets.append(UndoSkip.secret(shown).note)
            return
        }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw .io(shown, errno: errno) }
        tally.entries += 1
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            // A second name for a file elsewhere (a secret, say) is not
            // copied under this one.
            if info.st_nlink > 1 {
                tally.entries -= 1
                secrets.append(UndoSkip.hardLinked(shown).note)
                return
            }
            tally.files += 1
            tally.bytes += UInt64(max(0, info.st_size))
        case S_IFDIR:
            let fd = openat(parent, name, directoryFlags)
            guard fd >= 0 else { throw .io(shown, errno: errno) }
            let directory = UndoFD(fd)
            for child in try names(in: directory, shown: shown, budget: budget, already: tally.entries) {
                try scan(
                    child, in: directory.raw, shown: shown + "/" + child, depth: depth + 1, budget: budget,
                    into: &tally, secrets: &secrets)
            }
        default:
            break
        }
        try budget.check(tally)
    }

    /// Copies `name` in `source` to the same name in `destination` (a
    /// clone per regular file when the budget allows, else byte by byte),
    /// within `budget`. Secrets are left out and listed in `secrets`.
    static func copy(
        _ name: String, from source: borrowing UndoFD, to destination: borrowing UndoFD, shown: String,
        budget: UndoBudget, secrets: inout [String]
    ) throws(UndoSkip) -> UndoTally {
        var tally = UndoTally()
        try copy(
            name, from: source.raw, to: destination.raw, shown: shown, depth: 0, budget: budget, into: &tally,
            secrets: &secrets)
        return tally
    }

    private static func copy(
        _ name: String, from source: Int32, to destination: Int32, shown: String, depth: Int, budget: UndoBudget,
        into tally: inout UndoTally, secrets: inout [String]
    ) throws(UndoSkip) {
        guard depth <= budget.maxDepth else { throw .tooDeep(levels: UndoLimits.maxDepth) }
        if budget.isSecret(shown) {
            secrets.append(UndoSkip.secret(shown).note)
            return
        }
        var info = stat()
        guard fstatat(source, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw .io(shown, errno: errno) }
        let mode = mode_t(info.st_mode & 0o777)
        tally.entries += 1
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            let target = try linkTarget(name, in: source, shown: shown)
            guard symlinkat(target, destination, name) == 0 else { throw .io(shown, errno: errno) }
        case S_IFREG:
            if info.st_nlink > 1 {
                secrets.append(UndoSkip.hardLinked(shown).note)
                return
            }
            if budget.clones, UndoClone.cloneFile(name, from: source, to: destination) {
                // What was cloned must be a regular file: a link or folder
                // swapped in between the stat and the clone is undone.
                var made = stat()
                guard fstatat(destination, name, &made, AT_SYMLINK_NOFOLLOW) == 0, made.st_mode & S_IFMT == S_IFREG,
                    made.st_nlink == 1
                else {
                    UndoRemove.tree(name, in: destination, deadline: nil)
                    throw .io(shown, errno: EINVAL)
                }
                tally.files += 1
                tally.bytes += UInt64(max(0, info.st_size))
                tally.lines = nil
            } else {
                try copyFile(name, from: source, to: destination, mode: mode, shown: shown, budget: budget, into: &tally)
            }
        case S_IFDIR:
            let fd = openat(source, name, directoryFlags)
            guard fd >= 0 else { throw .io(shown, errno: errno) }
            let from = UndoFD(fd)
            guard mkdirat(destination, name, 0o700) == 0 else { throw .io(shown, errno: errno) }
            let made = openat(destination, name, directoryFlags)
            guard made >= 0 else { throw .io(shown, errno: errno) }
            let to = UndoFD(made)
            for child in try names(in: from, shown: shown, budget: budget, already: tally.entries) {
                try copy(
                    child, from: from.raw, to: to.raw, shown: shown + "/" + child, depth: depth + 1, budget: budget,
                    into: &tally, secrets: &secrets)
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
        let left = budget.maxBytes - min(budget.maxBytes, tally.bytes)
        let (copied, lines) = try pump(
            from: from.raw, to: to.raw, shown: shown, limit: left, deadline: budget.deadline, counted: tally.bytes)
        guard fchmod(to.raw, mode) == 0 else { throw .io(shown, errno: errno) }
        tally.files += 1
        tally.bytes += copied
        tally.lines = tally.lines.map { $0 + lines }
    }

    /// Copies every byte from `src` to `sink`, at most `limit` of them,
    /// before `deadline`. Returns the bytes and newlines copied.
    @discardableResult
    static func pump(
        from src: Int32, to sink: Int32, shown: String, limit: UInt64, deadline: ContinuousClock.Instant?,
        counted: UInt64 = 0
    ) throws(UndoSkip) -> (bytes: UInt64, lines: Int) {
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
            if copied > limit { throw .tooBig(bytes: counted + copied) }
            if let deadline, ContinuousClock.now >= deadline { throw .outOfTime }
        }
        return (copied, lines)
    }

    static func linkTarget(_ name: String, in directory: Int32, shown: String) throws(UndoSkip) -> String {
        let capacity = Int(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: capacity + 1)
        let count = readlinkat(directory, name, &buffer, capacity)
        guard count >= 0 else { throw .io(shown, errno: errno) }
        buffer[count] = 0
        return String(cString: buffer)
    }

    /// The entries of an open directory, without `.` and `..`. A huge
    /// directory is stopped while it is read: past the entry limit (with
    /// `already` entries counted before it) or the deadline.
    static func names(
        in directory: borrowing UndoFD, shown: String, budget: UndoBudget, already: Int = 0
    ) throws(UndoSkip) -> [String] {
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
            if names.count & 0xFF == 0 {
                if already + names.count > budget.maxEntries { throw .tooManyFiles(count: budget.maxEntries) }
                if ContinuousClock.now >= budget.deadline { throw .outOfTime }
            }
        }
        if already + names.count > budget.maxEntries { throw .tooManyFiles(count: budget.maxEntries) }
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
    /// Clones one regular file, to the same name. Directories are never
    /// cloned whole: the walk visits each entry, so the secret matcher sees
    /// every one. Fails across volumes (EXDEV), off APFS, or when the name
    /// exists: the caller copies bytes instead.
    static func cloneFile(_ name: String, from source: Int32, to destination: Int32) -> Bool {
        cloneFile(name, from: source, to: destination, as: name)
    }

    static func cloneFile(_ name: String, from source: Int32, to destination: Int32, as newName: String) -> Bool {
        #if os(macOS)
        // CLONE_NOFOLLOW: a link swapped in is cloned as the link, never
        // followed.
        return clonefileat(source, name, destination, newName, UInt32(CLONE_NOFOLLOW)) == 0
        #else
        return false
        #endif
    }
}

/// Walks to many paths under one root, sorted, reusing the directories it
/// already opened: siblings share one open parent. Every step is an
/// `openat` with `O_NOFOLLOW` from the directory above.
struct UndoDirCursor: ~Copyable {
    private var stack: [(name: String, fd: Int32)] = []
    private let root: Int32

    init(root: borrowing UndoFD) throws(UndoSkip) {
        let fd = dup(root.raw)
        guard fd >= 0 else { throw .io("", errno: errno) }
        self.root = fd
    }

    deinit {
        for entry in stack { close(entry.fd) }
        close(root)
    }

    /// The open directory for `components` (relative to the root).
    /// ENOENT reads as `.missing`; anything else (a link included) as
    /// `.outsideRepository`.
    mutating func directory(_ components: ArraySlice<String>, shown: String) throws(UndoSkip) -> Int32 {
        var common = 0
        for (index, component) in components.enumerated() {
            guard index < stack.count, stack[index].name == component else { break }
            common += 1
        }
        while stack.count > common { close(stack.removeLast().fd) }
        for component in components.dropFirst(common) {
            let parent = stack.last?.fd ?? root
            let next = openat(parent, component, UndoTree.directoryFlags)
            guard next >= 0 else { throw errno == ENOENT ? .missing(shown) : .outsideRepository(shown) }
            stack.append((component, next))
        }
        return stack.last?.fd ?? root
    }
}

/// Removes trees with descriptors, never following a link, and stops at a
/// deadline (what is left is removed by a later prune).
enum UndoRemove {
    /// Removes `name` in `parent`. False when the deadline cut it short.
    @discardableResult
    static func tree(_ name: String, in parent: Int32, deadline: ContinuousClock.Instant?, depth: Int = 0) -> Bool {
        if let deadline, ContinuousClock.now >= deadline { return false }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return true }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            _ = unlinkat(parent, name, 0)
            return true
        }
        guard depth < 256 else { return false }
        let fd = openat(parent, name, UndoTree.directoryFlags)
        guard fd >= 0 else { return false }
        let directory = UndoFD(fd)
        // Owner-only directories we made may be read-only now (a kept copy
        // of a read-only folder): open them up to empty them.
        _ = fchmod(directory.raw, 0o700)
        let budget = UndoBudget(maxEntries: .max, maxDepth: .max, deadline: deadline ?? .now + .seconds(86_400))
        guard let children = try? UndoTree.names(in: directory, shown: name, budget: budget) else { return false }
        for child in children {
            guard tree(child, in: directory.raw, deadline: deadline, depth: depth + 1) else { return false }
        }
        return unlinkat(parent, name, AT_REMOVEDIR) == 0
    }
}
