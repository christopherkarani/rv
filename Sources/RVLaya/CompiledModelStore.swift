#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// One file of a compiled model as installed.
struct CompiledFileRecord: Codable, Equatable, Sendable {
    let size: Int64
    let sha256: String
}

/// Stable, verified compiled-model cache under rv's guarded config dir
/// (`~/.config/rv/cache/laya/models`, which `core.secrets:home-rv-config`
/// keeps agents from writing).
///
/// `MLModel.compileModel` returns a temp directory macOS may purge under a
/// long-lived daemon, so the compiled `.mlmodelc` is copied into an
/// rv-owned entry and reused:
///
/// - Versioned: `<path key>-<version key>.mlmodelc`, where the version key
///   covers the package's modification time and the OS build, so an
///   updated bundle or OS compiles fresh. Superseded entries of the same
///   package are swept.
/// - Atomic: the copy lands in a `.partial-` sibling and is renamed into
///   place; a manifest is written beside it last and is the commit record.
/// - Verified: the manifest records every file's size and SHA-256, taken
///   from the installed copy, and is checked before every load. A missing
///   or mismatched manifest (a crash or full disk mid-copy, or a planted
///   or edited model) discards the entry and recompiles from the bundle; a
///   mismatched entry is never loaded. (Hashing the ~600 MB model costs
///   well under a second against a multi-second load.)
/// - Self-healing: a failed load discards the entry, purges Core ML's own
///   e5rt cache, and retries exactly once.
///
/// Every compile and load goes through `coreML` (disk precheck plus the
/// in-flight crash marker). Generic over the model so tests need no Core ML.
struct CompiledModelStore<Model> {
    let root: URL?
    let coreML: CoreMLGuard
    let version: String
    let compile: (URL) throws -> URL
    let load: (URL) throws -> Model
    /// Lowercase hex SHA-256 of one regular file; nil when unreadable.
    let digest: (URL) -> String?

    func model(package: URL) throws -> Model {
        do {
            return try attempt(package)
        } catch let refusal as CoreMLDiskSpaceError {
            throw refusal
        } catch {
            coreML.log("rvd: judge model load failed; purging compiled-model caches and retrying once")
            if let entry = entry(for: package) { discard(entry) }
            coreML.purgeCache()
            return try attempt(package)
        }
    }

    private struct Entry {
        let dir: URL
        let manifest: URL
        let pathKey: String
    }

    private func attempt(_ package: URL) throws -> Model {
        let entry = entry(for: package)
        if let entry {
            if isVerified(entry) {
                return try coreML.run(checkingDisk: true) { try load(entry.dir) }
            }
            if exists(entry) {
                coreML.log("rvd: compiled judge model failed verification; recompiling from the bundle")
                discard(entry)
            }
        }
        let compiled = try coreML.run(checkingDisk: true) { try compile(package) }
        var loadURL = compiled
        if let entry, install(compiled, as: entry) {
            loadURL = entry.dir
            try? FileManager.default.removeItem(at: compiled)
            sweep(keeping: entry)
        }
        return try coreML.run(checkingDisk: true) { try load(loadURL) }
    }

    /// nil when the cache root is unusable (then the compile output is loaded
    /// directly, as before the cache existed).
    private func entry(for package: URL) -> Entry? {
        guard let root, Self.usableRoot(root) else { return nil }
        let stamp = (try? FileManager.default.attributesOfItem(atPath: package.path))?[.modificationDate] as? Date
        let pathKey = Self.fnv1a(package.path)
        let versionKey = Self.fnv1a("\(stamp?.timeIntervalSince1970 ?? 0)|\(version)")
        let name = "\(pathKey)-\(versionKey).mlmodelc"
        return Entry(
            dir: root.appendingPathComponent(name, isDirectory: true),
            manifest: root.appendingPathComponent(name + Self.manifestSuffix),
            pathKey: pathKey)
    }

    private func exists(_ entry: Entry) -> Bool {
        var info = stat()
        return lstat(entry.dir.path, &info) == 0 || lstat(entry.manifest.path, &info) == 0
    }

    private func isVerified(_ entry: Entry) -> Bool {
        var info = stat()
        guard lstat(entry.dir.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              let recorded = Self.readManifest(entry.manifest),
              let actual = Self.manifest(of: entry.dir, digest: digest)
        else { return false }
        return recorded == actual
    }

    private func install(_ compiled: URL, as entry: Entry) -> Bool {
        let fm = FileManager.default
        let partial = entry.dir.deletingLastPathComponent()
            .appendingPathComponent(".\(entry.dir.lastPathComponent)\(Self.partialMarker)\(UUID().uuidString)")
        guard (try? fm.copyItem(at: compiled, to: partial)) != nil,
              let manifest = Self.manifest(of: partial, digest: digest),
              let data = try? JSONEncoder().encode(manifest)
        else {
            try? fm.removeItem(at: partial)
            return false
        }
        discard(entry)
        guard rename(partial.path, entry.dir.path) == 0 else {
            try? fm.removeItem(at: partial)
            return false
        }
        try? data.write(to: entry.manifest, options: .atomic)
        return true
    }

    /// Manifest first, so a half-removed entry is never trusted.
    private func discard(_ entry: Entry) {
        try? FileManager.default.removeItem(at: entry.manifest)
        try? FileManager.default.removeItem(at: entry.dir)
    }

    /// Removes this package's superseded entries and stale partial copies.
    /// Other packages' entries and anything else in the root are kept.
    private func sweep(keeping entry: Entry) {
        guard let root, let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        let keep: Set<String> = [entry.dir.lastPathComponent, entry.manifest.lastPathComponent]
        for name in names where !keep.contains(name) {
            let ours = name.hasPrefix("\(entry.pathKey)-")
                && (name.hasSuffix(".mlmodelc") || name.hasSuffix(".mlmodelc" + Self.manifestSuffix))
            let partial = name.hasPrefix(".\(entry.pathKey)-") && name.contains(Self.partialMarker)
            guard ours || partial else { continue }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }

    static var manifestSuffix: String { ".manifest.json" }
    static var partialMarker: String { ".partial-" }
    /// A manifest is a few hundred bytes; anything far larger is not one.
    static var maximumManifestBytes: Int { 1 << 20 }

    /// The recorded manifest, read only from this user's regular file under
    /// the size cap (a FIFO or symlink there is not read, so cannot hang).
    static func readManifest(_ url: URL) -> [String: CompiledFileRecord]? {
        var data = Data()
        var oversized = false
        let read = OwnedRegularFile.read(url.path) { chunk in
            guard !oversized else { return }
            data.append(contentsOf: chunk)
            oversized = data.count > maximumManifestBytes
        }
        guard read, !oversized else { return nil }
        return try? JSONDecoder().decode([String: CompiledFileRecord].self, from: data)
    }

    /// Relative path → size and SHA-256 of every regular file. nil on a
    /// symlink, an unreadable file, or an empty tree: such an entry is never
    /// trusted.
    static func manifest(of dir: URL, digest: (URL) -> String?) -> [String: CompiledFileRecord]? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else {
            return nil
        }
        let base = dir.resolvingSymlinksInPath().path + "/"
        var records: [String: CompiledFileRecord] = [:]
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            if values.isSymbolicLink == true { return nil }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, let size = values.fileSize, let sha = digest(url) else { return nil }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(base) else { return nil }
            records[String(path.dropFirst(base.count))] = CompiledFileRecord(size: Int64(size), sha256: sha)
        }
        return records.isEmpty ? nil : records
    }

    /// The root must be this user's real directory (created owner-only if
    /// missing), as must its parent.
    static func usableRoot(_ root: URL) -> Bool {
        try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return isOwnedDirectory(root) && isOwnedDirectory(root.deletingLastPathComponent())
    }

    static func isOwnedDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == geteuid()
    }

    /// Process-stable key (String.hashValue is per-process seeded).
    static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

/// The compiled copies older builds kept in `~/Library/Caches/rv-laya`
/// (agent-writable, so no longer trusted or loaded).
enum LegacyCompiledModels {
    /// Left alone this long after their last write, so a still-running older
    /// rvd keeps its copy for a while.
    static let minimumAge: TimeInterval = 7 * 24 * 3600

    /// Removes `<hex>.mlmodelc`, `<hex>-<hex>.mlmodelc` and their
    /// `.manifest.json` siblings older than `minimumAge`. Nothing else in
    /// the directory is touched; a symlinked or foreign root is skipped.
    static func sweep(root: URL, now: Date) {
        guard CompiledModelStore<Never>.isOwnedDirectory(root),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where isLegacyName(name) {
            let url = root.appendingPathComponent(name)
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_uid == geteuid() else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.modificationSeconds))
            guard now.timeIntervalSince(modified) >= minimumAge else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func isLegacyName(_ name: String) -> Bool {
        var stem = Substring(name)
        if stem.hasSuffix(".manifest.json") { stem = stem.dropLast(".manifest.json".count) }
        guard stem.hasSuffix(".mlmodelc") else { return false }
        stem = stem.dropLast(".mlmodelc".count)
        let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 16 && part.allSatisfy { $0.isHexDigit && !$0.isUppercase }
        }
    }
}

/// Reads this user's regular files without following a final symlink or
/// blocking on a FIFO: `open(O_NOFOLLOW|O_NONBLOCK)`, then `fstat` on the
/// descriptor actually read (so a swap after a path check cannot redirect
/// it), then `read(2)` to EOF.
enum OwnedRegularFile {
    static let chunkSize = 1 << 20

    /// Calls `body` with each chunk in order; false when the path is not
    /// this user's regular file or a read fails.
    static func read(_ path: String, body: (UnsafeRawBufferPointer) -> Void) -> Bool {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid() else {
            return false
        }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let count = systemRead(fd, buffer.baseAddress, chunkSize)
            if count == 0 { return true }
            if count < 0 {
                if errno == EINTR { continue }
                return false
            }
            body(UnsafeRawBufferPointer(rebasing: buffer[..<count]))
        }
    }
}

/// `read(2)`, named apart from `OwnedRegularFile.read`.
private func systemRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.read(fd, buffer, count)
    #else
    Glibc.read(fd, buffer, count)
    #endif
}

extension stat {
    /// Modification time in seconds, on Darwin and Glibc.
    var modificationSeconds: Int {
        #if canImport(Darwin)
        Int(st_mtimespec.tv_sec)
        #else
        Int(st_mtim.tv_sec)
        #endif
    }
}
