#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// One entry of the index, as `git ls-files -s --debug -z` prints it.
struct UndoIndexEntry: Sendable, Equatable {
    var mode: String
    var object: String
    var stage: Int
    var path: String
    var mtimeSeconds: UInt32
    var mtimeNanoseconds: UInt32
    var size: UInt32
    var flags: UInt32

    /// `skip-worktree` and `intent-to-add`: the file is not expected in
    /// the working tree as the index has it, so a copy leaves it alone.
    static let leaveAlone: UInt32 = (1 << 30) | (1 << 29)

    var isFile: Bool { mode == "100644" || mode == "100755" }
    var isLink: Bool { mode == "120000" }
}

/// Reads `ls-files -s --debug -z`. Pure.
enum UndoIndexListing {
    /// The entries, or nil when the text is not in the shape git prints.
    /// Each entry is `<mode> <object> <stage>\t<path>\0` and then five
    /// `  key: value` lines (ctime, mtime, dev/ino, uid/gid, size/flags).
    static func parse(_ data: Data, deadline: ContinuousClock.Instant? = nil) -> [UndoIndexEntry]? {
        let bytes = [UInt8](data)
        var entries: [UndoIndexEntry] = []
        var index = 0
        while index < bytes.count {
            if entries.count & 0x3FF == 0, let deadline, ContinuousClock.now >= deadline { return nil }
            guard let end = bytes[index...].firstIndex(of: 0) else { return nil }
            let header = String(decoding: bytes[index..<end], as: UTF8.self)
            index = end + 1
            var lines: [String] = []
            while lines.count < 5 {
                guard let newline = bytes[index...].firstIndex(of: 0x0A) else { return nil }
                lines.append(String(decoding: bytes[index..<newline], as: UTF8.self))
                index = newline + 1
            }
            guard let entry = entry(header: header, debug: lines) else { return nil }
            entries.append(entry)
        }
        return entries
    }

    private static func entry(header: String, debug: [String]) -> UndoIndexEntry? {
        guard let tab = header.firstIndex(of: "\t") else { return nil }
        let fields = header[..<tab].split(separator: " ")
        let path = String(header[header.index(after: tab)...])
        guard fields.count == 3, let stage = Int(fields[2]), path.isEmpty == false else { return nil }
        var mtime: (UInt32, UInt32)?
        var size: UInt32?
        var flags: UInt32?
        for line in debug {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("mtime: ") {
                let parts = trimmed.dropFirst("mtime: ".count).split(separator: ":")
                if parts.count == 2, let seconds = UInt32(parts[0]), let nanoseconds = UInt32(parts[1]) {
                    mtime = (seconds, nanoseconds)
                }
            } else if trimmed.hasPrefix("size: ") {
                for pair in trimmed.split(separator: "\t") {
                    let kv = pair.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard kv.count == 2 else { continue }
                    if kv[0] == "size" { size = UInt32(kv[1]) }
                    if kv[0] == "flags" { flags = UInt32(kv[1], radix: 16) }
                }
            }
        }
        guard let mtime, let size, let flags else { return nil }
        return UndoIndexEntry(
            mode: String(fields[0]), object: String(fields[1]), stage: stage, path: path,
            mtimeSeconds: mtime.0, mtimeNanoseconds: mtime.1, size: size, flags: flags)
    }
}

/// What the working tree holds at an index entry's path.
enum UndoWorktreeFile: Equatable {
    case missing
    case file(size: UInt64, mtimeSeconds: Int, mtimeNanoseconds: Int, executable: Bool)
    case link(size: UInt64, mtimeSeconds: Int, mtimeNanoseconds: Int)
    case other

    /// True when the entry may differ from what the index records, so its
    /// bytes must be hashed. Like git, an unchanged size and mtime means
    /// unchanged, unless the file changed in the same second the index was
    /// written ("racy"), which is hashed to be sure.
    func mayDiffer(from entry: UndoIndexEntry, indexWritten: (seconds: Int, nanoseconds: Int)) -> Bool {
        let size: UInt64
        let seconds: Int
        let nanoseconds: Int
        switch self {
        case .missing, .other:
            return true
        case .file(let s, let sec, let ns, let executable):
            guard entry.isFile, executable == (entry.mode == "100755") else { return true }
            (size, seconds, nanoseconds) = (s, sec, ns)
        case .link(let s, let sec, let ns):
            guard entry.isLink else { return true }
            (size, seconds, nanoseconds) = (s, sec, ns)
        }
        if UInt32(truncatingIfNeeded: size) != entry.size { return true }
        if UInt32(truncatingIfNeeded: seconds) != entry.mtimeSeconds { return true }
        // An index written without nanoseconds compares seconds only.
        if entry.mtimeNanoseconds != 0, UInt32(truncatingIfNeeded: nanoseconds) != entry.mtimeNanoseconds { return true }
        if seconds > indexWritten.seconds { return true }
        return seconds == indexWritten.seconds && nanoseconds >= indexWritten.nanoseconds
    }
}

/// Keeps unsaved tracked work as a stash-shaped commit, without letting
/// git read a single working-tree file. That is where a repository's
/// clean filters (commands the repository chooses) would run, in rvd,
/// outside any box. Instead:
/// 1. the repository's index is copied into the copy's own folder, and
///    git works only on that copy (`GIT_INDEX_FILE`), so the person's
///    index and its lock are never touched;
/// 2. rv compares each tracked file with the index itself (size, mtime,
///    mode), opening every directory with `O_NOFOLLOW`;
/// 3. the bytes of the files that may differ are copied into the copy's
///    folder and given to `git hash-object --no-filters`;
/// 4. `update-index --index-info`, `write-tree` and `commit-tree` build
///    the index commit and the work commit (`stash apply --index` reads
///    the pair).
/// Secrets (rv's matcher) are never read: they keep their committed
/// version, with a note.
enum UndoGitCopy {
    static let stageName = "stage"
    static let maxIndexBytes = 64 * 1024 * 1024

    struct Kept: Equatable {
        var head: String
        /// Nil when nothing was unsaved: the tree and the index match HEAD.
        var stash: String?
        /// Files kept (changed or deleted) and the bytes handed to git.
        var tally = UndoTally()
    }

    static func keep(
        runner: UndoGit, root: String, copy: borrowing UndoFD, copyPath: String, budget: UndoBudget,
        notes: inout [String]
    ) throws(UndoSkip) -> Kept {
        let head = try runner.text(["rev-parse", "--verify", "-q", "HEAD^{commit}"])
        guard UndoGit.isObjectID(head) else { throw .gitFailed("no commits yet") }
        let headTree = try runner.text(["rev-parse", "--verify", "-q", "HEAD^{tree}"])
        var indexPath = try runner.text(["rev-parse", "--git-path", "index"])
        if indexPath.hasPrefix("/") == false { indexPath = root + "/" + indexPath }

        guard mkdirat(copy.raw, stageName, 0o700) == 0 else { throw .io(stageName, errno: errno) }
        // Bounded too: what is left is swept by the next prune.
        defer { UndoRemove.tree(stageName, in: copy.raw, deadline: budget.deadline) }
        let stageFD = openat(copy.raw, stageName, UndoTree.directoryFlags)
        guard stageFD >= 0 else { throw .io(stageName, errno: errno) }
        let stage = UndoFD(stageFD)
        let stagePath = copyPath + "/" + stageName
        let tempIndex = stagePath + "/index"

        let written = try copyIndex(from: indexPath, to: stage)
        if written == nil {
            _ = try runner.text(["read-tree", head], indexFile: tempIndex)
        }
        let indexWritten = written ?? (0, 0)

        let listing = try runner.run(["ls-files", "-s", "--debug", "-z"], indexFile: tempIndex, maxOutput: 64 * 1024 * 1024)
        guard listing.status == 0 else { throw .gitFailed("ls-files") }
        guard let entries = UndoIndexListing.parse(listing.stdout, deadline: budget.deadline) else {
            throw ContinuousClock.now >= budget.deadline ? .outOfTime : .gitFailed("ls-files")
        }
        guard entries.allSatisfy({ $0.stage == 0 }) else { throw .unmergedFiles }
        let indexTree = try runner.text(["write-tree"], indexFile: tempIndex)

        let zeros = String(repeating: "0", count: head.utf8.count)
        var records: [String] = []
        var staged: [(mode: String, file: String, path: String)] = []
        var touched = Set<String>()
        var tally = UndoTally()
        let rootFD = try UndoTree.openDirectory(root)
        var cursor = try UndoDirCursor(root: rootFD)
        for (number, entry) in entries.enumerated() {
            guard entry.isFile || entry.isLink, entry.flags & UndoIndexEntry.leaveAlone == 0 else { continue }
            if number & 0x3F == 0, ContinuousClock.now >= budget.deadline { throw .outOfTime }
            let components = entry.path.split(separator: "/").map(String.init)
            guard let name = components.last, components.allSatisfy({ $0 != "." && $0 != ".." }) else { continue }
            // One open folder per level: deeper than the limit is never
            // walked (descriptors are finite).
            guard components.count <= budget.maxDepth else {
                notes.append(UndoSkip.tooDeep(levels: budget.maxDepth).note)
                continue
            }
            let state: UndoWorktreeFile
            let parent: Int32
            do throws(UndoSkip) {
                parent = try cursor.directory(components.dropLast(), shown: entry.path)
                state = worktreeFile(name, in: parent)
            } catch {
                // A folder that is gone: the file is gone. One that is now
                // a link is not followed, and the entry is left as it was.
                guard case .missing = error else { continue }
                if budget.isSecret(entry.path) { notes.append(UndoSkip.secret(entry.path).note); continue }
                records.append("0 \(zeros)\t\(entry.path)"); touched.insert(entry.path)
                continue
            }
            guard state.mayDiffer(from: entry, indexWritten: indexWritten) else { continue }
            if budget.isSecret(entry.path) {
                notes.append(UndoSkip.secret(entry.path).note)
                continue
            }
            switch state {
            case .missing, .other:
                records.append("0 \(zeros)\t\(entry.path)"); touched.insert(entry.path)
            case .file(let size, _, _, let executable):
                // A second name for another file (a secret, say) would put
                // that file's bytes in the repository's objects.
                var info = stat()
                guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_nlink == 1 else {
                    notes.append(UndoSkip.hardLinked(entry.path).note)
                    continue
                }
                let file = "f\(staged.count)"
                try stageFile(name, in: parent, as: file, into: stage, shown: entry.path, budget: budget, tally: &tally)
                tally.bytes += size
                staged.append((executable ? "100755" : "100644", file, entry.path))
                touched.insert(entry.path)
            case .link:
                let file = "f\(staged.count)"
                try stageLink(name, in: parent, as: file, into: stage, shown: entry.path)
                staged.append(("120000", file, entry.path))
                touched.insert(entry.path)
            }
            tally.entries += 1
            try budget.check(tally)
        }

        // Files kept: changed in the working tree, or staged (the index
        // differs from HEAD's tree, read with `ls-tree`: tree objects only).
        if indexTree != headTree {
            touched.formUnion(try stagedPaths(runner, head: head, entries: entries, deadline: budget.deadline))
        }
        tally.files = touched.count
        tally.entries = tally.files
        tally.lines = nil
        guard records.isEmpty == false || staged.isEmpty == false else {
            guard indexTree != headTree else { return Kept(head: head, stash: nil) }
            return Kept(
                head: head, stash: try commitPair(runner, head: head, index: indexTree, work: indexTree), tally: tally)
        }
        // The objects land in the repository's disk: the same floor applies.
        if let free = UndoTree.freeBytes(at: root + "/.git"), free < tally.bytes + UndoLimits.freeSpaceFloor {
            throw .lowDisk(free: free)
        }
        if staged.isEmpty == false {
            let paths = staged.map { stagePath + "/" + $0.file }.joined(separator: "\n") + "\n"
            let hashed = try runner.text(["hash-object", "--no-filters", "-w", "--stdin-paths"], input: Data(paths.utf8))
                .split(whereSeparator: \.isNewline).map(String.init)
            guard hashed.count == staged.count, hashed.allSatisfy(UndoGit.isObjectID) else {
                throw .gitFailed("hash-object")
            }
            for (item, object) in zip(staged, hashed) { records.append("\(item.mode) \(object)\t\(item.path)") }
        }
        let info = records.map { $0 + "\0" }.joined()
        _ = try runner.text(["update-index", "-z", "--index-info"], input: Data(info.utf8), indexFile: tempIndex)
        let workTree = try runner.text(["write-tree"], indexFile: tempIndex)
        guard workTree != headTree || indexTree != headTree else { return Kept(head: head, stash: nil) }
        return Kept(head: head, stash: try commitPair(runner, head: head, index: indexTree, work: workTree), tally: tally)
    }

    /// Paths whose index entry differs from HEAD's tree (added, changed or
    /// removed in the index).
    private static func stagedPaths(
        _ runner: UndoGit, head: String, entries: [UndoIndexEntry], deadline: ContinuousClock.Instant
    ) throws(UndoSkip) -> Set<String> {
        let listing = try runner.run(["ls-tree", "-r", "-z", "--full-tree", head], maxOutput: 64 * 1024 * 1024)
        guard listing.status == 0 else { throw .gitFailed("ls-tree") }
        var tree: [String: String] = [:]
        for (number, raw) in listing.stdout.split(separator: 0).enumerated() {
            if number & 0x3FF == 0, ContinuousClock.now >= deadline { throw .outOfTime }
            let line = String(decoding: raw, as: UTF8.self)
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let fields = line[..<tab].split(separator: " ")
            guard fields.count == 3 else { continue }
            tree[String(line[line.index(after: tab)...])] = fields[0] + " " + fields[2]
        }
        var paths = Set<String>()
        for entry in entries {
            if tree.removeValue(forKey: entry.path) != entry.mode + " " + entry.object { paths.insert(entry.path) }
        }
        return paths.union(tree.keys)
    }

    /// The index commit and the work commit on top, as `git stash` makes
    /// them. Returns the work commit.
    private static func commitPair(_ runner: UndoGit, head: String, index: String, work: String) throws(UndoSkip)
        -> String {
        let indexCommit = try runner.text(["commit-tree", "--no-gpg-sign", "-p", head, "-m", "index on rv undo", index])
        guard UndoGit.isObjectID(indexCommit) else { throw .gitFailed("commit-tree") }
        let workCommit = try runner.text([
            "commit-tree", "--no-gpg-sign", "-p", head, "-p", indexCommit, "-m", "rv undo", work,
        ])
        guard UndoGit.isObjectID(workCommit) else { throw .gitFailed("commit-tree") }
        return workCommit
    }

    /// Copies the repository's index into `stage/index`; returns when the
    /// index was written, or nil when the repository has no index file.
    private static func copyIndex(from path: String, to stage: borrowing UndoFD) throws(UndoSkip)
        -> (seconds: Int, nanoseconds: Int)? {
        let input = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if input < 0, errno == ENOENT { return nil }
        guard input >= 0 else { throw .io("index", errno: errno) }
        let from = UndoFD(input)
        var info = stat()
        guard fstat(from.raw, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maxIndexBytes else {
            throw .gitFailed("index")
        }
        let output = openat(stage.raw, "index", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard output >= 0 else { throw .io("index", errno: errno) }
        let to = UndoFD(output)
        try UndoTree.pump(from: from.raw, to: to.raw, shown: "index", limit: UInt64(maxIndexBytes), deadline: nil)
        return UndoStat.mtime(info)
    }

    private static func worktreeFile(_ name: String, in parent: Int32) -> UndoWorktreeFile {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return .missing }
        let (seconds, nanoseconds) = UndoStat.mtime(info)
        let size = UInt64(max(0, info.st_size))
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            return .file(size: size, mtimeSeconds: seconds, mtimeNanoseconds: nanoseconds,
                         executable: info.st_mode & 0o100 != 0)
        case S_IFLNK:
            return .link(size: size, mtimeSeconds: seconds, mtimeNanoseconds: nanoseconds)
        default:
            return .other
        }
    }

    /// The bytes of one tracked file into `stage/<file>`: a clone where the
    /// disk allows, else a copy. The open must still be a regular file.
    private static func stageFile(
        _ name: String, in parent: Int32, as file: String, into stage: borrowing UndoFD, shown: String,
        budget: UndoBudget, tally: inout UndoTally
    ) throws(UndoSkip) {
        if budget.clones, UndoClone.cloneFile(name, from: parent, to: stage.raw, as: file) {
            var info = stat()
            // A clone of a link swapped in is the link: refuse it.
            guard fstatat(stage.raw, file, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG,
                info.st_nlink == 1
            else {
                throw .io(shown, errno: EINVAL)
            }
            return
        }
        let input = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard input >= 0 else { throw .io(shown, errno: errno) }
        let from = UndoFD(input)
        var info = stat()
        guard fstat(from.raw, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw .io(shown, errno: EINVAL)
        }
        let output = openat(stage.raw, file, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard output >= 0 else { throw .io(shown, errno: errno) }
        let to = UndoFD(output)
        let left = budget.maxBytes - min(budget.maxBytes, tally.bytes)
        try UndoTree.pump(
            from: from.raw, to: to.raw, shown: shown, limit: left, deadline: budget.deadline, counted: tally.bytes)
    }

    /// A tracked link's target, as the bytes git stores for it.
    private static func stageLink(
        _ name: String, in parent: Int32, as file: String, into stage: borrowing UndoFD, shown: String
    ) throws(UndoSkip) {
        let target = try UndoTree.linkTarget(name, in: parent, shown: shown)
        let output = openat(stage.raw, file, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard output >= 0 else { throw .io(shown, errno: errno) }
        let to = UndoFD(output)
        let bytes = Array(target.utf8)
        let raw = to.raw
        let count = bytes.withUnsafeBytes { write(raw, $0.baseAddress, $0.count) }
        guard count == bytes.count else { throw .io(shown, errno: errno) }
    }
}

/// `stat` fields that differ by platform.
enum UndoStat {
    static func mtime(_ info: stat) -> (seconds: Int, nanoseconds: Int) {
        #if canImport(Darwin)
        (Int(info.st_mtimespec.tv_sec), Int(info.st_mtimespec.tv_nsec))
        #else
        (Int(info.st_mtim.tv_sec), Int(info.st_mtim.tv_nsec))
        #endif
    }
}
