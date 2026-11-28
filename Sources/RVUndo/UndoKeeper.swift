#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain

/// Keeps one copy before a destructive command runs. Called on the hook
/// path only for the destructive classes (`UndoPlan`), and bounded by the
/// request's budget: whatever cannot be kept in time, in size or safely
/// is skipped with a note, and the command goes on either way.
public enum UndoKeeper {
    /// Most notes one copy records; the rest are counted.
    static let maxNotes = 5
    /// The longest a keep spends pruning after its copy.
    static let pruneSlice: Duration = .milliseconds(100)

    /// Keeps the copy `request` asks for and returns its manifest (kind
    /// `skipped` with notes when nothing could be kept). Never throws:
    /// a copy is a courtesy, never a reason to block. Outside a
    /// repository nothing is written at all.
    @discardableResult
    public static func keep(
        _ request: UndoRequest, in store: UndoStore, now: Date = Date(),
        git: URL? = UndoGit.locate(), clones: Bool = true, maxBytes: UInt64 = UndoLimits.maxBytes,
        maxEntries: Int = UndoLimits.maxEntries, secrets: SecretPathCatalog = .dayOne
    ) -> UndoManifest {
        let deadline = ContinuousClock.now + request.budget
        let id = UndoStore.makeID(now: now)
        var manifest = UndoManifest(
            schema: UndoManifest.schema, id: id, createdAt: now, host: request.host, command: request.command,
            reason: request.reason, repoRoot: "", kind: .skipped, git: nil, paths: [], tally: UndoTally(), notes: [])
        guard let root = repositoryRoot(from: request.cwd) else {
            manifest.notes = [UndoSkip.notInRepository.note]
            return manifest
        }
        manifest.repoRoot = root
        let copy: UndoFD
        do throws(UndoSkip) {
            copy = try store.makeCopy(id: id)
        } catch {
            manifest.notes = [error.note]
            return manifest
        }
        let budget = UndoBudget(
            maxBytes: maxBytes, maxEntries: maxEntries, deadline: deadline,
            isSecret: { relative in secrets.firstMatch(of: root + "/" + relative) != nil }, clones: clones)
        var notes: [String] = []
        switch request.target {
        case .gitWorkingTree:
            keepGit(into: &manifest, copy: copy, store: store, root: root, git: git, budget: budget, notes: &notes)
        case .gitUntracked:
            keepUntracked(into: &manifest, copy: copy, store: store, root: root, git: git, budget: budget, notes: &notes)
        case .paths(let paths):
            keepPaths(paths, into: &manifest, copy: copy, store: store, root: root, budget: budget, notes: &notes)
        }
        manifest.notes = capped(notes)
        do {
            try store.writeManifest(manifest, in: copy)
        } catch {
            store.remove(id: id)
            dropRef(manifest, git: git)
        }
        // Pruning on the hook path is a short slice: what does not fit is
        // left for the next keep or for `rv undo`.
        let pruneDeadline = min(deadline, ContinuousClock.now + pruneSlice)
        for old in store.prune(now: now, deadline: pruneDeadline).prefix(2) {
            dropRef(old, git: git, deadline: min(deadline, ContinuousClock.now + .milliseconds(200)))
        }
        return manifest
    }

    /// The first `maxNotes` notes, then how many more there were.
    static func capped(_ notes: [String]) -> [String] {
        guard notes.count > maxNotes else { return notes }
        return Array(notes.prefix(maxNotes)) + ["And \(notes.count - maxNotes) more like these."]
    }

    // MARK: Git refs

    static func refName(_ id: String) -> String { "refs/rv/undo/\(id)" }

    private static func keepGit(
        into manifest: inout UndoManifest, copy: borrowing UndoFD, store: UndoStore, root: String, git: URL?,
        budget: UndoBudget, notes: inout [String]
    ) {
        guard let git else { notes.append(UndoSkip.gitUnavailable.note); return }
        let runner = UndoGit(executable: git, repository: root, deadline: budget.deadline)
        do throws(UndoSkip) {
            let kept = try UndoGitCopy.keep(
                runner: runner, root: root, copy: copy, copyPath: store.root.appendingPathComponent(manifest.id).path,
                budget: budget, notes: &notes)
            let ref = refName(manifest.id)
            _ = try runner.text(["update-ref", "-m", "rv undo", ref, kept.stash ?? kept.head])
            manifest.kind = .git
            manifest.git = UndoManifest.Git(ref: ref, head: kept.head, stash: kept.stash)
            if let stash = kept.stash, let counted = try? numstat(runner, from: kept.head, to: stash) {
                manifest.tally = counted
            }
        } catch {
            notes.append(error.note)
        }
    }

    /// Files and changed lines between two commits.
    static func numstat(_ runner: UndoGit, from: String, to: String) throws(UndoSkip) -> UndoTally {
        let text = try runner.text(["diff", "--numstat", "--no-textconv", "--no-ext-diff", "--no-renames", from, to])
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
    public static func dropRef(
        _ manifest: UndoManifest, git: URL? = UndoGit.locate(), deadline: ContinuousClock.Instant? = nil
    ) {
        guard let ref = manifest.git?.ref, ref == refName(manifest.id), let git, manifest.repoRoot.isEmpty == false
        else { return }
        let runner = UndoGit(executable: git, repository: manifest.repoRoot, deadline: deadline ?? .now + .seconds(1))
        _ = try? runner.run(["update-ref", "-d", ref])
    }

    // MARK: File copies

    private static func keepUntracked(
        into manifest: inout UndoManifest, copy: borrowing UndoFD, store: UndoStore, root: String, git: URL?,
        budget: UndoBudget, notes: inout [String]
    ) {
        guard let git else { notes.append(UndoSkip.gitUnavailable.note); return }
        let runner = UndoGit(executable: git, repository: root, deadline: budget.deadline)
        let listed: Data
        do throws(UndoSkip) {
            let output = try runner.run(["ls-files", "--others", "--exclude-standard", "-z"])
            guard output.status == 0 else { throw UndoSkip.gitFailed("ls-files") }
            listed = output.stdout
        } catch {
            notes.append(error.note)
            return
        }
        // Count first: a listing past the entry limit is refused before
        // anything is split, placed or opened.
        let count = listed.reduce(0) { $1 == 0 ? $0 + 1 : $0 }
        guard count <= budget.maxEntries else {
            notes.append(UndoSkip.tooManyFiles(count: budget.maxEntries).note)
            return
        }
        // git names them relative to the root; every directory on the way
        // is opened with O_NOFOLLOW later, so no realpath is needed here.
        var plan: [[String]] = []
        for raw in listed.split(separator: 0) {
            let components = String(decoding: raw, as: UTF8.self).split(separator: "/").map(String.init)
            guard components.isEmpty == false, components.allSatisfy({ $0 != "." && $0 != ".." }) else { continue }
            plan.append(components)
        }
        guard plan.isEmpty == false else {
            notes.append(UndoSkip.missing("untracked files").note)
            return
        }
        copyPlan(plan, into: &manifest, copy: copy, store: store, root: root, budget: budget, notes: &notes)
    }

    private static func keepPaths(
        _ paths: [UndoPath], into manifest: inout UndoManifest, copy: borrowing UndoFD, store: UndoStore,
        root: String, budget: UndoBudget, notes: inout [String]
    ) {
        guard paths.count <= budget.maxEntries else {
            notes.append(UndoSkip.tooManyFiles(count: budget.maxEntries).note)
            return
        }
        var plan: [[String]] = []
        for (number, path) in paths.enumerated() {
            if number & 0x3F == 0, ContinuousClock.now >= budget.deadline {
                notes.append(UndoSkip.outOfTime.note)
                return
            }
            switch place(path, in: root) {
            case .success(let relative): plan.append(relative)
            case .failure(let skip): notes.append(skip.note)
            }
        }
        copyPlan(plan, into: &manifest, copy: copy, store: store, root: root, budget: budget, notes: &notes)
    }

    /// Sorted, with every path inside another one in the set dropped (it
    /// is in that one's copy). Sorting puts a folder right before what is
    /// inside it, so one pass is enough.
    static func outermost(_ plan: [[String]]) -> [[String]] {
        let sorted = plan.sorted { $0.lexicographicallyPrecedes($1) }
        var kept: [[String]] = []
        for candidate in sorted {
            if let last = kept.last, candidate.count >= last.count, Array(candidate.prefix(last.count)) == last {
                continue
            }
            kept.append(candidate)
        }
        return kept
    }

    /// Every path is checked before anything is copied, then the whole set
    /// is measured against the limits, then copied.
    private static func copyPlan(
        _ plan: [[String]], into manifest: inout UndoManifest, copy: borrowing UndoFD, store: UndoStore,
        root: String, budget: UndoBudget, notes: inout [String]
    ) {
        let plan = outermost(plan)
        guard plan.isEmpty == false else { return }
        do throws(UndoSkip) {
            let rootFD = try UndoTree.openDirectory(root)
            var measured = UndoTally()
            var present: [[String]] = []
            var secrets: [String] = []
            var cursor = try UndoDirCursor(root: rootFD)
            for relative in plan {
                let shown = relative.joined(separator: "/")
                let name = relative[relative.count - 1]
                if budget.isSecret(shown) {
                    secrets.append(shown)
                    continue
                }
                let parent: Int32
                do throws(UndoSkip) {
                    parent = try cursor.directory(relative.dropLast(), shown: shown)
                } catch {
                    notes.append(error.note)
                    continue
                }
                var info = stat()
                guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    notes.append(UndoSkip.missing(shown).note)
                    continue
                }
                let parentFD = UndoFD(dup(parent))
                var left = budget
                left.maxEntries = budget.maxEntries - min(budget.maxEntries, measured.entries)
                left.maxBytes = budget.maxBytes - min(budget.maxBytes, measured.bytes)
                measured.add(try UndoTree.scan(name, in: parentFD, shown: shown, budget: left, secrets: &secrets))
                try budget.check(measured)
                present.append(relative)
            }
            notes += secrets.map { UndoSkip.secret($0).note }
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
            var again: [String] = []
            for relative in present {
                let shown = relative.joined(separator: "/")
                let name = relative[relative.count - 1]
                let parentFD = UndoFD(dup(try cursor.directory(relative.dropLast(), shown: shown)))
                guard UndoTree.exists(name, in: parentFD) else { continue }
                let target = try UndoTree.makeDirectories(Array(relative.dropLast()), under: data, shown: shown)
                var left = budget
                left.maxEntries = budget.maxEntries - min(budget.maxEntries, tally.entries)
                left.maxBytes = budget.maxBytes - min(budget.maxBytes, tally.bytes)
                tally.add(try UndoTree.copy(name, from: parentFD, to: target, shown: shown, budget: left, secrets: &again))
                try budget.check(tally)
                kept.append(shown)
            }
            manifest.kind = .files
            manifest.paths = kept
            manifest.tally = tally
        } catch let skip {
            // Half a copy is no copy: drop the data, keep the note.
            if let copyFD = try? UndoTree.openDirectory(store.root.appendingPathComponent(manifest.id).path) {
                UndoRemove.tree(UndoStore.dataName, in: copyFD.raw, deadline: nil)
            }
            manifest.kind = .skipped
            manifest.paths = []
            manifest.tally = UndoTally()
            notes.append(skip.note)
        }
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
