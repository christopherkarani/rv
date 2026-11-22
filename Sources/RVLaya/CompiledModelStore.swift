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
/// - Shared across processes: rvd, the CLI and both judge-pool workers use
///   one root. Verify, compile, install, sweep and discard run under an
///   exclusive `flock` on `<root>.lock` beside the root, so two workers
///   warming at once compile once and never remove each other's `.partial-`
///   copy or half-committed entry. A process that loaded an entry holds a
///   shared `flock` on its manifest (`CompiledModelLease`) for as long as
///   the model lives; the sweep skips a superseded entry someone still
///   holds and removes it on a later load.
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
    /// Longest wait for the store lock before the load refuses (review).
    var lockWait: Duration = Self.defaultLockWait

    /// Comfortably past a cold compile of the ~600 MB model by another
    /// loader (the lock's legitimate holder); a holder past it is stuck or
    /// hostile. The caller's own bounded wait (`loadWait`) already answers
    /// `judge-warming` while this runs.
    static var defaultLockWait: Duration { .seconds(120) }

    /// Poll interval while another process holds the store lock.
    static var lockPollInterval: Duration { .milliseconds(50) }

    /// Records each refusal on the guard (doctor shows the last one) and
    /// clears it on the next good load.
    func model(package: URL) throws -> Model {
        try leasedModel(package: package).model
    }

    /// The model and the lease that keeps its entry from being swept; keep
    /// the lease as long as the model.
    func leasedModel(package: URL) throws -> (model: Model, lease: CompiledModelLease) {
        do {
            let loaded = try loadRetryingOnce(package)
            coreML.noteRefusal(nil)
            return loaded
        } catch let refusal as any CoreMLRefusal {
            coreML.noteRefusal(refusal.reason)
            throw refusal
        }
    }

    private func loadRetryingOnce(_ package: URL) throws -> (model: Model, lease: CompiledModelLease) {
        do {
            return try attempt(package)
        } catch let refusal as any CoreMLRefusal {
            throw refusal
        } catch {
            coreML.log("rvd: judge model load failed; purging compiled-model caches and retrying once")
            // Our own lease died with the failed attempt. An entry another
            // loader still holds is kept (as the sweep does): the retry
            // reloads it, and a second failure refuses.
            if let entry = try? entry(for: package) {
                try? exclusively { if !CompiledModelLease.isHeld(entry.manifest) { discard(entry) } }
            }
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

    /// Verifies (or compiles and installs) and leases the entry under the
    /// store lock, then loads outside it: a slow or crashing Core ML load
    /// never holds up the other processes' verification.
    private func attempt(_ package: URL) throws -> (model: Model, lease: CompiledModelLease) {
        let entry = try entry(for: package)
        let lease = try exclusively { () throws -> CompiledModelLease in
            if !isVerified(entry) {
                if exists(entry) {
                    coreML.log("rvd: compiled judge model failed verification; recompiling from the bundle")
                    discard(entry)
                }
                let compiled = try coreML.run(checkingDisk: true) { try compile(package) }
                try install(compiled, as: entry)
                sweep(keeping: entry)
            }
            guard let lease = CompiledModelLease(manifest: entry.manifest) else {
                throw CompiledModelRefusal(detail: "could not hold the compiled model's manifest")
            }
            return lease
        }
        return (try coreML.run(checkingDisk: true) { try load(entry.dir) }, lease)
    }

    /// Runs `body` holding the store's exclusive lock, `<root>.lock` in the
    /// root's parent (outside the root, so the sweep never sees it). The
    /// lock file must be this user's regular file; anything else refuses.
    /// Waits while another process holds it (its compile, at worst), for at
    /// most `lockWait`: any process of this user can open the file and hold
    /// a lock on it, so past the wait the load refuses rather than block.
    private func exclusively<T>(_ body: () throws -> T) throws -> T {
        guard let root else { throw CompiledModelRefusal(detail: "no protected model cache directory") }
        let path = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + ".lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CompiledModelRefusal(detail: "could not open the model cache lock") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid() else {
            throw CompiledModelRefusal(detail: "the model cache lock is not this user's regular file")
        }
        try Self.lockExclusively(fd, within: lockWait)
        return try body()
    }

    /// `flock(LOCK_EX | LOCK_NB)` retried every `lockPollInterval` until
    /// `wait` runs out; then, or on any error but contention or EINTR,
    /// refuses.
    static func lockExclusively(_ fd: Int32, within wait: Duration) throws(CompiledModelRefusal) {
        let deadline = ContinuousClock.now + wait
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR else {
                throw CompiledModelRefusal(detail: "could not lock the model cache")
            }
            guard ContinuousClock.now < deadline else {
                throw CompiledModelRefusal(detail: "the model cache lock is held by another process")
            }
            Thread.sleep(forTimeInterval: Self.seconds(lockPollInterval))
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (whole, fraction) = duration.components
        return TimeInterval(whole) + TimeInterval(fraction) / 1e18
    }

    /// Refuses when there is no usable protected root: the compile output
    /// is never loaded from the temp dir it lands in.
    private func entry(for package: URL) throws(CompiledModelRefusal) -> Entry {
        guard let root else { throw CompiledModelRefusal(detail: "no protected model cache directory") }
        guard Self.usableRoot(root) else { throw CompiledModelRefusal(detail: Self.rootProblem(root)) }
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
        // Checked before the copy, not only after: off Darwin, FileManager
        // copies a FIFO by opening it for reading, which blocks forever.
        guard Self.holdsOnlyFilesAndDirectories(compiled) else {
            throw CompiledModelRefusal(detail: "compile output holds something other than files and directories")
        }
        guard (try? fm.copyItem(at: compiled, to: partial)) != nil else {
            throw CompiledModelRefusal(detail: "could not copy the compile output into the cache")
        }
        guard Self.restrictToOwner(partial) else {
            throw CompiledModelRefusal(
                detail: "could not make the cached copy owner-only (an entry could not be walked or chmod-ed, "
                    + "or is not a file or directory)")
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

    /// Removes this package's superseded entries and stale partial copies,
    /// under the store lock (so every partial copy is a dead process's). A
    /// superseded entry another process still has loaded (its manifest is
    /// leased) is kept. Other packages' entries and anything else in the
    /// root are kept.
    private func sweep(keeping entry: Entry) {
        guard let root, let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        let keep: Set<String> = [entry.dir.lastPathComponent, entry.manifest.lastPathComponent]
        for name in names where !keep.contains(name) {
            let dirName = name.hasSuffix(Self.manifestSuffix) ? String(name.dropLast(Self.manifestSuffix.count)) : name
            let ours = name.hasPrefix("\(entry.pathKey)-") && dirName.hasSuffix(".mlmodelc")
            let partial = name.hasPrefix(".\(entry.pathKey)-") && name.contains(Self.partialMarker)
            guard ours || partial else { continue }
            if ours, CompiledModelLease.isHeld(root.appendingPathComponent(dirName + Self.manifestSuffix)) { continue }
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
    /// file, a file with another hard link, a file not owned by this user,
    /// an unreadable file or directory (never skipped), or an empty tree:
    /// such an entry is never trusted. On the install path every file is
    /// the store's own fresh copy, so these checks fail only on a copy that
    /// could not be made cleanly; they matter when an installed entry is
    /// re-verified before a load, where a hard link or another user's file
    /// in the protected root means something other than the store put it
    /// there (and a hard-linked file could be rewritten through the link).
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

    /// The root must be this user's real directory, as must its parent, and
    /// owner-only: it is created 0700, and narrowed to 0700 through a
    /// no-follow descriptor if something made it wider, so the privacy of
    /// `.partial-` copies never depends on who created the root.
    static func usableRoot(_ root: URL) -> Bool {
        try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard isOwnedDirectory(root.deletingLastPathComponent()) else { return false }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid() else {
            return false
        }
        if info.st_mode & 0o077 != 0 {
            guard fchmod(fd, 0o700) == 0, fstat(fd, &info) == 0 else { return false }
        }
        return info.st_mode & 0o077 == 0
    }

    /// Why `usableRoot` refused, for the refusal doctor shows. A root that is
    /// this user's real directory but that its owner cannot open (mode 0000,
    /// say) never heals on its own, so the message names the fix.
    static func rootProblem(_ root: URL) -> String {
        var info = stat()
        if lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid(),
           info.st_mode & 0o700 != 0o700 {
            return "the model cache \(root.path) is not accessible to its owner (mode "
                + String(info.st_mode & 0o777, radix: 8)
                + "); the owner can restore it with `chmod 700 \(root.path)`"
        }
        return "\(root.path) is not this user's real directory"
    }

    /// Narrows the store's fresh copy to owner-only (directories 0700, files
    /// 0600) before it is hashed; false on anything that is not a directory
    /// or regular file, or a directory that cannot be walked.
    static func restrictToOwner(_ dir: URL) -> Bool {
        guard isOwnedDirectory(dir), chmod(dir.path, 0o700) == 0 else { return false }
        let walkFailed = WalkFailure()
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, _ in walkFailed.set(); return false })
        else { return false }
        for case let url as URL in walker {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return false }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: guard chmod(url.path, 0o700) == 0 else { return false }
            case S_IFREG: guard chmod(url.path, 0o600) == 0 else { return false }
            default: return false
            }
        }
        return !walkFailed.value
    }

    /// Whether every entry under `dir` is a directory or regular file, by
    /// `lstat` (nothing is opened, so a FIFO cannot block the walk); false
    /// on anything else or a directory that cannot be walked.
    static func holdsOnlyFilesAndDirectories(_ dir: URL) -> Bool {
        let walkFailed = WalkFailure()
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, _ in walkFailed.set(); return false })
        else { return false }
        for case let url as URL in walker {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return false }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG else { return false }
        }
        return !walkFailed.value
    }

    /// Whether the bundle's model package is there. Only ENOENT is absence
    /// (the packs-only floor); any other error refuses (review), so an error
    /// an agent can provoke never reads as "no model". The refusal is
    /// recorded on `coreML` so doctor shows it.
    static func packageExists(_ url: URL, recordingOn coreML: CoreMLGuard? = nil) throws(CoreMLLoadRefusal) -> Bool {
        try BundleFilePresence.exists(url, recordingOn: coreML)
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

/// A shared `flock` on an installed entry's manifest, held for as long as
/// the model loaded from it lives: the store's sweep skips a superseded
/// entry while anyone holds one. Taken only under the store lock, so a
/// sweep never races a new lease.
final class CompiledModelLease: Sendable {
    private let fd: Int32

    /// Nil when the manifest cannot be opened as this user's regular file
    /// or is being swept.
    init?(manifest: URL) {
        let fd = open(manifest.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(),
              flock(fd, LOCK_SH | LOCK_NB) == 0
        else {
            close(fd)
            return nil
        }
        self.fd = fd
    }

    deinit { close(fd) }

    /// Whether some process (this one included) holds a lease on
    /// `manifest`. A manifest that cannot be opened is not held.
    static func isHeld(_ manifest: URL) -> Bool {
        let fd = open(manifest.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return false }
        return errno == EWOULDBLOCK
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
