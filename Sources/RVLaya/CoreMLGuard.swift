#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import Synchronization

/// Where the Core ML in-flight marker and crash history live.
public protocol CoreMLCrashStore: Sendable {
    /// True when the previous process left the in-flight marker set.
    func previousRunCrashed() -> Bool
    func setInFlight(_ inFlight: Bool)
    /// Missing or unreadable state reads as empty.
    func loadState() -> CoreMLCrashState
    func saveState(_ state: CoreMLCrashState)
}

/// Free space on a volume; nil when it cannot be read.
public protocol DiskSpaceProbe: Sendable {
    func availableBytes(at url: URL) -> Int64?
}

/// The judge refused to touch Core ML because the cache volume is nearly
/// full: compiling into the e5rt cache with no space aborts the process
/// (`LLVM ERROR: IO failure on output stream`). Callers fail closed to
/// review; this is never an unjudged allow.
public struct CoreMLDiskSpaceError: Error, Sendable, Equatable {
    public let availableBytes: Int64
    public let requiredBytes: Int64

    public init(availableBytes: Int64, requiredBytes: Int64) {
        self.availableBytes = availableBytes
        self.requiredBytes = requiredBytes
    }

    public var reason: String {
        let gib = { (bytes: Int64) in String(format: "%.1f GiB", Double(bytes) / Double(1 << 30)) }
        return "Laya judge: disk nearly full (\(gib(availableBytes)) free, needs \(gib(requiredBytes))); "
            + "judge disabled until space is freed."
    }
}

/// Guards every Core ML model load and prediction in a process.
///
/// - Crash awareness: around each call it sets an "in flight" marker and
///   clears it after. A marker still set at the next start means the last
///   process died inside Core ML; `CoreMLCrashPolicy` turns repeated deaths
///   into CPU-only loads. The marker is one byte written with `pwrite` on a
///   descriptor opened once: a few microseconds against a ~300 ms p50
///   prediction, so every prediction is covered (the MPSGraph aborts in the
///   field happened mid-session, not at load). No fsync: an abort keeps
///   the page cache; only a kernel panic loses the byte, and that is not a
///   Core ML crash.
/// - Disk precheck: refuses any call below `minimumFreeBytes` free on the
///   cache volume (one `statfs`/`statvfs`).
///
/// An untracked guard (no store) only does the disk precheck: short-lived
/// CLI processes share no marker with rvd, so they cannot miscount its runs.
public final class CoreMLGuard: Sendable {
    /// Below this much free space on the cache volume the judge refuses to
    /// load or predict (compiling the ~600 MB model writes the compiled
    /// copy plus Core ML's e5rt bundle).
    public static let minimumFreeBytes: Int64 = 2 << 30

    public struct Status: Sendable, Equatable {
        public let units: JudgeComputeUnits
        public let cpuOnlyUntil: Date?
        public let diskLow: Bool

        public init(units: JudgeComputeUnits, cpuOnlyUntil: Date?, diskLow: Bool) {
            self.units = units
            self.cpuOnlyUntil = cpuOnlyUntil
            self.diskLow = diskLow
        }
    }

    private struct Started {
        var units: JudgeComputeUnits
        var cpuOnlyUntil: Date?
        var store: (any CoreMLCrashStore)?
        var depth = 0
    }

    /// Opened on first Core ML use, so an rvd that never loads a judge
    /// never touches the cache directory.
    private let makeStore: @Sendable () -> (any CoreMLCrashStore)?
    private let disk: any DiskSpaceProbe
    private let cacheVolume: URL?
    private let purgeCoreMLCache: @Sendable () -> Void
    let log: @Sendable (String) -> Void
    private let now: @Sendable () -> Date
    private let started = Mutex<Started?>(nil)

    public convenience init(
        store: (any CoreMLCrashStore)?,
        disk: any DiskSpaceProbe,
        cacheVolume: URL?,
        purgeCoreMLCache: @escaping @Sendable () -> Void,
        log: @escaping @Sendable (String) -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            makeStore: { store }, disk: disk, cacheVolume: cacheVolume,
            purgeCoreMLCache: purgeCoreMLCache, log: log, now: now)
    }

    init(
        makeStore: @escaping @Sendable () -> (any CoreMLCrashStore)?,
        disk: any DiskSpaceProbe,
        cacheVolume: URL?,
        purgeCoreMLCache: @escaping @Sendable () -> Void,
        log: @escaping @Sendable (String) -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.makeStore = makeStore
        self.disk = disk
        self.cacheVolume = cacheVolume
        self.purgeCoreMLCache = purgeCoreMLCache
        self.log = log
        self.now = now
    }

    /// Compute units for the next model load (runs crash recovery once).
    public var computeUnits: JudgeComputeUnits {
        started.withLock { recover(&$0).units }
    }

    /// For doctor: the units in force, the CPU-only deadline, and whether
    /// the disk is below the floor right now.
    public var status: Status {
        let current = started.withLock { recover(&$0) }
        return Status(units: current.units, cpuOnlyUntil: current.cpuOnlyUntil, diskLow: diskShortfall() != nil)
    }

    /// Throws when the cache volume is below `minimumFreeBytes`. Unknown free
    /// space proceeds: the precheck only prevents a crash, it is not a gate.
    public func requireDiskSpace() throws(CoreMLDiskSpaceError) {
        if let shortfall = diskShortfall() { throw shortfall }
    }

    /// Runs one Core ML load, compile or prediction: disk precheck, then
    /// the body with the in-flight marker set.
    public func run<T>(_ body: () throws -> T) throws -> T {
        started.withLock { _ = recover(&$0) }
        try requireDiskSpace()
        enter()
        defer { leave() }
        return try body()
    }

    /// Purges Core ML's own compiled-bundle cache (corruption recovery).
    public func purgeCache() {
        purgeCoreMLCache()
    }

    private func diskShortfall() -> CoreMLDiskSpaceError? {
        guard let cacheVolume, let free = disk.availableBytes(at: cacheVolume),
              free < Self.minimumFreeBytes else { return nil }
        return CoreMLDiskSpaceError(availableBytes: free, requiredBytes: Self.minimumFreeBytes)
    }

    private func enter() {
        started.withLock {
            if $0?.depth == 0 { $0?.store?.setInFlight(true) }
            $0?.depth += 1
        }
    }

    private func leave() {
        started.withLock {
            $0?.depth -= 1
            if $0?.depth == 0 { $0?.store?.setInFlight(false) }
        }
    }

    /// First touch in this process: read the previous run's marker before
    /// any marker write of ours, apply the policy, persist, then clear.
    private func recover(_ slot: inout Started?) -> Started {
        if let slot { return slot }
        guard let store = makeStore() else {
            let fresh = Started(units: .cpuAndGPU)
            slot = fresh
            return fresh
        }
        let crashed = store.previousRunCrashed()
        let before = store.loadState()
        let next = CoreMLCrashPolicy.recover(before, previousRunCrashed: crashed, now: now())
        if next.state != before { store.saveState(next.state) }
        if crashed {
            log("rvd: the previous run died inside Core ML (\(next.state.crashes.count) in 24 h); purging its compiled-model cache")
            purgeCoreMLCache()
        }
        if next.units == .cpuOnly {
            let until = next.state.cpuOnlyUntil.map { $0.formatted(.iso8601) } ?? "later"
            log("rvd: judge loads CPU only (GPU/MPSGraph off) until \(until) after repeated Core ML crashes")
        }
        store.setInFlight(false)
        let fresh = Started(units: next.units, cpuOnlyUntil: next.state.cpuOnlyUntil, store: store)
        slot = fresh
        return fresh
    }
}

extension CoreMLGuard {
    private static let bound = Mutex<CoreMLGuard?>(nil)

    /// The guard judges use when none is injected. Untracked until rvd binds
    /// its daemon guard at startup.
    public static var current: CoreMLGuard {
        bound.withLock { slot in
            if let slot { return slot }
            let made = untracked()
            slot = made
            return made
        }
    }

    /// rvd binds `daemon(log:)` before its listeners start.
    public static func bind(_ guardian: CoreMLGuard) {
        bound.withLock { $0 = guardian }
    }

    /// Disk precheck only, on the user caches volume.
    public static func untracked() -> CoreMLGuard {
        CoreMLGuard(
            store: nil, disk: StatfsDiskSpace(), cacheVolume: cachesRoot(),
            purgeCoreMLCache: {}, log: { _ in })
    }

    /// rvd's guard: marker and history under `~/Library/Caches/rv-laya/
    /// coreml-guard`, cleared on orderly exit, plus purge of rvd's own e5rt
    /// cache. Nothing is opened until the first Core ML use. A store that
    /// cannot be opened degrades to untracked (logged): the judge still
    /// loads, only crash-awareness is lost.
    public static func daemon(log: @escaping @Sendable (String) -> Void) -> CoreMLGuard {
        let caches = cachesRoot()
        let processName = ProcessInfo.processInfo.processName
        return CoreMLGuard(
            makeStore: {
                let store = caches.flatMap {
                    FileCoreMLCrashStore(
                        directory: $0.appendingPathComponent("rv-laya/coreml-guard", isDirectory: true),
                        clearOnExit: true)
                }
                if store == nil { log("rvd: Core ML crash marker unavailable; judge runs without crash fallback") }
                return store
            },
            disk: StatfsDiskSpace(), cacheVolume: caches,
            purgeCoreMLCache: {
                guard let caches else { return }
                if !CoreMLCachePurge.purge(cachesRoot: caches, processName: processName) {
                    log("rvd: Core ML cache not purged (not rvd's own directory)")
                }
            },
            log: log)
    }

    /// `~/Library/Caches` (Linux: `~/.cache`).
    static func cachesRoot() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }
}

/// Free space for unprivileged writers (`f_bavail` blocks): `statfs` on
/// Darwin (64-bit block counts), POSIX `statvfs` elsewhere (Glibc does not
/// export `statfs` to Swift).
public struct StatfsDiskSpace: DiskSpaceProbe {
    public init() {}

    public func availableBytes(at url: URL) -> Int64? {
        #if canImport(Darwin)
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        let blockSize = Int64(info.f_bsize)
        #else
        var info = statvfs()
        guard statvfs(url.path, &info) == 0 else { return nil }
        let blockSize = Int64(info.f_frsize)
        #endif
        let blocks = Int64(clamping: UInt64(info.f_bavail))
        let (bytes, overflow) = blocks.multipliedReportingOverflow(by: blockSize)
        return overflow ? Int64.max : bytes
    }
}

/// Descriptor of the marker the exit handler clears; -1 when none.
private let exitMarkerFD = Atomic<Int32>(-1)

private func clearMarkerAtExit() {
    let fd = exitMarkerFD.load(ordering: .acquiring)
    guard fd >= 0 else { return }
    var zero = UInt8(ascii: "0")
    _ = pwrite(fd, &zero, 1, 0)
}

/// Marker byte plus JSON crash history in one owner-only directory.
///
/// The directory, the marker and the state file must be this user's, and
/// none may be a symlink (refused, so the store cannot be aimed at another
/// file). The state is replaced atomically (temp file + rename).
public final class FileCoreMLCrashStore: CoreMLCrashStore, Sendable {
    static let markerName = "coreml-in-flight"
    static let stateName = "coreml-crashes.json"

    private let fd: Int32
    private let stateURL: URL

    /// nil when the directory or marker is unusable. `clearOnExit` clears the
    /// marker in an `atexit` handler: an orderly `exit` while a prediction is
    /// running is not a Core ML crash. An abort or signal skips it.
    public init?(directory: URL, clearOnExit: Bool = false) {
        guard Self.prepare(directory) else { return nil }
        let marker = directory.appendingPathComponent(Self.markerName).path
        let fd = open(marker, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid() else {
            close(fd)
            return nil
        }
        self.fd = fd
        stateURL = directory.appendingPathComponent(Self.stateName)
        if clearOnExit {
            exitMarkerFD.store(fd, ordering: .releasing)
            Self.registerExitHandler()
        }
    }

    deinit {
        // The exit handler must never write into a reused descriptor.
        _ = exitMarkerFD.compareExchange(expected: fd, desired: -1, ordering: .acquiringAndReleasing)
        close(fd)
    }

    private static let exitHandler = Mutex(false)

    private static func registerExitHandler() {
        exitHandler.withLock { registered in
            guard !registered else { return }
            registered = true
            atexit { clearMarkerAtExit() }
        }
    }

    public func previousRunCrashed() -> Bool {
        var byte: UInt8 = 0
        return pread(fd, &byte, 1, 0) == 1 && byte == UInt8(ascii: "1")
    }

    public func setInFlight(_ inFlight: Bool) {
        var byte = UInt8(ascii: inFlight ? "1" : "0")
        _ = pwrite(fd, &byte, 1, 0)
    }

    public func loadState() -> CoreMLCrashState {
        var info = stat()
        guard lstat(stateURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_size < 64 << 10,
              let data = try? Data(contentsOf: stateURL),
              let state = try? Self.decoder.decode(CoreMLCrashState.self, from: data)
        else { return CoreMLCrashState() }
        return state
    }

    public func saveState(_ state: CoreMLCrashState) {
        guard let data = try? Self.encoder.encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    private static func prepare(_ directory: URL) -> Bool {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        return lstat(directory.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == geteuid()
    }
}

/// Purges Core ML's compiled-bundle cache for this process
/// (`<caches>/<process>/com.apple.e5rt.e5bundlecache`), where a crash or a
/// full disk leaves half-written bundles ("resources.bin missing",
/// "Original module missing").
public enum CoreMLCachePurge {
    /// Only rvd's own cache is ever removed.
    static let owners: Set<String> = ["rvd"]
    static let cacheName = "com.apple.e5rt.e5bundlecache"

    /// True when the cache is gone (or was never there). Refuses (false)
    /// any other process name and any path component that is a symlink or
    /// not this user's directory. The cache is renamed aside first, so a
    /// swap after the check renames the swapped-in entry itself (rename
    /// never follows a final symlink), and the removal does not follow links.
    @discardableResult
    public static func purge(cachesRoot: URL, processName: String) -> Bool {
        guard owners.contains(processName) else { return false }
        let owner = cachesRoot.appendingPathComponent(processName, isDirectory: true)
        let cache = owner.appendingPathComponent(cacheName, isDirectory: true)
        var info = stat()
        guard lstat(owner.path, &info) == 0 else { return errno == ENOENT }
        guard isOwnedDirectory(info) else { return false }
        guard lstat(cache.path, &info) == 0 else { return errno == ENOENT }
        guard isOwnedDirectory(info) else { return false }
        let aside = owner.appendingPathComponent(".\(cacheName).purge-\(UUID().uuidString)")
        guard rename(cache.path, aside.path) == 0 else { return false }
        guard lstat(aside.path, &info) == 0, isOwnedDirectory(info) else { return false }
        return (try? FileManager.default.removeItem(at: aside)) != nil
    }

    private static func isOwnedDirectory(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == geteuid()
    }
}
