#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// What a restore did. Nothing that exists is ever overwritten.
public enum UndoRestoreOutcome: Sendable, Equatable {
    /// The kept HEAD on a new branch, unsaved changes applied on top.
    case branch(String)
    /// Files put back where nothing is now; `leftInPlace` already existed
    /// and were left alone (their copy stays in the store).
    case files(restored: Int, leftInPlace: [String])
}

/// Why a restore did not run. Each reads as one line.
public enum UndoRestoreRefusal: Error, Sendable, Equatable {
    case otherRepository(String)
    case unsavedChanges
    case nothingKept
    case gitUnavailable
    case gitFailed(String)
    case io(String)
    /// The manifest is not in the shape rv writes (any process running as
    /// the person can edit it): nothing from it is used.
    case notOurs

    public var note: String {
        switch self {
        case .otherRepository(let root): "This copy is of \(root). Run rv undo there."
        case .unsavedChanges: "You have unsaved changes here. Commit or stash them first; rv never overwrites them."
        case .nothingKept: "rv kept nothing for this one."
        case .gitUnavailable: "git was not found."
        case .gitFailed(let what): "git could not restore it (\(what)). Nothing was overwritten."
        case .io(let what): "Could not restore \(what). Nothing was overwritten."
        case .notOurs: "This copy's record was changed after rv wrote it, so rv will not restore it."
        }
    }
}

/// Puts a kept copy back, without overwriting anything.
public enum UndoRestore {
    /// Restores `manifest` into `repository` (the person's current repo,
    /// resolved). It must be the repository the copy came from.
    public static func restore(
        _ manifest: UndoManifest, from store: UndoStore, into repository: String, now: Date = Date(),
        timeZone: TimeZone = .current, git: URL? = UndoGit.locate()
    ) throws(UndoRestoreRefusal) -> UndoRestoreOutcome {
        guard isWellFormed(manifest) else { throw .notOurs }
        guard UndoKeeper.realPath(repository) == UndoKeeper.realPath(manifest.repoRoot) else {
            throw .otherRepository(manifest.repoRoot)
        }
        switch manifest.kind {
        case .skipped:
            throw .nothingKept
        case .git:
            guard let kept = manifest.git else { throw .nothingKept }
            guard let git else { throw .gitUnavailable }
            return .branch(try restoreGit(
                kept, objects: store.objectsDirectory(of: manifest.id).path, root: manifest.repoRoot, git: git,
                now: now, timeZone: timeZone))
        case .files:
            return try restoreFiles(manifest, from: store)
        }
    }

    /// True when every field a restore acts on is in the shape rv writes:
    /// the id, full commit ids (never a
    /// revision expression or an option), and plain relative paths, none
    /// inside `.git` (where a restored file would be a hook or config).
    static func isWellFormed(_ manifest: UndoManifest) -> Bool {
        guard manifest.schema == UndoManifest.schema, UndoStore.isID(manifest.id),
            manifest.repoRoot.hasPrefix("/")
        else { return false }
        if let git = manifest.git {
            guard UndoGit.isObjectID(git.head), git.stash.map(UndoGit.isObjectID) ?? true
            else { return false }
        }
        return manifest.paths.allSatisfy(isPlainRelativePath)
    }

    static func isPlainRelativePath(_ path: String) -> Bool {
        guard path.isEmpty == false, path.hasPrefix("/") == false else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count <= UndoLimits.maxDepth else { return false }
        return components.allSatisfy { component in
            component.isEmpty == false && component != "." && component != ".."
                && foldedGitName(component) != ".git"
        }
    }

    /// `.GIT` is `.git` on a case-insensitive disk.
    private static func foldedGitName(_ component: Substring) -> String {
        component.lowercased()
    }

    /// `rv/restore-1403`, from when the copy was kept.
    static func branchName(for date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HHmm"
        return "rv/restore-" + formatter.string(from: date)
    }

    private static func restoreGit(
        _ kept: UndoManifest.Git, objects: String, root: String, git: URL, now: Date, timeZone: TimeZone
    ) throws(UndoRestoreRefusal) -> String {
        // The person's own git (their global config, so LFS and smudge
        // filters work), hooks still off, pinned to this repository.
        let runner = UndoGit(executable: git, repository: root, deadline: .now + .seconds(60), mode: .person)
        func text(_ arguments: [String]) throws(UndoRestoreRefusal) -> String {
            do {
                return try runner.text(arguments)
            } catch {
                throw .gitFailed(arguments.first ?? "git")
            }
        }
        guard (try? runner.text(["cat-file", "-e", kept.head + "^{commit}"])) != nil else {
            throw .gitFailed("the kept commit is gone")
        }
        guard try text(["status", "--porcelain", "--untracked-files=no"]).isEmpty else { throw .unsavedChanges }
        if let stash = kept.stash {
            // The objects rv made are in its store: they go into the
            // repository first (only ones it lacks), so what is restored
            // stays whole after the copy is pruned.
            try copyObjects(from: objects, into: root)
            guard (try? runner.text(["rev-list", "--objects", "--missing=error", stash, "--not", kept.head])) != nil
            else { throw .gitFailed("the kept commit is gone") }
        }
        let base = branchName(for: now, timeZone: timeZone)
        var branch = base
        var suffix = 2
        while (try? runner.text(["rev-parse", "--verify", "-q", "refs/heads/" + branch])) != nil {
            branch = "\(base)-\(suffix)"
            suffix += 1
        }
        _ = try text(["switch", "-q", "-c", branch, kept.head])
        if let stash = kept.stash {
            if (try? runner.text(["stash", "apply", "-q", "--index", stash])) == nil {
                _ = try text(["stash", "apply", "-q", stash])
            }
        }
        return branch
    }

    /// Copies the loose objects of a git copy (`xx/<rest>`, both hex) into
    /// the repository's objects, skipping any it already has, without
    /// following a link on either side. Objects are read-only, as git
    /// makes them.
    static func copyObjects(from objects: String, into root: String) throws(UndoRestoreRefusal) {
        if let problem = UndoRepository.foldersProblem(root: root, deadline: .now + .seconds(10)) {
            throw .gitFailed(problem)
        }
        do throws(UndoSkip) {
            let from = try UndoTree.openDirectory(objects)
            let to = try UndoTree.openDirectory(root + "/.git/objects")
            let budget = UndoBudget(maxEntries: 1_000_000, deadline: .now + .seconds(60))
            for folder in try UndoTree.names(in: from, shown: objects, budget: budget) where isHex(folder, count: 2) {
                let source = try UndoTree.openChild(folder, in: from, shown: folder)
                if mkdirat(to.raw, folder, 0o777) != 0, errno != EEXIST { throw .io(folder, errno: errno) }
                let target = try UndoTree.openChild(folder, in: to, shown: folder)
                for name in try UndoTree.names(in: source, shown: folder, budget: budget)
                where isHex(name, count: 38) || isHex(name, count: 62) {
                    try copyObject(name, from: source, to: target, shown: folder + "/" + name, budget: budget)
                }
            }
        } catch {
            throw .io(error.note)
        }
    }

    private static func copyObject(
        _ name: String, from source: borrowing UndoFD, to target: borrowing UndoFD, shown: String,
        budget: UndoBudget
    ) throws(UndoSkip) {
        let input = openat(source.raw, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard input >= 0 else { throw .io(shown, errno: errno) }
        let reader = UndoFD(input)
        var info = stat()
        guard fstat(reader.raw, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw .io(shown, errno: EPERM) }
        let output = openat(target.raw, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o444))
        if output < 0, errno == EEXIST { return }
        guard output >= 0 else { throw .io(shown, errno: errno) }
        let writer = UndoFD(output)
        do throws(UndoSkip) {
            _ = try UndoTree.pump(
                from: reader.raw, to: writer.raw, shown: shown, limit: UndoLimits.maxBytes * 2,
                deadline: budget.deadline)
        } catch {
            _ = unlinkat(target.raw, name, 0)
            throw error
        }
    }

    private static func isHex(_ text: String, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    private static func restoreFiles(_ manifest: UndoManifest, from store: UndoStore)
        throws(UndoRestoreRefusal) -> UndoRestoreOutcome {
        do throws(UndoSkip) {
            let data = try UndoTree.openDirectory(store.dataDirectory(of: manifest).path)
            let root = try UndoTree.openDirectory(manifest.repoRoot)
            var restored = 0
            var leftInPlace: [String] = []
            // Nothing inside a `.git` folder is ever put back, at any depth:
            // the store is the person's to write, so anyone running as them
            // could have planted a hook there.
            let budget = UndoBudget(
                maxBytes: .max, maxEntries: .max, deadline: .now + .seconds(600),
                isSecret: { shown in isPlainRelativePath(shown) == false }, clones: true)
            for shown in manifest.paths {
                let components = shown.split(separator: "/").map(String.init)
                guard isPlainRelativePath(shown), let name = components.last else { continue }
                let from = try openChain(components.dropLast(), under: data, create: false, shown: shown)
                let to = try openChain(components.dropLast(), under: root, create: true, shown: shown)
                if UndoTree.exists(name, in: to) {
                    leftInPlace.append(shown)
                    continue
                }
                var secrets: [String] = []
                restored += try UndoTree.copy(name, from: from, to: to, shown: shown, budget: budget, secrets: &secrets).files
            }
            return .files(restored: restored, leftInPlace: leftInPlace)
        } catch {
            throw .io(error.note)
        }
    }

    /// Opens (or, in the repository, makes with the usual permissions)
    /// each directory in turn, never through a link.
    private static func openChain(
        _ components: ArraySlice<String>, under root: borrowing UndoFD, create: Bool, shown: String
    ) throws(UndoSkip) -> UndoFD {
        var current = dup(root.raw)
        guard current >= 0 else { throw .io(shown, errno: errno) }
        for component in components {
            if create, mkdirat(current, component, 0o777) != 0, errno != EEXIST {
                let code = errno
                close(current)
                throw .io(shown, errno: code)
            }
            let next = openat(current, component, UndoTree.directoryFlags)
            let code = errno
            close(current)
            guard next >= 0 else { throw .io(shown, errno: code) }
            current = next
        }
        return UndoFD(current)
    }
}
