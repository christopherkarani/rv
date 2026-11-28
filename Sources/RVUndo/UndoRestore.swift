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
            return .branch(try restoreGit(kept, root: manifest.repoRoot, git: git, now: now, timeZone: timeZone))
        case .files:
            return try restoreFiles(manifest, from: store)
        }
    }

    /// True when every field a restore acts on is in the shape rv writes:
    /// the id, a ref that is this copy's own, full commit ids (never a
    /// revision expression or an option), and plain relative paths, none
    /// inside `.git` (where a restored file would be a hook or config).
    static func isWellFormed(_ manifest: UndoManifest) -> Bool {
        guard manifest.schema == UndoManifest.schema, UndoStore.isID(manifest.id),
            manifest.repoRoot.hasPrefix("/")
        else { return false }
        if let git = manifest.git {
            guard git.ref == UndoKeeper.refName(manifest.id), UndoGit.isObjectID(git.head),
                git.stash.map(UndoGit.isObjectID) ?? true
            else { return false }
        }
        return manifest.paths.allSatisfy(isPlainRelativePath)
    }

    static func isPlainRelativePath(_ path: String) -> Bool {
        guard path.isEmpty == false, path.hasPrefix("/") == false else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
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
        _ kept: UndoManifest.Git, root: String, git: URL, now: Date, timeZone: TimeZone
    ) throws(UndoRestoreRefusal) -> String {
        let runner = UndoGit(executable: git, repository: root, deadline: .now + .seconds(60))
        func text(_ arguments: [String]) throws(UndoRestoreRefusal) -> String {
            do {
                return try runner.text(arguments)
            } catch {
                throw .gitFailed(arguments.first ?? "git")
            }
        }
        guard (try? runner.text(["cat-file", "-e", kept.head + "^{commit}"])) != nil,
            kept.stash.map({ (try? runner.text(["cat-file", "-e", $0 + "^{commit}"])) != nil }) ?? true
        else {
            throw .gitFailed("the kept commit is gone")
        }
        guard try text(["status", "--porcelain", "--untracked-files=no"]).isEmpty else { throw .unsavedChanges }
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
