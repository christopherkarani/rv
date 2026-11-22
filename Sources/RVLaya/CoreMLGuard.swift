#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import RVDomain
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

/// A judge load refused for a reason that must fail closed to review,
/// never to the packs-only floor (which allows).
public protocol CoreMLRefusal: Error, Sendable {
    var reason: String { get }
}

extension CoreMLDiskSpaceError: CoreMLRefusal {}

/// The compiled model could not be copied into, or verified inside, rv's
/// protected cache, so it is not loaded. Core ML compiles into the per-user
/// temp dir, which any process of this user can write; the store loads only
/// its own hashed copy, never the output where it lands. Residual: while
/// Core ML is compiling, a same-user process can rewrite the output before
/// rv copies it, and that is not detected.
public struct CompiledModelRefusal: CoreMLRefusal, Equatable {
    public let detail: String

    public init(detail: String) {
        self.detail = detail
    }

    public var reason: String {
        "Laya judge: compiled model not verified (\(detail)); judge disabled until it can be."
    }
}

/// Core ML could not compile or load the judge model even after the store's
/// one discard-and-retry. An agent can provoke that (a swapped compile
/// output, a poisoned e5rt cache), so it refuses to review like any other
/// refusal; only a bundle dir that is not there at all is packs-only.
public struct CoreMLLoadRefusal: CoreMLRefusal, Equatable {
    public let detail: String

    public init(detail: String) {
        self.detail = detail
    }

    public var reason: String {
        // Reaches the agent too: it sends the agent to the owner, never to a
        // repair (the installer, doctor's fixes) of its own.
        "Laya judge: Core ML could not compile or load the judge model (\(detail)); judged calls go to review "
            + "until the owner repairs the judge install. Ask the owner to run `rv doctor`."
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
///   Core ML crash. An orderly exit or SIGTERM/SIGINT clears it.
/// - Disk precheck: refuses a compile or load below `minimumFreeBytes`
///   free on the cache volume (one `statfs`/`statvfs`). Predictions on a
///   loaded model are not checked.
///
/// State (marker, crash history, compiled models) lives under `stateRoot`,
/// rv's guarded config dir, never in agent-writable caches.
///
/// An untracked guard (no store) keeps the disk precheck and the verified
/// model cache but writes no crash marker: short-lived
/// CLI processes share no marker with rvd, so they cannot miscount its runs.
public final class CoreMLGuard: Sendable {
    /// Below this much free space on the cache volume the judge refuses to
    /// compile or load (compiling the ~600 MB model writes the compiled
    /// copy plus Core ML's e5rt bundle).
    public static let minimumFreeBytes: Int64 = 2 << 30

    public struct Status: Sendable, Equatable {
        public let units: JudgeComputeUnits
        public let cpuOnlyUntil: Date?
        public let diskLow: Bool
        /// rvd's guard runs without its crash marker (another rvd holds it,
        /// or it could not be written): no CPU-only fallback after a crash.
        public let crashMarkerUnavailable: Bool
        /// The reason of the last judge load this guard refused; nil once a
        /// load succeeds.
        public let lastRefusal: String?
        /// The verified-model cache dir when it is this user's directory but
        /// its owner cannot use it (mode 0000, say): every load refuses until
        /// the owner restores it. Doctor names the fix; the refusal the agent
        /// sees does not.
        public let inaccessibleModelCache: String?

        public init(
            units: JudgeComputeUnits, cpuOnlyUntil: Date?, diskLow: Bool,
            crashMarkerUnavailable: Bool = false, lastRefusal: String? = nil,
            inaccessibleModelCache: String? = nil
        ) {
            self.units = units
            self.cpuOnlyUntil = cpuOnlyUntil
            self.diskLow = diskLow
            self.crashMarkerUnavailable = crashMarkerUnavailable
            self.lastRefusal = lastRefusal
            self.inaccessibleModelCache = inaccessibleModelCache
        }
    }

    private struct Started {
        var units: JudgeComputeUnits
        var cpuOnlyUntil: Date?
        var store: (any CoreMLCrashStore)?
        var depth = 0
    }

    /// `~/.config/rv/cache/laya`: `models/` and `guard/` below it.
    public let stateRoot: URL?
    /// rvd's guard: it is meant to hold the crash marker.
    private let tracksCrashes: Bool
    /// A CPU worker of the judge pool: loads CPU only whatever its crash
    /// history says (the history still drives `status`).
    private let cpuOnly: Bool
    /// Opened on first Core ML use, so an rvd that never loads a judge
    /// never touches the state directory.
    private let makeStore: @Sendable () -> (any CoreMLCrashStore)?
    private let disk: any DiskSpaceProbe
    private let cacheVolume: URL?
    private let purgeCoreMLCache: @Sendable () -> Void
    let log: @Sendable (String) -> Void
    private let now: @Sendable () -> Date
    private let started = Mutex<Started?>(nil)
    private let refusal = Mutex<String?>(nil)

    public convenience init(
        store: (any CoreMLCrashStore)?,
        disk: any DiskSpaceProbe,
        cacheVolume: URL?,
        stateRoot: URL? = nil,
        purgeCoreMLCache: @escaping @Sendable () -> Void,
        log: @escaping @Sendable (String) -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            makeStore: { store }, disk: disk, cacheVolume: cacheVolume, stateRoot: stateRoot,
            purgeCoreMLCache: purgeCoreMLCache, log: log, now: now)
    }

    init(
        makeStore: @escaping @Sendable () -> (any CoreMLCrashStore)?,
        disk: any DiskSpaceProbe,
        cacheVolume: URL?,
        stateRoot: URL? = nil,
        tracksCrashes: Bool = false,
        cpuOnly: Bool = false,
        purgeCoreMLCache: @escaping @Sendable () -> Void,
        log: @escaping @Sendable (String) -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.makeStore = makeStore
        self.disk = disk
        self.cacheVolume = cacheVolume
        self.stateRoot = stateRoot
        self.tracksCrashes = tracksCrashes
        self.cpuOnly = cpuOnly
        self.purgeCoreMLCache = purgeCoreMLCache
        self.log = log
        self.now = now
    }

    /// Where verified compiled models live; nil refuses every load.
    var modelRoot: URL? {
        stateRoot?.appendingPathComponent("models", isDirectory: true)
    }

    /// Compute units for the next model load (runs crash recovery once).
    public var computeUnits: JudgeComputeUnits {
        let units = startedState().units
        return cpuOnly ? .cpuOnly : units
    }

    /// For doctor: the units in force, the CPU-only deadline, and whether
    /// the disk is below the floor right now.
    public var status: Status {
        let current = startedState()
        return Status(
            units: current.units, cpuOnlyUntil: current.cpuOnlyUntil, diskLow: diskShortfall() != nil,
            crashMarkerUnavailable: tracksCrashes && current.store == nil,
            lastRefusal: refusal.withLock { $0 },
            inaccessibleModelCache: modelRoot.flatMap { root in
                CompiledModelStore<Never>.inaccessibleMode(root).map { _ in root.path }
            })
    }

    /// Records the last refused load (nil after a good one) for doctor.
    func noteRefusal(_ reason: String?) {
        refusal.withLock { $0 = reason }
    }

    /// Throws when the cache volume is below `minimumFreeBytes`. Unknown free
    /// space proceeds: the precheck only prevents a crash, it is not a gate.
    public func requireDiskSpace() throws(CoreMLDiskSpaceError) {
        if let shortfall = diskShortfall() { throw shortfall }
    }

    /// Runs one Core ML call with the in-flight marker set. A compile or
    /// load passes `checkingDisk` (they write the e5rt cache); a prediction
    /// on a loaded model does not.
    public func run<T>(checkingDisk: Bool = false, _ body: () throws -> T) throws -> T {
        _ = startedState()
        if checkingDisk { try requireDiskSpace() }
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

    /// The process's started state; the first caller runs recovery. The
    /// e5rt purge a crash calls for runs after the lock is released (it can
    /// take seconds); the cache is renamed aside first, so a load that
    /// starts meanwhile never sees a half-removed cache.
    private func startedState() -> Started {
        let (state, purge) = started.withLock { recover(&$0) }
        if purge { purgeCoreMLCache() }
        return state
    }

    /// First touch in this process: read the previous run's marker before
    /// any marker write of ours, apply the policy, persist, then clear.
    private func recover(_ slot: inout Started?) -> (Started, purge: Bool) {
        if let slot { return (slot, false) }
        guard let store = makeStore() else {
            let fresh = Started(units: .cpuAndGPU)
            slot = fresh
            return (fresh, false)
        }
        let crashed = store.previousRunCrashed()
        let before = store.loadState()
        let next = CoreMLCrashPolicy.recover(before, previousRunCrashed: crashed, now: now())
        if next.state != before { store.saveState(next.state) }
        if crashed {
            log("rvd: the previous run died inside Core ML (\(next.state.crashes.count) in 24 h); purging its compiled-model cache")
        }
        if next.units == .cpuOnly {
            let until = next.state.cpuOnlyUntil.map { $0.formatted(.iso8601) } ?? "later"
            log("rvd: judge loads CPU only (GPU/MPSGraph off) until \(until) after repeated Core ML crashes")
        }
        store.setInFlight(false)
        let fresh = Started(units: next.units, cpuOnlyUntil: next.state.cpuOnlyUntil, store: store)
        slot = fresh
        return (fresh, crashed)
    }
}

extension CoreMLGuard {
    private static let bound = Mutex<CoreMLGuard?>(nil)

    /// The guard judges use when none is injected: the bound one, else an
    /// untracked guard over the protected cache of this process's HOME.
    public static var current: CoreMLGuard {
        current(orBind: untracked(stateRoot: processStateRoot()))
    }

    /// `<config dir>/cache/laya`, below rv's config dir
    /// (`core.secrets:home-rv-config` denies agents there).
    public static func stateRoot(configDirectory: URL) -> URL {
        configDirectory
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("laya", isDirectory: true)
    }

    /// `$HOME/.config/rv/cache/laya` for an absolute, NUL-free HOME (the
    /// same rule as `HomeDirectory.processConfigDirectory()`); nil
    /// otherwise, and then every judge load refuses.
    static func processStateRoot() -> URL? {
        guard let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/"), !home.contains("\0")
        else { return nil }
        let config = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("rv", isDirectory: true)
        return stateRoot(configDirectory: config)
    }

    /// The bound guard, binding `make()` first when none is.
    public static func current(orBind make: @autoclosure () -> CoreMLGuard) -> CoreMLGuard {
        bound.withLock { slot in
            if let slot { return slot }
            let made = make()
            slot = made
            return made
        }
    }

    /// rvd binds `daemon(stateRoot:log:)` before its listeners start.
    public static func bind(_ guardian: CoreMLGuard) {
        bound.withLock { $0 = guardian }
    }

    /// Disk precheck and the verified compiled-model cache under
    /// `stateRoot`; no crash marker.
    public static func untracked(stateRoot: URL?) -> CoreMLGuard {
        CoreMLGuard(
            store: nil, disk: StatfsDiskSpace(), cacheVolume: cachesRoot(), stateRoot: stateRoot,
            purgeCoreMLCache: {}, log: { _ in })
    }

    /// rvd's guard: marker and history under `<stateRoot>/guard` (cleared on
    /// orderly exit and SIGTERM/SIGINT), compiled models under
    /// `<stateRoot>/models`, plus purge of rvd's own e5rt cache. Nothing is
    /// opened until the first Core ML use. A store that cannot be opened (or
    /// that another rvd holds) degrades to untracked, logged: the judge still
    /// loads, only crash-awareness is lost.
    public static func daemon(stateRoot: URL?, log: @escaping @Sendable (String) -> Void) -> CoreMLGuard {
        let caches = cachesRoot()
        let processName = ProcessInfo.processInfo.processName
        return CoreMLGuard(
            makeStore: {
                let store = stateRoot.flatMap {
                    FileCoreMLCrashStore(
                        directory: $0.appendingPathComponent("guard", isDirectory: true),
                        clearOnExit: true)
                }
                if store == nil { log("rvd: Core ML crash marker unavailable or held by another rvd; judge runs without crash fallback") }
                return store
            },
            disk: StatfsDiskSpace(), cacheVolume: caches, stateRoot: stateRoot, tracksCrashes: true,
            purgeCoreMLCache: {
                guard let caches else { return }
                if !CoreMLCachePurge.purge(cachesRoot: caches, processName: processName) {
                    log("rvd: Core ML cache not purged (not rvd's own directory)")
                }
            },
            log: log)
    }

    /// A judge-pool worker's guard (docs/architecture/judge-pool.md): its
    /// own marker and crash history in `<stateRoot>/guard-<worker>`, so one
    /// worker's crashes drive only its own compute units, never rvd's or
    /// the other worker's. `cpuOnly` pins the CPU worker to CPU whatever
    /// the history says. Compiled models are shared under
    /// `<stateRoot>/models`. A marker another process holds degrades to
    /// untracked, logged, as for rvd.
    public static func worker(
        stateRoot: URL?, worker: String, cpuOnly: Bool, log: @escaping @Sendable (String) -> Void
    ) -> CoreMLGuard {
        let caches = cachesRoot()
        let processName = ProcessInfo.processInfo.processName
        return CoreMLGuard(
            makeStore: {
                let store = stateRoot.flatMap {
                    FileCoreMLCrashStore(directory: workerMarkerDirectory(stateRoot: $0, worker: worker), clearOnExit: true)
                }
                if store == nil { log("judge worker \(worker): Core ML crash marker unavailable or held by another process; no crash fallback") }
                return store
            },
            disk: StatfsDiskSpace(), cacheVolume: caches, stateRoot: stateRoot, tracksCrashes: true,
            cpuOnly: cpuOnly,
            purgeCoreMLCache: {
                guard let caches else { return }
                if !CoreMLCachePurge.purge(cachesRoot: caches, processName: processName) {
                    log("judge worker \(worker): Core ML cache not purged (not rv's own directory)")
                }
            },
            log: log)
    }

    /// `<stateRoot>/guard-<worker>`: one judge-pool worker's crash marker.
    public static func workerMarkerDirectory(stateRoot: URL, worker: String) -> URL {
        stateRoot.appendingPathComponent("guard-\(worker)", isDirectory: true)
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

/// Descriptor of the marker the exit and signal handlers clear; -1 when none.
private let exitMarkerFD = Atomic<Int32>(-1)

/// Async-signal-safe: one lock-free atomic load and one `pwrite`.
private func clearMarkerAtExit() {
    let fd = exitMarkerFD.load(ordering: .acquiring)
    guard fd >= 0 else { return }
    var zero = UInt8(ascii: "0")
    _ = pwrite(fd, &zero, 1, 0)
}

/// SIGTERM/SIGINT: clear the marker, restore the default action and
/// re-raise, so the process still dies of the signal (launchd sees the same
/// exit status). Only async-signal-safe calls (`pwrite`, `signal`, `raise`).
private let clearMarkerAndReraise: @convention(c) (Int32) -> Void = { signo in
    clearMarkerAtExit()
    signal(signo, SIG_DFL)
    raise(signo)
}

/// Marker byte plus JSON crash history in one owner-only directory.
///
/// The directory, the marker and the state file must be this user's, and
/// none may be a symlink (refused, so the store cannot be aimed at another
/// file). The state is replaced atomically (temp file + rename). The marker
/// is held under an exclusive `flock`: a second process gets no store (it
/// runs untracked) and can neither read our marker as its own crash nor
/// clear it under us. The lock dies with the process, so no pid is needed.
public final class FileCoreMLCrashStore: CoreMLCrashStore, Sendable {
    static let markerName = "coreml-in-flight"
    static let stateName = "coreml-crashes.json"

    private let fd: Int32
    private let stateURL: URL

    /// nil when the directory or marker is unusable or another process holds
    /// the marker. `clearOnExit` clears the marker on orderly `exit` and on
    /// SIGTERM/SIGINT: neither is a Core ML crash. An abort still leaves it.
    public init?(directory: URL, clearOnExit: Bool = false) {
        guard Self.prepare(directory) else { return nil }
        let marker = directory.appendingPathComponent(Self.markerName).path
        let fd = open(marker, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(),
              flock(fd, LOCK_EX | LOCK_NB) == 0
        else {
            close(fd)
            return nil
        }
        self.fd = fd
        stateURL = directory.appendingPathComponent(Self.stateName)
        if clearOnExit {
            exitMarkerFD.store(fd, ordering: .releasing)
            Self.registerExitHandlers()
        }
    }

    deinit {
        // The handlers must never write into a reused descriptor.
        _ = exitMarkerFD.compareExchange(expected: fd, desired: -1, ordering: .acquiringAndReleasing)
        close(fd)
    }

    private static let exitHandlers = Mutex(false)

    private static func registerExitHandlers() {
        exitHandlers.withLock { registered in
            guard !registered else { return }
            registered = true
            atexit { clearMarkerAtExit() }
            for signo in [SIGTERM, SIGINT] { installClearingHandler(signo) }
        }
    }

    /// Installs the clearing handler only over the default action: a
    /// signal the process ignores or already handles is left as it was.
    static func installClearingHandler(_ signo: Int32) {
        let previous = signal(signo, clearMarkerAndReraise)
        let raw = unsafeBitCast(previous, to: Int.self)
        if raw != 0, raw != -1 { signal(signo, previous) }
    }

    /// Clears the in-flight marker in `directory` that a process no longer
    /// running left set: the judge-pool supervisor calls it after reaping a
    /// worker it SIGKILLed itself (a budget overrun is not a Core ML crash).
    /// Only this user's regular marker, never through a symlink, and only
    /// when no process holds its lock (a replacement worker that already
    /// started keeps its own state). False when nothing was cleared, which
    /// counts the kill as a crash: the safe direction (CPU only is slower,
    /// never weaker).
    @discardableResult
    public static func clearStaleMarker(directory: URL) -> Bool {
        let marker = directory.appendingPathComponent(markerName).path
        let fd = open(marker, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(),
              flock(fd, LOCK_EX | LOCK_NB) == 0
        else { return false }
        var zero = UInt8(ascii: "0")
        return pwrite(fd, &zero, 1, 0) == 1
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
    /// Only rv's own caches are ever removed: rvd's, and the judge-pool
    /// workers' (`rv-judge`).
    static let owners = Set(RVWiringPaths.coreMLCacheOwners)
    static let cacheName = "com.apple.e5rt.e5bundlecache"

    /// True when the cache is gone (or was never there). Refuses (false)
    /// any other process name and a directory that is not this user's. A
    /// symlink or file planted at `<caches>/rvd` or at the cache itself is
    /// unlinked (never followed: its target is untouched). The cache is
    /// renamed aside first, so a swap after the check renames the
    /// swapped-in entry itself (rename never follows a final symlink), and
    /// the removal does not follow links.
    @discardableResult
    public static func purge(cachesRoot: URL, processName: String) -> Bool {
        guard owners.contains(processName) else { return false }
        let owner = cachesRoot.appendingPathComponent(processName, isDirectory: true)
        let cache = owner.appendingPathComponent(cacheName, isDirectory: true)
        var info = stat()
        guard lstat(owner.path, &info) == 0 else { return errno == ENOENT }
        if !isDirectory(info) { return unlinkPlanted(owner.path) }
        guard isOwnedDirectory(info) else { return false }
        guard lstat(cache.path, &info) == 0 else { return errno == ENOENT }
        if !isDirectory(info) { return unlinkPlanted(cache.path) }
        guard isOwnedDirectory(info) else { return false }
        let aside = owner.appendingPathComponent(".\(cacheName).purge-\(UUID().uuidString)")
        guard rename(cache.path, aside.path) == 0 else { return false }
        guard lstat(aside.path, &info) == 0, isOwnedDirectory(info) else { return false }
        return (try? FileManager.default.removeItem(at: aside)) != nil
    }

    private static func isDirectory(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func isOwnedDirectory(_ info: stat) -> Bool {
        isDirectory(info) && info.st_uid == geteuid()
    }

    /// unlink(2) removes a symlink itself, never its target, and fails on a
    /// directory swapped in after the lstat, so a race only refuses.
    private static func unlinkPlanted(_ path: String) -> Bool {
        unlink(path) == 0 || errno == ENOENT
    }
}
