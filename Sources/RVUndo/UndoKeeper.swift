#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Keeps one copy before a destructive command runs. Called on the hook
/// path only for the destructive classes (`UndoPlan`), and bounded by the
/// request's budget: whatever cannot be kept in time, in size or safely
/// is skipped with a note, and the command goes on either way.
public enum UndoKeeper {
    /// Keeps the copy `request` asks for and returns its manifest (kind
    /// `skipped` with notes when nothing could be kept). Never throws:
    /// a copy is a courtesy, never a reason to block.
    @discardableResult
    public static func keep(
        _ request: UndoRequest, in store: UndoStore, now: Date = Date(),
        git: URL? = UndoGit.locate(), clones: Bool = true, maxBytes: UInt64 = UndoLimits.maxBytes
    ) -> UndoManifest {
        let deadline = ContinuousClock.now + request.budget
        let id = UndoStore.makeID(now: now)
        var manifest = UndoManifest(
            schema: UndoManifest.schema, id: id, createdAt: now, host: request.host, command: request.command,
            reason: request.reason, repoRoot: "", kind: .skipped, git: nil, paths: [], tally: UndoTally(), notes: [])
        let copy: UndoFD
        do throws(UndoSkip) {
            copy = try store.makeCopy(id: id)
        } catch {
            manifest.notes = [error.note]
            return manifest
        }
        guard let root = repositoryRoot(from: request.cwd) else {
            manifest.notes = [UndoSkip.notInRepository.note]
            try? store.writeManifest(manifest, in: copy)
            return manifest
        }
        manifest.repoRoot = root
        let budget = UndoBudget(maxBytes: maxBytes, deadline: deadline)
        switch request.target {
        case .gitWorkingTree:
            keepGit(into: &manifest, root: root, git: git, deadline: deadline)
        case .gitUntracked:
            keepUntracked(into: &manifest, copy: copy, store: store, root: root, git: git, budget: budget, clones: clones)
        case .paths(let paths):
            keepPaths(paths, into: &manifest, copy: copy, store: store, root: root, budget: budget, clones: clones)
        }
        do {
            try store.writeManifest(manifest, in: copy)
        } catch {
            store.remove(id: id)
            dropRef(manifest, git: git)
        }
        let pruned = store.prune(now: now)
        for old in pruned.prefix(5) { dropRef(old, git: git) }
        return manifest
    }

    // MARK: Git refs

    static func refName(_ id: String) -> String { "refs/rv/undo/\(id)" }

    private static func keepGit(into manifest: inout UndoManifest, root: String, git: URL?, deadline: ContinuousClock.Instant) {
        guard let git else { manifest.notes.append(UndoSkip.gitUnavailable.note); return }
        let runner = UndoGit(executable: git, repository: root, deadline: deadline)
        do throws(UndoSkip) {
            guard try runner.filtersConfigured() == false else { throw UndoSkip.gitRunsRepoCommands }
            let head = try runner.text(["rev-parse", "--verify", "-q", "HEAD"])
            guard head.isEmpty == false else { throw UndoSkip.gitFailed("no commits yet") }
            let stash = try runner.text(["stash", "create", "rv undo"])
            let ref = refName(manifest.id)
            _ = try runner.text(["update-ref", "-m", "rv undo", ref, stash.isEmpty ? head : stash])
            manifest.kind = .git
            manifest.git = UndoManifest.Git(ref: ref, head: head, stash: stash.isEmpty ? nil : stash)
            if stash.isEmpty == false, let counted = try? numstat(runner, from: head, to: stash) {
                manifest.tally = counted
            }
        } catch {
            manifest.notes.append(error.note)
        }
    }

    /// Files and changed lines between two commits.
    static func numstat(_ runner: UndoGit, from: String, to: String) throws(UndoSkip) -> UndoTally {
        let text = try runner.text(["diff", "--numstat", "--no-textconv", "--no-ext-diff", from, to])
        var tally = UndoTally()
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 2)
            guard fields.count == 3 else { continue }
            tally.files += 1
            tally.lines = tally.lines.map { $0 + (Int(fields[0]) ?? 0) + (Int(fields[1]) ?? 0) }
        }
        tally.entries = tally.files
        return tally
    }

    /// Deletes a copy's git ref (after pruning it).
    public static func dropRef(_ manifest: UndoManifest, git: URL? = UndoGit.locate()) {
        guard let ref = manifest.git?.ref, let git, manifest.repoRoot.isEmpty == false else { return }
        let runner = UndoGit(executable: git, repository: manifest.repoRoot, deadline: .now + .seconds(1))
        _ = try? runner.run(["update-ref", "-d", ref])
    }

    // MARK: File copies

    private static func keepUntracked(
        into manifest: inout UndoManifest, copy: borrowing UndoFD, store: UndoStore, root: String, git: URL?,
        budget: UndoBudget, clones: Bool
    ) {
        guard let git else { manifest.notes.append(UndoSkip.gitUnavailable.note); return }
        let runner = UndoGit(executable: git, repository: root, deadline: budget.deadline)
        let listed: String
        do throws(UndoSkip) {
            listed = String(decoding: try runner.run(["ls-files", "--others", "--exclude-standard", "-z"]).stdout,
                            as: UTF8.self)
        } catch {
            manifest.notes.append(error.note)
            return
        }
        let paths = listed.split(separator: "\0").map { UndoPath(path: root + "/" + $0) }
        guard paths.isEmpty == false else {
            manifest.notes.append(UndoSkip.missing("untracked files").note)
            return
        }
        keepPaths(paths, into: &manifest, copy: copy, store: store, root: root, budget: budget, clones: clones)
    }

    private static func keepPaths(
        _ paths: [UndoPath], into manifest: inout UndoManifest, copy: borrowing UndoFD, store: UndoStore,
        root: String, budget: UndoBudget, clones: Bool
    ) {
        // Every path is checked before anything is copied, then the whole
        // set is measured against the limits, then copied.
        var plan: [(relative: [String], shown: String)] = []
        for path in paths {
            switch place(path, in: root) {
            case .success(let relative): plan.append((relative, relative.joined(separator: "/")))
            case .failure(let skip): manifest.notes.append(skip.note)
            }
        }
        // A path inside another one in the set is already in its copy.
        plan = plan.filter { candidate in
            plan.contains { other in
                other.relative.count < candidate.relative.count
                    && Array(candidate.relative.prefix(other.relative.count)) == other.relative
            } == false
        }
        guard plan.isEmpty == false else { return }
        do throws(UndoSkip) {
            let rootFD = try UndoTree.openDirectory(root)
            var measured = UndoTally()
            for entry in plan {
                let parent = try openChain(entry.relative.dropLast(), under: rootFD, shown: entry.shown)
                guard UndoTree.exists(entry.relative[entry.relative.count - 1], in: parent) else {
                    manifest.notes.append(UndoSkip.missing(entry.shown).note)
                    continue
                }
                let scanned = try UndoTree.scan(
                    entry.relative[entry.relative.count - 1], in: parent, shown: entry.shown, budget: budget)
                measured.add(scanned)
                try budget.check(measured)
            }
            guard measured.entries > 0 else { return }
            if let free = UndoTree.freeBytes(at: store.root.path), free < measured.bytes + UndoLimits.freeSpaceFloor {
                throw UndoSkip.lowDisk(free: free)
            }
            guard mkdirat(copy.raw, UndoStore.dataName, 0o700) == 0 else {
                throw UndoSkip.io(UndoStore.dataName, errno: errno)
            }
            let dataFD = openat(copy.raw, UndoStore.dataName, UndoTree.directoryFlags)
            guard dataFD >= 0 else { throw UndoSkip.io(UndoStore.dataName, errno: errno) }
            let data = UndoFD(dataFD)
            var tally = UndoTally()
            var kept: [String] = []
            for entry in plan {
                let name = entry.relative[entry.relative.count - 1]
                let parent = try openChain(entry.relative.dropLast(), under: rootFD, shown: entry.shown)
                guard UndoTree.exists(name, in: parent) else { continue }
                let target = try UndoTree.makeDirectories(Array(entry.relative.dropLast()), under: data, shown: entry.shown)
                if clones, UndoClone.clone(name, from: parent, to: target) {
                    var scanned = try UndoTree.scan(name, in: parent, shown: entry.shown, budget: UndoBudget(
                        maxBytes: .max, maxEntries: .max, deadline: budget.deadline))
                    scanned.lines = nil
                    tally.add(scanned)
                } else {
                    var left = budget
                    left.maxBytes = budget.maxBytes - min(budget.maxBytes, tally.bytes)
                    let copied = try UndoTree.copy(name, from: parent, to: target, shown: entry.shown, budget: left)
                    tally.add(copied)
                }
                kept.append(entry.shown)
            }
            manifest.kind = .files
            manifest.paths = kept
            manifest.tally = tally
        } catch let skip {
            // Half a copy is no copy: drop the data, keep the note.
            try? FileManager.default.removeItem(
                at: store.root.appendingPathComponent(manifest.id).appendingPathComponent(UndoStore.dataName))
            manifest.kind = .skipped
            manifest.paths = []
            manifest.tally = UndoTally()
            manifest.notes.append(skip.note)
        }
    }

    /// Opens `components` under `root` one by one, refusing links.
    private static func openChain(_ components: ArraySlice<String>, under root: borrowing UndoFD, shown: String)
        throws(UndoSkip) -> UndoFD {
        var current = dup(root.raw)
        guard current >= 0 else { throw .io(shown, errno: errno) }
        for component in components {
            let next = openat(current, component, UndoTree.directoryFlags)
            let code = errno
            close(current)
            guard next >= 0 else { throw code == ENOENT ? .missing(shown) : .outsideRepository(shown) }
            current = next
        }
        return UndoFD(current)
    }

    /// `path` as components under the repository root, or why not. The
    /// parent directories must resolve inside the repository (a link in
    /// them that leads out is refused), the last component is taken as is.
    static func place(_ path: UndoPath, in root: String) -> Result<[String], UndoSkip> {
        if path.isSecret { return .failure(.secret(path.path)) }
        let normalized = UndoPlan.lexicallyNormalized(path.path)
        guard let realRoot = realPath(root) else { return .failure(.notInRepository) }
        let parentPath = (normalized as NSString).deletingLastPathComponent
        let name = (normalized as NSString).lastPathComponent
        guard name.isEmpty == false, name != "/", let realParent = realPath(parentPath) else {
            return .failure(.missing(path.path))
        }
        let full = realParent == "/" ? "/" + name : realParent + "/" + name
        if full == realRoot { return .failure(.wholeRepository) }
        guard full.hasPrefix(realRoot + "/") else { return .failure(.outsideRepository(path.path)) }
        let relative = String(full.dropFirst(realRoot.count + 1))
        let components = relative.split(separator: "/").map(String.init)
        guard components.isEmpty == false, components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            return .failure(.outsideRepository(path.path))
        }
        return .success(components)
    }

    public static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The nearest directory at or above `cwd` holding `.git`, resolved.
    public static func repositoryRoot(from cwd: String) -> String? {
        guard var path = realPath(cwd) else { return nil }
        while true {
            var info = stat()
            if lstat(path == "/" ? "/.git" : path + "/.git", &info) == 0 { return path }
            if path == "/" { return nil }
            path = (path as NSString).deletingLastPathComponent
        }
    }
}
