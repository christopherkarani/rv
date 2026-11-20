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
/// `MLModel.compileModel` writes into the per-user temp dir
/// (`confstr(_CS_DARWIN_USER_TEMP_DIR)`; `TMPDIR` does not move it, checked
/// on macOS 27), which any process of this user can write and macOS may
/// purge. The compiled `.mlmodelc` is copied into an rv-owned entry and only
/// ever loaded from there:
///
/// - Versioned: `<path key>-<version key>.mlmodelc`, where the version key
///   covers the package's modification time and the OS build, so an
///   updated bundle or OS compiles fresh. Superseded entries of the same
///   package are swept.
/// - Copied before it is read: the compile output must be this user's real
///   directory and is copied (an APFS clone: new inodes) into a `.partial-`
///   sibling under the root, hashed there, then renamed into place; the
///   manifest is written last and is the commit record. A descriptor held
///   open, or a hard link made, inside the temp output cannot reach the
///   copy. Residual: the output sits in the per-user temp dir for the whole
///   compile, so a same-user process that rewrites or replaces it before
///   the copy gets its model hashed and installed; an uncaged same-user
///   process can always reach it.
/// - Verified: the manifest records every file's size and SHA-256 and is
///   checked before every load. A missing or mismatched manifest (a crash
///   or full disk mid-install, or a planted or edited model) discards the
///   entry and recompiles from the bundle; a mismatched entry is never
///   loaded. A hard-linked file is refused (it could be rewritten through
///   the other link). (Hashing the ~600 MB model costs well under a second
///   against a multi-second load.)
/// - Fail closed: with no usable root, or when the output cannot be copied,
///   hashed or committed, the load throws `CompiledModelRefusal` (review);
///   the temp output is never loaded.
/// - Self-healing: a failed load discards the entry, purges Core ML's own
///   e5rt cache, and retries exactly once. A failure that survives the
///   retry throws `CoreMLLoadRefusal` (review), never the plain error the
///   gate would read as an unavailable judge (packs-only).
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
        } catch let refusal as any CoreMLRefusal {
            throw refusal
        } catch {
            coreML.log("rvd: judge model load failed; purging compiled-model caches and retrying once")
            if let entry = try? entry(for: package) { discard(entry) }
            coreML.purgeCache()
        }
        do {
            return try attempt(package)
        } catch let refusal as any CoreMLRefusal {
            throw refusal
        } catch {
            throw CoreMLLoadRefusal(detail: "\(error)")
        }
    }

    private struct Entry {
        let dir: URL
        let manifest: URL
        let pathKey: String
    }

    private func attempt(_ package: URL) throws -> Model {
        let entry = try entry(for: package)
        if isVerified(entry) {
            return try coreML.run(checkingDisk: true) { try load(entry.dir) }
        }
        if exists(entry) {
            coreML.log("rvd: compiled judge model failed verification; recompiling from the bundle")
            discard(entry)
        }
        let compiled = try coreML.run(checkingDisk: true) { try compile(package) }
        try install(compiled, as: entry)
        sweep(keeping: entry)
        return try coreML.run(checkingDisk: true) { try load(entry.dir) }
    }

    /// Refuses when there is no usable protected root: the compile output
    /// is never loaded from the temp dir it lands in.
    private func entry(for package: URL) throws(CompiledModelRefusal) -> Entry {
        guard let root else { throw CompiledModelRefusal(detail: "no protected model cache directory") }
        guard Self.usableRoot(root) else {
            throw CompiledModelRefusal(detail: "\(root.path) is not this user's real directory")
        }
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
        guard let recorded = Self.readManifest(entry.manifest),
              let actual = Self.manifest(of: entry.dir, digest: digest)
        else { return false }
        return recorded == actual
    }

    /// Core ML compiles into the temp dir, which agents can write. The output
    /// is checked (this user's real directory), copied into the protected
    /// root (an APFS clone, so new inodes nothing in the temp dir can
    /// write), hashed there, then committed under its entry name with the
    /// manifest. Any failure refuses. The temp output and the partial copy
    /// are removed on every path.
    private func install(_ compiled: URL, as entry: Entry) throws(CompiledModelRefusal) {
        let fm = FileManager.default
        let partial = entry.dir.deletingLastPathComponent()
            .appendingPathComponent(".\(entry.dir.lastPathComponent)\(Self.partialMarker)\(UUID().uuidString)")
        defer {
            // A refused symlink is removed itself, never its target.
            try? fm.removeItem(at: compiled)
            try? fm.removeItem(at: partial)
        }
        guard Self.isOwnedDirectory(compiled) else {
            throw CompiledModelRefusal(detail: "compile output is not this user's real directory")
        }
        guard (try? fm.copyItem(at: compiled, to: partial)) != nil else {
            throw CompiledModelRefusal(detail: "could not copy the compile output into the cache")
        }
        guard let manifest = Self.manifest(of: partial, digest: digest),
              let data = try? JSONEncoder().encode(manifest)
        else { throw CompiledModelRefusal(detail: "could not hash the compiled model") }
        guard rename(partial.path, entry.dir.path) == 0 else {
            // Another process committed this entry first: use it only verified.
            if isVerified(entry) { return }
            throw CompiledModelRefusal(detail: "could not commit the compiled model")
        }
        do {
            try data.write(to: entry.manifest, options: .atomic)
        } catch {
            discard(entry)
            throw CompiledModelRefusal(detail: "could not write the manifest")
        }
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

    /// Relative path → size and SHA-256 of every regular file. nil when the
    /// root is not this user's real directory, or on a symlink, a special
    /// file, a foreign file, a file with another hard link (it could be
    /// rewritten through that link after the hash), an unreadable file or
    /// directory (never skipped), or an empty tree: such an entry is never
    /// trusted.
    static func manifest(of dir: URL, digest: (URL) -> String?) -> [String: CompiledFileRecord]? {
        let walkFailed = WalkFailure()
        guard isOwnedDirectory(dir),
              let walker = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: nil, options: [],
                errorHandler: { _, _ in walkFailed.set(); return false })
        else { return nil }
        let base = dir.resolvingSymlinksInPath().path + "/"
        var records: [String: CompiledFileRecord] = [:]
        for case let url as URL in walker {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_uid == geteuid() else { return nil }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFDIR { continue }
            guard kind == S_IFREG, info.st_nlink == 1, let sha = digest(url) else { return nil }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(base) else { return nil }
            records[String(path.dropFirst(base.count))] = CompiledFileRecord(size: Int64(info.st_size), sha256: sha)
        }
        return records.isEmpty || walkFailed.value ? nil : records
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

/// Set by the directory walker's error handler: a directory it could not
/// read means the manifest does not cover the tree.
private final class WalkFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false
    func set() { lock.withLock { failed = true } }
    var value: Bool { lock.withLock { failed } }
}
