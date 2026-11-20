#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization

/// The workers' compiled-model cache: a directory the supervisor creates
/// fresh at startup, passes to each worker as `--cache`, and removes when it
/// exits. Workers never read the shared `~/Library/Caches/rv-laya` cache, so
/// a compiled model planted there is not loaded when a worker (re)starts.
///
/// It lives under `<passwd home>/.config/rv/cache/judge/`, which neither the
/// isolation cage nor the MCP sandbox may write (the per-user temporary
/// directory is writable from both, so a random name there hid nothing).
/// Every step is fd-relative: each directory is opened `O_DIRECTORY` (and
/// `O_NOFOLLOW` from `rv` down) and checked through its descriptor, never
/// re-resolved by path. The run directory is `rv-judge-<128 random bits>`,
/// mode 0700. A sibling `<name>.lock`, created
/// already locked, marks it live: a sweep never touches a directory whose
/// lock another supervisor holds.
///
/// This is an interim measure, not a verified store: the verified,
/// manifest-checked store (PR #625) replaces it.
public enum JudgePoolCacheDirectory {
    static let prefix = "rv-judge-"
    static let lockSuffix = ".lock"
    static let maxDepth = 64

    struct Prepared {
        let path: String
        let name: String
        let baseFD: Int32
        let directoryFD: Int32
        let lockFD: Int32
    }

    private static let current = Mutex<Prepared?>(nil)

    /// The account home from the password database; never `$HOME`.
    public static func passwdHome() -> String? {
        guard let entry = getpwuid(geteuid()), let directory = entry.pointee.pw_dir else { return nil }
        let home = String(cString: directory)
        return home.hasPrefix("/") ? home : nil
    }

    /// Opens `<home>/.config/rv/cache/judge`, creating what is missing
    /// (0700). `.config` may be a link (dotfile managers symlink it; rv's
    /// own `~/.config` check follows it too), so it is followed; `rv`,
    /// `cache` and `judge` never are. Each level must be a
    /// directory this user owns that no one else can write; `judge` is
    /// forced to 0700 through its descriptor.
    static func openBase(home: String) -> (fd: Int32, path: String)? {
        var fd = open(home, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var path = home
        for (component, follow) in [(".config", true), ("rv", false), ("cache", false), ("judge", false)] {
            _ = mkdirat(fd, component, 0o700)
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | (follow ? 0 : O_NOFOLLOW))
            close(fd)
            guard next >= 0 else { return nil }
            fd = next
            path += "/" + component
            if component == "judge" { _ = fchmod(fd, 0o700) }
            guard ownedPrivateDirectory(fd, exactMode: component == "judge" ? 0o700 : nil) else {
                close(fd)
                return nil
            }
        }
        return (fd, path)
    }

    /// A directory owned by this user that group and others cannot write
    /// (and, with `exactMode`, exactly that mode), judged on the descriptor.
    static func ownedPrivateDirectory(_ fd: Int32, exactMode: mode_t? = nil) -> Bool {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid() else { return false }
        if let exactMode { return (info.st_mode & 0o777) == exactMode }
        return (info.st_mode & 0o022) == 0
    }

    /// Creates `rv-judge-<random>` under the base, its lock first (created
    /// locked, so no sweep can take it in between), then the directory.
    static func create(baseFD: Int32, basePath: String) -> Prepared? {
        var generator = SystemRandomNumberGenerator()
        let name = prefix + (0..<16).map { _ in
            String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
        }.joined()
        guard let lockFD = createLocked(baseFD: baseFD, name: name + lockSuffix) else { return nil }
        guard mkdirat(baseFD, name, 0o700) == 0 else {
            _ = unlinkat(baseFD, name + lockSuffix, 0)
            close(lockFD)
            return nil
        }
        let directoryFD = openat(baseFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0, fchmod(directoryFD, 0o700) == 0, ownedPrivateDirectory(directoryFD, exactMode: 0o700) else {
            if directoryFD >= 0 { close(directoryFD) }
            _ = unlinkat(baseFD, name, AT_REMOVEDIR)
            _ = unlinkat(baseFD, name + lockSuffix, 0)
            close(lockFD)
            return nil
        }
        return Prepared(path: basePath + "/" + name, name: name, baseFD: baseFD, directoryFD: directoryFD, lockFD: lockFD)
    }

    private static func createLocked(baseFD: Int32, name: String) -> Int32? {
        #if canImport(Darwin)
        let fd = openat(baseFD, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK | O_NONBLOCK, 0o600)
        return fd >= 0 ? fd : nil
        #else
        let fd = openat(baseFD, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return fd
        #endif
    }

    /// Removes leftovers of earlier supervisors (killed before they could
    /// clean up), except `keeping` and any whose lock a live supervisor
    /// holds. A link or file with the prefix is removed as itself, never
    /// followed; trees are removed fd-relative without following links.
    static func sweep(baseFD: Int32, keeping: String?) {
        let names = entries(of: baseFD)
        for name in names where name.hasPrefix(prefix) && name != keeping && name != keeping.map({ $0 + lockSuffix }) {
            if name.hasSuffix(lockSuffix) {
                if names.contains(String(name.dropLast(lockSuffix.count))) { continue }
                removeLockIfFree(baseFD: baseFD, name: name)
                continue
            }
            var info = stat()
            guard fstatat(baseFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                _ = unlinkat(baseFD, name, 0)
                continue
            }
            guard info.st_uid == geteuid() else { continue }
            let lockFD = openat(baseFD, name + lockSuffix, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            if lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
                close(lockFD)
                continue
            }
            removeTree(baseFD: baseFD, name: name)
            if lockFD >= 0 {
                _ = unlinkat(baseFD, name + lockSuffix, 0)
                close(lockFD)
            }
        }
    }

    private static func removeLockIfFree(baseFD: Int32, name: String) {
        var info = stat()
        guard fstatat(baseFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            if (info.st_mode & S_IFMT) != S_IFDIR { _ = unlinkat(baseFD, name, 0) }
            return
        }
        let fd = openat(baseFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { _ = unlinkat(baseFD, name, 0) }
        close(fd)
    }

    /// Removes the directory `name` under `baseFD` and everything in it.
    static func removeTree(baseFD: Int32, name: String) {
        let fd = openat(baseFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 {
            removeContents(of: fd, depth: 0)
            close(fd)
        }
        _ = unlinkat(baseFD, name, AT_REMOVEDIR)
    }

    /// Empties the directory open at `fd`: subdirectories are opened
    /// `O_NOFOLLOW` relative to their parent, and anything else (a link
    /// included) is unlinked as itself.
    static func removeContents(of fd: Int32, depth: Int) {
        guard depth < maxDepth else { return }
        _ = fchmod(fd, 0o700)
        for name in entries(of: fd) {
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child >= 0 {
                    removeContents(of: child, depth: depth + 1)
                    close(child)
                }
                _ = unlinkat(fd, name, AT_REMOVEDIR)
            } else {
                _ = unlinkat(fd, name, 0)
            }
        }
    }

    /// The names in the directory open at `fd` (not `.` or `..`).
    static func entries(of fd: Int32) -> [String] {
        let copy = dup(fd)
        guard copy >= 0 else { return [] }
        guard let stream = fdopendir(copy) else {
            close(copy)
            return []
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String? in
                guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return nil }
                return String(cString: base)
            }
            if let name, name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    /// Creates this supervisor's directory under the passwd home, sweeps
    /// older ones, and removes it again at exit. Nil when any check fails.
    public static func prepare(home: String) -> String? {
        guard let base = openBase(home: home) else { return nil }
        guard let prepared = create(baseFD: base.fd, basePath: base.path) else {
            close(base.fd)
            return nil
        }
        sweep(baseFD: base.fd, keeping: prepared.name)
        current.withLock { $0 = prepared }
        atexit { JudgePoolCacheDirectory.removeCurrent() }
        return prepared.path
    }

    static func removeCurrent() {
        guard let prepared = current.withLock({ value -> Prepared? in
            defer { value = nil }
            return value
        }) else { return }
        remove(prepared)
    }

    static func remove(_ prepared: Prepared) {
        removeContents(of: prepared.directoryFD, depth: 0)
        close(prepared.directoryFD)
        _ = unlinkat(prepared.baseFD, prepared.name, AT_REMOVEDIR)
        _ = unlinkat(prepared.baseFD, prepared.name + lockSuffix, 0)
        close(prepared.lockFD)
    }
}
