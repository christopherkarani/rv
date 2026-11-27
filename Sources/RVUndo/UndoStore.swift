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
        /// Git refs: `head`, and `stash` when there were unsaved changes.
        case git
        /// File copies under `data/`, repo-relative.
        case files
        /// Nothing was kept; `notes` say why.
        case skipped
    }

    public struct Git: Sendable, Equatable, Codable {
        public var ref: String
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

/// The owner-only store of kept copies: `<root>/<id>/manifest.json` and
/// `<root>/<id>/data/`. The root and every copy are 0700, the manifest
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

    /// Removes one copy's directory (links inside are removed, never
    /// followed).
    func remove(id: String) {
        guard Self.isID(id) else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id, isDirectory: true))
    }

    /// Removes copies older than `retention`, and copies a crash left
    /// without a manifest once they are an hour old. Returns what went, so
    /// the caller can drop their git refs.
    @discardableResult
    public func prune(now: Date, retention: TimeInterval = UndoLimits.retention) -> [UndoManifest] {
        let kept = list()
        let expired = kept.filter { now.timeIntervalSince($0.createdAt) > retention }
        for manifest in expired { remove(id: manifest.id) }
        let listed = Set(kept.map(\.id))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for id in names where Self.isID(id) && listed.contains(id) == false {
            let path = root.appendingPathComponent(id).path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                let modified = attributes[.modificationDate] as? Date, now.timeIntervalSince(modified) > 3600
            else { continue }
            remove(id: id)
        }
        return expired
    }
}
