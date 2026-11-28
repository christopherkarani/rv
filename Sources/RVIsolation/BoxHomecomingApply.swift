#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Runs a `BoxHomePlan` on the box before it closes. Every copy into the
/// trash runs first; the first step that fails stops the rest, so a
/// change is never undone in the box unless its box version is already
/// kept. Writes in the box never pass through a link: each folder on the
/// way is checked with `lstat`, and files are made with `O_EXCL |
/// O_NOFOLLOW`.
public enum BoxHomecomingApply {
    public enum Outcome: Equatable, Sendable {
        /// Every step ran. `trash` is the entry holding the dropped work,
        /// when anything was dropped.
        case applied(trash: BoxTrashEntry?)
        /// `step` failed; the steps before it ran. Dropped work already
        /// copied is in `trash`.
        case failed(path: String, trash: BoxTrashEntry?)
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
                ok = foldersAreReal(parent(relative), in: boxRoot) && keepCopy(relative, from: boxRoot, into: copies)
            case .placeBeside(let relative, let name):
                ok = foldersAreReal(parent(relative), in: boxRoot)
                    && copyEntry(from: boxRoot + "/" + relative, toRoot: boxRoot, relative: name, folderModes: boxRoot)
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

    static func parent(_ relative: String) -> String {
        (relative as NSString).deletingLastPathComponent
    }

    /// The box's file or link at `relative`, copied to `copies/relative`.
    static func keepCopy(_ relative: String, from boxRoot: String, into copies: String) -> Bool {
        let parent = (relative as NSString).deletingLastPathComponent
        if parent.isEmpty == false {
            do {
                try FileManager.default.createDirectory(
                    atPath: copies + "/" + parent, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            } catch {
                return false
            }
        }
        return copyEntry(from: boxRoot + "/" + relative, toRoot: copies, relative: relative, folderModes: nil)
    }

    /// The saved version of `relative` in place of the box's.
    static func restore(_ relative: String, savedRoot: String, boxRoot: String) -> Bool {
        guard let saved = BoxHomecomingScan.entry(at: savedRoot + "/" + relative) else { return false }
        if saved.isDirectory {
            guard makeFolders(upTo: relative, in: boxRoot, modesFrom: savedRoot) else { return false }
            return true
        }
        guard removeName(relative, boxRoot: boxRoot) else { return false }
        return copyEntry(from: savedRoot + "/" + relative, toRoot: boxRoot, relative: relative, folderModes: savedRoot)
    }

    /// Copies the file or link at `source` to `root/relative`, a name that
    /// must not exist yet. Folders on the way are made, with the modes
    /// they have under `folderModes` when given.
    static func copyEntry(from source: String, toRoot root: String, relative: String, folderModes: String?) -> Bool {
        let parent = (relative as NSString).deletingLastPathComponent
        if let folderModes {
            guard makeFolders(upTo: parent, in: root, modesFrom: folderModes) else { return false }
        } else {
            guard foldersAreReal(parent, in: root) else { return false }
        }
        guard let entry = BoxHomecomingScan.entry(at: source) else { return false }
        let destination = root + "/" + relative
        switch entry.kind {
        case .symlink(let target):
            return symlink(target, destination) == 0
        case .file:
            return copyFile(source, destination, mode: mode_t(entry.mode))
        case .directory, .special:
            return false
        }
    }

    private static func copyFile(_ source: String, _ destination: String, mode: mode_t) -> Bool {
        guard let input = BoxFileRead.openRegular(source) else { return false }
        defer { close(input) }
        let output = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard output >= 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var copied = true
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
        if copied == false { unlink(destination) }
        return copied
    }

    /// Removes a file, link or special file; a name already gone is fine.
    static func removeName(_ relative: String, boxRoot: String) -> Bool {
        let parent = (relative as NSString).deletingLastPathComponent
        guard foldersAreReal(parent, in: boxRoot) else { return false }
        let path = boxRoot + "/" + relative
        guard let entry = BoxHomecomingScan.entry(at: path) else { return errno == ENOENT }
        guard entry.isDirectory == false else { return false }
        return unlink(path) == 0
    }

    /// Removes an empty folder; one already gone is fine.
    static func removeFolder(_ relative: String, boxRoot: String) -> Bool {
        let parent = (relative as NSString).deletingLastPathComponent
        guard foldersAreReal(parent, in: boxRoot) else { return false }
        let path = boxRoot + "/" + relative
        guard let entry = BoxHomecomingScan.entry(at: path) else { return errno == ENOENT }
        guard entry.isDirectory else { return false }
        return rmdir(path) == 0
    }

    /// True when every folder of `relative` under `root` is a real folder
    /// (never a link).
    static func foldersAreReal(_ relative: String, in root: String) -> Bool {
        var path = root
        for part in relative.split(separator: "/") {
            guard part != "..", part != "." else { return false }
            path += "/" + part
            guard BoxHomecomingScan.entry(at: path)?.isDirectory == true else { return false }
        }
        return true
    }

    /// Makes each missing folder of `relative` under `root` with the mode
    /// the same folder has under `modesFrom`; an existing one must be a
    /// real folder.
    static func makeFolders(upTo relative: String, in root: String, modesFrom: String) -> Bool {
        var path = root
        var source = modesFrom
        for part in relative.split(separator: "/") {
            guard part != "..", part != "." else { return false }
            path += "/" + part
            source += "/" + part
            if let existing = BoxHomecomingScan.entry(at: path) {
                guard existing.isDirectory else { return false }
                continue
            }
            let mode = BoxHomecomingScan.entry(at: source).map { mode_t($0.mode) } ?? 0o755
            guard mkdir(path, 0o700) == 0, chmod(path, mode) == 0 else { return false }
        }
        return true
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
