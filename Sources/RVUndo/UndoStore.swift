#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// One kept copy, as `rv undo` lists it. Written last, so a copy without
/// a manifest never existed.
public struct UndoManifest: Sendable, Equatable, Codable {
    public static let schema = 1

    public enum Kind: String, Sendable, Equatable, Codable {
        /// Git commits: `head`, and `stash` with the unsaved changes, whose
        /// new objects are in the copy's `objects/` (never the repository).
        case git
        /// File copies under `data/`, repo-relative.
        case files
        /// Nothing was kept; `notes` say why.
        case skipped
    }

    public struct Git: Sendable, Equatable, Codable {
        public var head: String
        public var stash: String?
    }

    public var schema: Int
    public var id: String
    public var createdAt: Date
    public var host: String
    public var command: String
    public var reason: UndoReason
    public var repoRoot: String
    public var kind: Kind
    public var git: Git?
    /// Repo-relative paths copied under `data/` (top level of each copy).
    public var paths: [String]
    public var tally: UndoTally
    public var notes: [String]
}

/// The owner-only store of kept copies: `<root>/<id>/manifest.json`, and
/// `<root>/<id>/data/` (file copies) or `<root>/<id>/objects/` (the git
/// objects a git copy made). The root and every copy are 0700, the manifest
/// 0600. rvd writes; `rv undo` reads and restores.
public struct UndoStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/.config/rv/undo` for a config directory.
    public static func inConfigDirectory(_ configDirectory: URL) -> UndoStore {
        UndoStore(root: configDirectory.appendingPathComponent("undo", isDirectory: true))
    }

    static let manifestName = "manifest.json"
    static let dataName = "data"
    static let objectsName = "objects"

    /// `20261127-140312-1a2b`: sorts by time.
    static func makeID(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let random = String(UInt16.random(in: .min ... .max), radix: 16)
        return formatter.string(from: now) + "-" + String(repeating: "0", count: 4 - random.count) + random
    }

    /// An id is ours only in our own shape: never a path.
    static func isID(_ text: String) -> Bool {
        text.count == 20 && text.allSatisfy { $0.isNumber || $0 == "-" || ("a"..."f").contains($0) }
    }

    /// Makes the root (0700) and a fresh copy directory in it.
    func makeCopy(id: String) throws(UndoSkip) -> UndoFD {
        let path = root.path
        if mkdir(path, 0o700) != 0, errno != EEXIST { throw .io(path, errno: errno) }
        let rootFD = try UndoTree.openDirectory(path)
        var info = stat()
        // The root must be ours and closed to everyone else.
        guard fstat(rootFD.raw, &info) == 0, info.st_uid == getuid() else { throw .io(path, errno: EPERM) }
        if info.st_mode & 0o077 != 0 { _ = fchmod(rootFD.raw, 0o700) }
        guard mkdirat(rootFD.raw, id, 0o700) == 0 else { throw .io(path + "/" + id, errno: errno) }
        let fd = openat(rootFD.raw, id, UndoTree.directoryFlags)
        guard fd >= 0 else { throw .io(path + "/" + id, errno: errno) }
        return UndoFD(fd)
    }

    /// Writes the manifest last, owner-only, through the copy's descriptor.
    func writeManifest(_ manifest: UndoManifest, in copy: borrowing UndoFD) throws(UndoSkip) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(manifest) else { throw .io(Self.manifestName, errno: EINVAL) }
        let temp = Self.manifestName + ".tmp"
        let fd = openat(copy.raw, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw .io(temp, errno: errno) }
        let file = UndoFD(fd)
        let raw = file.raw
        let written = data.withUnsafeBytes { write(raw, $0.baseAddress, $0.count) }
        guard written == data.count, fsync(file.raw) == 0 else { throw .io(temp, errno: errno) }
        guard renameat(copy.raw, temp, copy.raw, Self.manifestName) == 0 else { throw .io(temp, errno: errno) }
    }

    /// Every readable manifest, newest first.
    public func list() -> [UndoManifest] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return names.filter(Self.isID).compactMap { id in
            let url = root.appendingPathComponent(id).appendingPathComponent(Self.manifestName)
            guard let data = try? Self.readOwnerOnly(url.path),
                let manifest = try? decoder.decode(UndoManifest.self, from: data),
                manifest.schema == UndoManifest.schema, manifest.id == id
            else { return nil }
            return manifest
        }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Reads a small regular file that is ours and not a link.
    static func readOwnerOnly(_ path: String) throws -> Data {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw UndoSkip.io(path, errno: errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
            info.st_size <= 1024 * 1024
        else { throw UndoSkip.io(path, errno: EPERM) }
        return handle.readDataToEndOfFile()
    }

    /// Where a copy's files are.
    public func dataDirectory(of manifest: UndoManifest) -> URL {
        root.appendingPathComponent(manifest.id).appendingPathComponent(Self.dataName, isDirectory: true)
    }

    /// Where a git copy's objects are.
    public func objectsDirectory(of id: String) -> URL {
        root.appendingPathComponent(id).appendingPathComponent(Self.objectsName, isDirectory: true)
    }

    /// Removes one copy's directory (links inside are removed, never
    /// followed), stopping at `deadline` (a later prune finishes it).
    func remove(id: String, deadline: ContinuousClock.Instant? = nil) {
        guard Self.isID(id), let rootFD = try? UndoTree.openDirectory(root.path) else { return }
        let copyFD = openat(rootFD.raw, id, UndoTree.directoryFlags)
        if copyFD >= 0 {
            _ = unlinkat(copyFD, Self.manifestName, 0)
            close(copyFD)
        }
        UndoRemove.tree(id, in: rootFD.raw, deadline: deadline)
    }

    /// Skipped requests keep only their note; at most this many are kept.
    static let maxSkipped = 10

    /// Which copies go, oldest first: expired ones, skipped notes past
    /// `maxSkipped`, then the oldest copies, of any kind, while the store
    /// holds more than `maxCopies` or `maxBytes` (git copies count the
    /// bytes they put in their repository). Pure.
    static func evictions(
        _ manifests: [UndoManifest], now: Date, retention: TimeInterval = UndoLimits.retention,
        maxCopies: Int = UndoLimits.storeMaxCopies, maxBytes: UInt64 = UndoLimits.storeMaxBytes
    ) -> [UndoManifest] {
        let newestFirst = manifests.sorted { $0.createdAt > $1.createdAt }
        var going = Set<String>()
        for manifest in newestFirst where now.timeIntervalSince(manifest.createdAt) > retention {
            going.insert(manifest.id)
        }
        for manifest in newestFirst.filter({ $0.kind == .skipped && going.contains($0.id) == false })
            .dropFirst(maxSkipped) {
            going.insert(manifest.id)
        }
        var staying = newestFirst.filter { going.contains($0.id) == false }
        var bytes = staying.reduce(UInt64(0)) { $0 + $1.storedBytes }
        // Too many: the oldest goes, whatever its kind. Too big: the oldest
        // that holds bytes goes (an empty one would not help).
        while staying.count > maxCopies, let oldest = staying.popLast() {
            going.insert(oldest.id)
            bytes -= oldest.storedBytes
        }
        while bytes > maxBytes, let index = staying.lastIndex(where: { $0.storedBytes > 0 }) {
            let oldest = staying.remove(at: index)
            going.insert(oldest.id)
            bytes -= oldest.storedBytes
        }
        return newestFirst.reversed().filter { going.contains($0.id) }
    }

    /// Removes what `evictions` names, oldest first, and leftovers: copies
    /// a crash left without a manifest once they are an hour old, and the
    /// half-removed `data` or `stage` folders a copy cut short left behind.
    /// Each copy loses its manifest first, so a removal cut short by
    /// `deadline` leaves a leftover a later prune finishes, never a half
    /// copy `rv undo` lists. Returns the copies whose manifests went.
    @discardableResult
    public func prune(
        now: Date, deadline: ContinuousClock.Instant? = nil, retention: TimeInterval = UndoLimits.retention,
        maxCopies: Int = UndoLimits.storeMaxCopies, maxBytes: UInt64 = UndoLimits.storeMaxBytes
    ) -> [UndoManifest] {
        guard let rootFD = try? UndoTree.openDirectory(root.path) else { return [] }
        let kept = list()
        var removed: [UndoManifest] = []
        for manifest in Self.evictions(kept, now: now, retention: retention, maxCopies: maxCopies, maxBytes: maxBytes) {
            if let deadline, ContinuousClock.now >= deadline { return removed }
            let copyFD = openat(rootFD.raw, manifest.id, UndoTree.directoryFlags)
            if copyFD >= 0 {
                _ = unlinkat(copyFD, Self.manifestName, 0)
                close(copyFD)
            }
            removed.append(manifest)
            UndoRemove.tree(manifest.id, in: rootFD.raw, deadline: deadline)
        }
        let removedIDs = Set(removed.map(\.id))
        for manifest in kept where removedIDs.contains(manifest.id) == false {
            if let deadline, ContinuousClock.now >= deadline { return removed }
            let copyFD = openat(rootFD.raw, manifest.id, UndoTree.directoryFlags)
            guard copyFD >= 0 else { continue }
            let copy = UndoFD(copyFD)
            UndoRemove.tree(UndoGitCopy.stageName, in: copy.raw, deadline: deadline)
            if manifest.kind != .files { UndoRemove.tree(Self.dataName, in: copy.raw, deadline: deadline) }
            if manifest.kind != .git { UndoRemove.tree(Self.objectsName, in: copy.raw, deadline: deadline) }
        }
        let listed = Set(kept.map(\.id)).subtracting(removedIDs)
        let budget = UndoBudget(maxEntries: .max, deadline: deadline ?? .now + .seconds(86_400))
        let names = (try? UndoTree.names(in: rootFD, shown: root.path, budget: budget)) ?? []
        for id in names where Self.isID(id) && listed.contains(id) == false {
            if let deadline, ContinuousClock.now >= deadline { break }
            var info = stat()
            guard fstatat(rootFD.raw, id, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let leftover = removedIDs.contains(id)
            guard leftover || now.timeIntervalSince1970 - Double(UndoStat.mtime(info).seconds) > 3600 else { continue }
            UndoRemove.tree(id, in: rootFD.raw, deadline: deadline)
        }
        return removed
    }
}

extension UndoManifest {
    /// Bytes this copy holds in the store (for a git copy, the bytes it
    /// handed git, an upper bound on its compressed objects).
    var storedBytes: UInt64 { kind == .skipped ? 0 : tally.bytes }
}

/// Text from a manifest, which any process running as the person can
/// write, made safe for a terminal: control characters (C0, DEL, C1),
/// format characters (bidi overrides and isolates, zero-width marks) and
/// line or paragraph separators are dropped.
public enum UndoText {
    public static func plain(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
                continue
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}
