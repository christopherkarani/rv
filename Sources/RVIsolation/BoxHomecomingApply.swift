#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Runs a `BoxHomePlan` on the box before it closes. Every copy into the
/// trash runs first; the first step that fails stops the rest, so a
/// change is never undone in the box unless its box version is already
/// kept.
///
/// Every write goes through a folder descriptor: each folder on the way is
/// opened `O_DIRECTORY | O_NOFOLLOW` from the one before it (made with
/// `mkdirat` when a restore needs it), so no write passes through a link.
/// A name is replaced by writing a new file beside it (`O_EXCL |
/// O_NOFOLLOW`) and renaming it over the old one: when a write fails, the
/// old version is still there.
public enum BoxHomecomingApply {
    public enum Outcome: Equatable, Sendable {
        /// Every step ran. `trash` is the entry holding the dropped work,
        /// when anything was dropped.
        case applied(trash: BoxTrashEntry?)
        /// The step on `path` failed; the steps before it ran. Dropped work
        /// already copied is in `trash`.
        case failed(path: String, trash: BoxTrashEntry?)
    }

    /// The name a replacement is written under before it is renamed into
    /// place. One left behind (the run was stopped mid-copy) is listed in
    /// the next review and dropped.
    public static let unfinishedPrefix = ".rv-home-"

    static func isUnfinishedCopy(_ relative: String) -> Bool {
        let name = BoxPath.name(relative)
        return name.hasPrefix(unfinishedPrefix)
            && UUID(uuidString: String(name.dropFirst(unfinishedPrefix.count))) != nil
    }

    public static func apply(
        _ plan: BoxHomePlan, savedRoot: String, boxRoot: String, project: String,
        trash: BoxTrash, now: Date
    ) -> Outcome {
        var entry: BoxTrashEntry?
        for step in plan.steps {
            let ok: Bool
            switch step {
            case .trash(let relative):
                if entry == nil {
                    guard case .success(let made) = trash.makeEntry(from: project, now: now) else {
                        return .failed(path: relative, trash: nil)
                    }
                    entry = made
                }
                guard let entry else { return .failed(path: relative, trash: nil) }
                let copies = entry.path + "/" + BoxTrash.copiesFolder
                ok = copy(relative, from: boxRoot, to: copies, as: relative, folders: .private, replacing: false)
            case .placeBeside(let relative, let name):
                ok = copy(relative, from: boxRoot, to: boxRoot, as: name, folders: .existing, replacing: false)
            case .restore(let relative):
                ok = restore(relative, savedRoot: savedRoot, boxRoot: boxRoot)
            case .remove(let relative):
                ok = removeName(relative, boxRoot: boxRoot)
            case .removeFolder(let relative):
                ok = removeFolder(relative, boxRoot: boxRoot)
            }
            guard ok else { return .failed(path: step.relative, trash: entry) }
        }
        return .applied(trash: entry)
    }

    /// The saved version of `relative` in place of the box's: a file or
    /// link renamed over the box's, or a folder made (when missing) and
    /// given its saved mode. Missing folders on the way are made with
    /// their saved modes.
    static func restore(_ relative: String, savedRoot: String, boxRoot: String) -> Bool {
        guard let saved = BoxHomecomingScan.entry(at: savedRoot + "/" + relative) else { return false }
        if saved.isDirectory {
            return BoxFolder.with(relative, in: boxRoot, making: .like(savedRoot)) { folder in
                fchmod(folder, mode_t(saved.mode)) == 0
            }
        }
        return copy(relative, from: savedRoot, to: boxRoot, as: relative, folders: .like(savedRoot), replacing: true)
    }

    /// Copies the file or link at `from/relative` to `to/name`. Replacing
    /// writes a new name and renames it over `name`; otherwise `name` must
    /// not exist yet.
    static func copy(
        _ relative: String, from source: String, to destination: String, as name: String,
        folders: BoxFolder.Making, replacing: Bool
    ) -> Bool {
        BoxFolder.with(BoxPath.parent(relative), in: source, making: .existing) { from in
            BoxFolder.with(BoxPath.parent(name), in: destination, making: folders) { into in
                place(BoxPath.name(relative), from: from, as: BoxPath.name(name), into: into, replacing: replacing)
            }
        }
    }

    private static func place(_ name: String, from source: Int32, as target: String, into folder: Int32, replacing: Bool) -> Bool {
        var info = stat()
        guard fstatat(source, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        let written = replacing ? unfinishedPrefix + UUID().uuidString : target
        let made: Bool
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            guard let link = BoxFileRead.linkTarget(name, in: source) else { return false }
            made = symlinkat(link, folder, written) == 0
        case S_IFREG:
            made = copyFile(name, from: source, as: written, into: folder, mode: info.st_mode & 0o7777)
        default:
            return false
        }
        guard made else { return false }
        guard replacing else { return true }
        guard renameat(folder, written, folder, target) == 0 else {
            unlinkat(folder, written, 0)
            return false
        }
        return true
    }

    private static func copyFile(_ name: String, from source: Int32, as target: String, into folder: Int32, mode: mode_t) -> Bool {
        let input = openat(source, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { return false }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        let output = openat(folder, target, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { return false }
        var copied = true
        var buffer = [UInt8](repeating: 0, count: 65_536)
        copying: while true {
            let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                copied = false
                break
            }
            if count == 0 { break }
            var written = 0
            while written < count {
                let wrote = buffer.withUnsafeBytes { write(output, $0.baseAddress.map { $0 + written }, count - written) }
                if wrote < 0, errno == EINTR { continue }
                guard wrote > 0 else {
                    copied = false
                    break copying
                }
                written += wrote
            }
        }
        // The create mode is masked by the umask; set the one asked for.
        if fchmod(output, mode) != 0 { copied = false }
        if close(output) != 0 { copied = false }
        if copied == false { unlinkat(folder, target, 0) }
        return copied
    }

    /// Removes a file, link or special file; a name already gone is fine.
    static func removeName(_ relative: String, boxRoot: String) -> Bool {
        BoxFolder.with(BoxPath.parent(relative), in: boxRoot, making: .existing, missingIsFine: true) { folder in
            let name = BoxPath.name(relative)
            var info = stat()
            guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT }
            guard info.st_mode & S_IFMT != S_IFDIR else { return false }
            return unlinkat(folder, name, 0) == 0
        }
    }

    /// Removes an empty folder; one already gone is fine.
    static func removeFolder(_ relative: String, boxRoot: String) -> Bool {
        BoxFolder.with(BoxPath.parent(relative), in: boxRoot, making: .existing, missingIsFine: true) { folder in
            let name = BoxPath.name(relative)
            var info = stat()
            guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT }
            guard info.st_mode & S_IFMT == S_IFDIR else { return false }
            return unlinkat(folder, name, AT_REMOVEDIR) == 0
        }
    }
}

/// Paths relative to a tree root, split by hand: `NSString`'s path
/// methods trap on some short names on Linux, and normalise away what
/// rv must refuse.
enum BoxPath {
    /// Everything before the last `/`; empty at the top.
    static func parent(_ relative: String) -> String {
        guard let slash = relative.lastIndex(of: "/") else { return "" }
        return String(relative[..<slash])
    }

    /// Everything after the last `/`.
    static func name(_ relative: String) -> String {
        guard let slash = relative.lastIndex(of: "/") else { return relative }
        return String(relative[relative.index(after: slash)...])
    }

    /// The folder names on the way, or nil for `.`, `..`, an empty name or
    /// a NUL, none of which a tree walk ever yields.
    static func parts(_ relative: String) -> [String]? {
        guard relative.isEmpty == false else { return [] }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ $0.isEmpty == false && $0 != "." && $0 != ".." && $0.contains("\0") == false })
        else { return nil }
        return parts
    }
}

/// A folder under a tree root, reached one name at a time from a held
/// descriptor, never through a link.
enum BoxFolder {
    enum Making {
        /// Every folder must already be there.
        case existing
        /// Missing folders are made with the mode the same folder has
        /// under this root (`0755` when it has none).
        case like(String)
        /// Missing folders are made owner-only (the trash).
        case `private`
    }

    /// Runs `body` with a descriptor for `root/relative`; false when a
    /// name on the way is not a real folder or can't be made.
    /// `missingIsFine` makes a missing folder a success without `body`.
    static func with(
        _ relative: String, in root: String, making: Making, missingIsFine: Bool = false,
        _ body: (Int32) -> Bool
    ) -> Bool {
        guard root.contains("\0") == false, let parts = BoxPath.parts(relative) else { return false }
        var folder = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { return false }
        var source: String? = {
            if case .like(let modes) = making { return modes }
            return nil
        }()
        for part in parts {
            source = source.map { $0 + "/" + part }
            var next = openat(folder, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT {
                switch making {
                case .existing:
                    close(folder)
                    return missingIsFine
                case .like, .private:
                    next = make(part, in: folder, modeFrom: source)
                }
            }
            close(folder)
            guard next >= 0 else { return false }
            folder = next
        }
        defer { close(folder) }
        return body(folder)
    }

    /// `mkdirat`, then the folder opened and given its mode; -1 on failure.
    private static func make(_ name: String, in parent: Int32, modeFrom source: String?) -> Int32 {
        guard mkdirat(parent, name, 0o700) == 0 else { return -1 }
        let made = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard made >= 0 else { return -1 }
        let mode = source.flatMap { BoxHomecomingScan.entry(at: $0) }.flatMap { $0.isDirectory ? mode_t($0.mode) : nil }
        let wanted = source == nil ? 0o700 : (mode ?? 0o755)
        guard fchmod(made, wanted) == 0 else {
            close(made)
            return -1
        }
        return made
    }
}

extension BoxHomeStep {
    /// The path the step acts on.
    public var relative: String {
        switch self {
        case .trash(let relative), .restore(let relative), .remove(let relative),
            .removeFolder(let relative):
            relative
        case .placeBeside(_, let name):
            name
        }
    }
}
