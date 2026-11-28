#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Which repositories rvd may run git in. A repository is the agent's to
/// shape, so its `.git` can be set up to send git elsewhere: a `gitdir:`
/// file or a link (git would follow it, or walk up to a parent repo), an
/// object or ref folder that is a link out of the repository (git would
/// write there), alternates (git would read objects from anywhere), or a
/// partial clone (git would fetch, running the remote's transport). rvd
/// refuses all of them before git runs.
///
/// These are point-in-time checks; the guards that hold even if the
/// repository changes right after them are in `UndoGit` (no transport,
/// no lazy fetch, no hooks, git pinned to `<root>/.git`).
public enum UndoRepository {
    /// Extensions a repository may have and still be kept: the object
    /// format (SHA-256 repositories).
    static let allowedExtensions: Set<String> = ["extensions.objectformat"]

    /// The nearest directory at or above `cwd` holding `.git`, resolved,
    /// when that `.git` is a plain directory (not a link, a `gitdir:`
    /// file, or anything else). Nil otherwise: rv never walks past a
    /// `.git` it cannot use to a parent repository.
    public static func root(from cwd: String) -> String? {
        guard var path = UndoKeeper.realPath(cwd) else { return nil }
        while true {
            var info = stat()
            if lstat(path == "/" ? "/.git" : path + "/.git", &info) == 0 {
                return info.st_mode & S_IFMT == S_IFDIR ? path : nil
            }
            if path == "/" { return nil }
            path = (path as NSString).deletingLastPathComponent
        }
    }

    /// Why `root` is not a repository rvd may run git in, or nil when it
    /// is. Runs `git config` and `rev-parse` (hardened) after the folder
    /// checks.
    static func problem(root: String, runner: UndoGit) -> String? {
        if let reason = foldersProblem(root: root) { return reason }
        let gitDir = root + "/.git"
        let config: UndoGit.Output
        do {
            config = try runner.run(["config", "--list", "--name-only"])
        } catch {
            return "git could not read its config"
        }
        guard config.status == 0 else { return "git could not read its config" }
        let names = String(decoding: config.stdout, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.lowercased() }
        if let reason = configProblem(names) { return reason }
        guard let absolute = try? runner.text(["rev-parse", "--absolute-git-dir"]),
            let real = UndoKeeper.realPath(gitDir), UndoKeeper.realPath(absolute) == real
        else { return "git does not use this folder's .git" }
        return nil
    }

    /// The folder checks alone (no git run): `.git`, its object and ref
    /// folders are plain folders, and nothing borrows objects.
    static func foldersProblem(root: String) -> String? {
        let gitDir = root + "/.git"
        guard kind(gitDir) == .directory else { return ".git is not a plain folder" }
        for folder in ["objects", "refs"] where kind(gitDir + "/" + folder) != .directory {
            return ".git/\(folder) is not a plain folder"
        }
        for folder in ["objects/info", "refs/rv", "refs/rv/undo"] {
            switch kind(gitDir + "/" + folder) {
            case .missing, .directory: continue
            default: return ".git/\(folder) is not a plain folder"
            }
        }
        if kind(gitDir + "/objects/info/alternates") != .missing { return "it borrows objects (alternates)" }
        if let linked = linkedObjectFolder(gitDir + "/objects") { return ".git/objects/\(linked) is a link" }
        return nil
    }

    /// A partial clone, a promisor remote, or an extension rv does not
    /// know. Pure.
    static func configProblem(_ names: [String]) -> String? {
        for name in names {
            if name == "extensions.partialclone" { return "it is a partial clone" }
            if name.hasPrefix("remote."), name.hasSuffix(".promisor") { return "it is a partial clone" }
            if name.hasPrefix("extensions."), allowedExtensions.contains(name) == false {
                return "it uses \(name)"
            }
        }
        return nil
    }

    enum Kind: Equatable {
        case missing
        case directory
        case other
    }

    static func kind(_ path: String) -> Kind {
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT ? .missing : .other }
        return info.st_mode & S_IFMT == S_IFDIR ? .directory : .other
    }

    /// The first `objects/xx` fan-out entry that is not a plain folder.
    private static func linkedObjectFolder(_ objects: String) -> String? {
        guard let fd = try? UndoTree.openDirectory(objects) else { return "." }
        let budget = UndoBudget(maxEntries: 100_000, deadline: .now + .seconds(1))
        guard let names = try? UndoTree.names(in: fd, shown: objects, budget: budget) else { return "." }
        for name in names where name.utf8.count == 2 || name == "pack" || name == "info" {
            var info = stat()
            guard fstatat(fd.raw, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                return name
            }
        }
        return nil
    }
}
