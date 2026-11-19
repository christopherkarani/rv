#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// Stable compiled-model cache under `~/Library/Caches/rv-laya`.
///
/// `MLModel.compileModel` returns a temp directory macOS may purge under a
/// long-lived daemon, so the compiled `.mlmodelc` is copied into an
/// rv-owned entry and reused:
///
/// - Versioned: `<path key>-<version key>.mlmodelc`, where the version key
///   covers the package's modification time and the OS build, so an
///   updated bundle or OS compiles fresh. Superseded entries of the same
///   package (and the unversioned entries older builds left) are swept.
/// - Atomic: the copy lands in a `.partial-` sibling and is renamed into
///   place; a size manifest is written beside it last and is the commit
///   record. An entry whose manifest is missing or no longer matches (a
///   crash or full disk mid-copy) is recompiled, never loaded. The manifest
///   records sizes, not content hashes: truncation is the failure seen in
///   the field, and a same-user writer could rewrite a hash as easily.
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
        if let entry, isComplete(entry) {
            return try coreML.run { try load(entry.dir) }
        }
        let compiled = try coreML.run { try compile(package) }
        var loadURL = compiled
        if let entry, install(compiled, as: entry) {
            loadURL = entry.dir
            try? FileManager.default.removeItem(at: compiled)
            sweep(keeping: entry)
        }
        return try coreML.run { try load(loadURL) }
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

    private func isComplete(_ entry: Entry) -> Bool {
        var info = stat()
        guard lstat(entry.dir.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              let data = try? Data(contentsOf: entry.manifest),
              let recorded = try? JSONDecoder().decode([String: Int64].self, from: data),
              let actual = Self.manifest(of: entry.dir)
        else { return false }
        return recorded == actual
    }

    private func install(_ compiled: URL, as entry: Entry) -> Bool {
        let fm = FileManager.default
        let partial = entry.dir.deletingLastPathComponent()
            .appendingPathComponent(".\(entry.dir.lastPathComponent)\(Self.partialMarker)\(UUID().uuidString)")
        guard (try? fm.copyItem(at: compiled, to: partial)) != nil,
              let manifest = Self.manifest(of: partial),
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

    /// Removes this package's superseded entries and stale partial copies,
    /// plus unversioned legacy entries (`<hex>.mlmodelc`). Other packages'
    /// entries and anything else in the root are kept.
    private func sweep(keeping entry: Entry) {
        guard let root, let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        let keep: Set<String> = [entry.dir.lastPathComponent, entry.manifest.lastPathComponent]
        for name in names where !keep.contains(name) {
            let ours = name.hasPrefix("\(entry.pathKey)-")
                && (name.hasSuffix(".mlmodelc") || name.hasSuffix(".mlmodelc" + Self.manifestSuffix))
            let partial = name.hasPrefix(".\(entry.pathKey)-") && name.contains(Self.partialMarker)
            guard ours || partial || Self.isLegacyEntry(name) else { continue }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }

    static var manifestSuffix: String { ".manifest.json" }
    static var partialMarker: String { ".partial-" }

    /// `<hex>.mlmodelc`: the unversioned key older builds wrote.
    static func isLegacyEntry(_ name: String) -> Bool {
        guard name.hasSuffix(".mlmodelc") else { return false }
        let stem = name.dropLast(".mlmodelc".count)
        return !stem.isEmpty && stem.count <= 16 && stem.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Relative path → size of every regular file. nil on a symlink or an
    /// unreadable tree: such an entry is never trusted.
    static func manifest(of dir: URL) -> [String: Int64]? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else {
            return nil
        }
        let base = dir.resolvingSymlinksInPath().path + "/"
        var sizes: [String: Int64] = [:]
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            if values.isSymbolicLink == true { return nil }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, let size = values.fileSize else { return nil }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(base) else { return nil }
            sizes[String(path.dropFirst(base.count))] = Int64(size)
        }
        return sizes.isEmpty ? nil : sizes
    }

    /// The root must be this user's real directory (created if missing).
    static func usableRoot(_ root: URL) -> Bool {
        try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        return lstat(root.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == geteuid()
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
