#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Reads the saved tree and the box into a `BoxReview`. Read-only: it
/// never follows a link, opens every file with `O_NOFOLLOW`, and only
/// walks into names `lstat` says are folders. Plain directories, so it
/// runs (and is tested) on Linux too.
public enum BoxHomecomingScan {
    public enum Failure: Error, Equatable, Sendable {
        /// A root or a folder in it could not be read.
        case unreadable(String)
        /// More names than a review can hold.
        case tooLarge(Int)
    }

    /// The most names rv reads from the two trees together.
    public static let maxEntries = 400_000

    /// Everything that changed between `savedRoot` (the project as it was
    /// when the box started at `startedAt`) and `boxRoot`.
    public static func review(savedRoot: String, boxRoot: String, startedAt: Date) -> Result<BoxReview, Failure> {
        let saved: [String: BoxTreeEntry]
        let box: [String: BoxTreeEntry]
        switch walk(savedRoot, budget: maxEntries, skipAtRoot: { _ in false }) {
        case .failure(let failure): return .failure(failure)
        case .success(let entries): saved = entries
        }
        // The volume's own bookkeeping folders (`.fseventsd`, `.Trashes`)
        // are not project content unless the project had them too.
        switch walk(boxRoot, budget: maxEntries - saved.count, skipAtRoot: { name in
            WorkspaceFilesystemMetadata.isBookkeepingName(name) && saved[name] == nil
        }) {
        case .failure(let failure): return .failure(failure)
        case .success(let entries): box = entries
        }
        var links: [String: String] = [:]
        for (relative, entry) in box {
            if case .symlink(let target) = entry.kind { links[relative] = target }
        }
        let table = WorkspaceLinkTable(links)
        let names = Set(saved.keys).union(box.keys)
        var changes: [BoxPathChange] = []
        for relative in names.sorted() {
            let before = saved[relative]
            let after = box[relative]
            let (same, lines) = compare(
                relative, saved: before, box: after,
                savedRoot: savedRoot, boxRoot: boxRoot, startedAt: startedAt)
            if let change = BoxHomecoming.classify(
                relative, saved: before, box: after, sameContent: same, lines: lines, startedAt: startedAt,
                linkStaysInside: { workspaceSymlinkTargetStaysInside(link: $0, target: $1, links: table) })
            {
                changes.append(change)
            }
        }
        return .success(BoxHomecoming.review(changes, names: names, startedAt: startedAt))
    }

    /// Whether the two sides hold the same content, and the line counts
    /// when they differ and both are text.
    static func compare(
        _ relative: String, saved: BoxTreeEntry?, box: BoxTreeEntry?,
        savedRoot: String, boxRoot: String, startedAt: Date
    ) -> (Bool, BoxLineCount?) {
        let savedPath = savedRoot + "/" + relative
        let boxPath = boxRoot + "/" + relative
        switch (saved?.kind, box?.kind) {
        case (.symlink(let left)?, .symlink(let right)?):
            return (left == right, nil)
        case (.file?, .file?):
            guard let saved, let box else { return (false, nil) }
            if saved.size == box.size {
                // Neither side was touched since the box started: the copy
                // rv made then is still the saved file.
                if saved.changedAt <= startedAt, box.changedAt <= startedAt { return (true, nil) }
                if BoxFileRead.sameBytes(savedPath, boxPath) == true { return (true, nil) }
            }
            return (false, counted(old: saved.size, savedPath, new: box.size, boxPath))
        case (.file?, nil):
            return (false, counted(old: saved?.size ?? 0, savedPath, new: nil, nil))
        case (nil, .file?):
            return (false, counted(old: nil, nil, new: box?.size ?? 0, boxPath))
        default:
            return (false, nil)
        }
    }

    private static func counted(old: UInt64?, _ oldPath: String?, new: UInt64?, _ newPath: String?) -> BoxLineCount? {
        let limit = UInt64(BoxLineDiff.maxBytes)
        guard (old ?? 0) <= limit, (new ?? 0) <= limit else { return nil }
        var before: Data?
        var after: Data?
        if let oldPath {
            guard let data = BoxFileRead.contents(oldPath, limit: BoxLineDiff.maxBytes) else { return nil }
            before = data
        }
        if let newPath {
            guard let data = BoxFileRead.contents(newPath, limit: BoxLineDiff.maxBytes) else { return nil }
            after = data
        }
        return BoxLineDiff.count(old: before, new: after)
    }

    /// Every name under `root`, keyed by its path relative to `root`.
    static func walk(
        _ root: String, budget: Int, skipAtRoot: (String) -> Bool
    ) -> Result<[String: BoxTreeEntry], Failure> {
        guard let top = entry(at: root), top.isDirectory else { return .failure(.unreadable(root)) }
        var entries: [String: BoxTreeEntry] = [:]
        var pending = [""]
        while let relative = pending.popLast() {
            let directory = relative.isEmpty ? root : root + "/" + relative
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
                return .failure(.unreadable(directory))
            }
            for name in names.sorted() {
                if relative.isEmpty, skipAtRoot(name) { continue }
                let child = relative.isEmpty ? name : relative + "/" + name
                guard let found = entry(at: root + "/" + child) else {
                    return .failure(.unreadable(root + "/" + child))
                }
                entries[child] = found
                guard entries.count <= budget else { return .failure(.tooLarge(maxEntries)) }
                if found.isDirectory { pending.append(child) }
            }
        }
        return .success(entries)
    }

    /// `lstat(2)`, as a tree entry; nil when it can't be read.
    static func entry(at path: String) -> BoxTreeEntry? {
        guard path.contains("\0") == false else { return nil }
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        #if canImport(Darwin)
        let modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
        let changed = TimeInterval(info.st_ctimespec.tv_sec) + TimeInterval(info.st_ctimespec.tv_nsec) / 1e9
        #else
        let modified = TimeInterval(info.st_mtim.tv_sec) + TimeInterval(info.st_mtim.tv_nsec) / 1e9
        let changed = TimeInterval(info.st_ctim.tv_sec) + TimeInterval(info.st_ctim.tv_nsec) / 1e9
        #endif
        let kind: BoxTreeEntry.Kind
        switch info.st_mode & S_IFMT {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .directory
        case S_IFLNK:
            guard let target = BoxFileRead.linkTarget(path) else { return nil }
            kind = .symlink(target: target)
        default: kind = .special
        }
        return BoxTreeEntry(
            kind: kind, size: UInt64(max(0, info.st_size)), mode: UInt16(info.st_mode & 0o7777),
            changedAt: Date(timeIntervalSince1970: max(modified, changed)))
    }
}

/// Bounded reads that never follow a link at the last name.
enum BoxFileRead {
    /// The file's bytes, or nil when it is not a regular file or holds
    /// more than `limit`.
    static func contents(_ path: String, limit: Int) -> Data? {
        guard let descriptor = openRegular(path) else { return nil }
        defer { close(descriptor) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return nil }
            if count == 0 { return data }
            data.append(contentsOf: buffer[0..<count])
            if data.count > limit { return nil }
        }
    }

    /// Whether two regular files hold the same bytes; nil when either
    /// can't be read.
    static func sameBytes(_ left: String, _ right: String) -> Bool? {
        guard let first = openRegular(left) else { return nil }
        defer { close(first) }
        guard let second = openRegular(right) else { return nil }
        defer { close(second) }
        var a = [UInt8](repeating: 0, count: 65_536)
        var b = [UInt8](repeating: 0, count: 65_536)
        while true {
            guard let countA = fill(first, &a), let countB = fill(second, &b) else { return nil }
            if countA != countB || a[0..<countA] != b[0..<countB] { return false }
            if countA == 0 { return true }
        }
    }

    /// The link's target text; nil when it is not a link.
    static func linkTarget(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = buffer.withUnsafeMutableBufferPointer { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return readlink(path, base, raw.count - 1)
        }
        guard count >= 0 else { return nil }
        return String(decoding: buffer[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func openRegular(_ path: String) -> Int32? {
        guard path.contains("\0") == false else { return nil }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    /// Reads until `buffer` is full or the file ends; nil on an error.
    private static func fill(_ descriptor: Int32, _ buffer: inout [UInt8]) -> Int? {
        var total = 0
        while total < buffer.count {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(descriptor, raw.baseAddress.map { $0 + total }, raw.count - total)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return nil }
            if count == 0 { break }
            total += count
        }
        return total
    }
}
