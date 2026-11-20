#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// rvd's own crash-loop brake.
///
/// launchd (KeepAlive) and systemd (Restart=always) relaunch rvd after every
/// exit, at most once per throttle interval. A failure that repeats on every
/// start (a refused `~/.config`, a Core ML abort while prewarming the judge
/// from a corrupt cache) would then spawn rvd thousands of times a day. rvd
/// counts its own early exits and waits longer before each restart.
///
/// A run is early when it never reached `survivalWindow`: each start writes
/// `running`, and a run that stays up that long writes `survived`. A start
/// that finds `running` knows the previous run died early. rvd binds its
/// listeners before the delay and accepts after it, so a hook meanwhile sees
/// a slow rvd (ask/deny), never an absent one; once it serves, nothing here
/// refuses a request. Only a supervised rvd (`isSupervised`) keeps a record
/// or waits: one started by hand, by the SDK or by `rv` itself never does.
public enum StartupBackoff {
    /// A run that stays up this long resets the count.
    public static let survivalWindow: Duration = .seconds(30)
    public static let firstDelay: Duration = .seconds(5)
    public static let maxDelay: Duration = .seconds(300)
    /// Early exits after which the judge is no longer prewarmed at startup
    /// (it still loads on the first judged request).
    public static let skipPrewarmAfter = 2
    /// How long a supervised rvd waits before exiting on a configuration
    /// error that will fail the same way on the next start.
    public static let configErrorPause: Duration = .seconds(60)

    public struct Record: Codable, Equatable, Sendable {
        /// Consecutive runs that ended inside `survivalWindow`.
        public var earlyExits: Int
        /// True from start until the run survives `survivalWindow`.
        public var running: Bool

        public init(earlyExits: Int, running: Bool) {
            self.earlyExits = earlyExits
            self.running = running
        }

        public static let survived = Record(earlyExits: 0, running: false)
    }

    public struct Plan: Equatable, Sendable {
        public var delay: Duration
        public var prewarmJudge: Bool
        /// What to persist before serving.
        public var record: Record
        /// False for an unsupervised rvd: no record is read or written.
        public var tracked: Bool = true
    }

    /// An unsupervised rvd: no wait, prewarm, no record.
    public static let untracked = Plan(delay: .zero, prewarmJudge: true, record: .survived, tracked: false)

    /// Pure: what this start does, given the record the last start left.
    /// No record (first start, unreadable file) means no backoff.
    public static func plan(previous: Record?) -> Plan {
        let early: Int
        if let previous, previous.running {
            // Clamped: a forged count cannot push the delay past `maxDelay`
            // or overflow.
            early = min(max(previous.earlyExits, 0), 64) + 1
        } else {
            early = 0
        }
        return Plan(
            delay: delay(earlyExits: early),
            prewarmJudge: early < skipPrewarmAfter,
            record: Record(earlyExits: early, running: true)
        )
    }

    /// 0 and 1 early exits: none (one early exit is an ordinary restart or
    /// upgrade). Then 5 s, doubling, capped at `maxDelay`.
    static func delay(earlyExits: Int) -> Duration {
        guard earlyExits >= 2 else { return .zero }
        let doublings = min(earlyExits - 2, 16)
        let delay = firstDelay * (1 << doublings)
        return min(delay, maxDelay)
    }

    /// True when a service manager started this rvd (launchd sets
    /// `XPC_SERVICE_NAME` to the job label; systemd sets `INVOCATION_ID`).
    /// Decides whether rvd keeps a backoff record and waits, and whether a
    /// doomed start pauses before exiting; it never changes what rvd allows.
    public static func isSupervised(environment: [String: String]) -> Bool {
        if let label = environment["XPC_SERVICE_NAME"], label == RVService.machServiceName {
            return true
        }
        return environment["INVOCATION_ID"]?.isEmpty == false
    }
}

/// The record in its own owner-only directory beside rvd's log
/// (`directoryName`). The directory is an `RVWiringPaths` entry: a planted
/// record would hold rvd in its wait, so agents may not write there.
public struct StartupBackoffStore: Sendable {
    public let path: String
    static let maxBytes = 4096
    public static let directoryName = "rvd-backoff"
    public static let fileName = "rvd-starts.json"

    public init(path: String) {
        self.path = path
    }

    public static func live(home: String) -> StartupBackoffStore {
        let logs = (RVDLogFile.path(home: home) as NSString).deletingLastPathComponent
        return StartupBackoffStore(path: logs + "/" + directoryName + "/" + fileName)
    }

    /// Nil when absent, not a small regular file of this user, or not a
    /// record: rvd then starts without backoff. Opened without following a
    /// symlink and without blocking, so a FIFO swapped in cannot hang rvd.
    public func load() -> StartupBackoff.Record? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(),
            Int(info.st_size) <= Self.maxBytes
        else { return nil }
        var buffer = [UInt8](repeating: 0, count: Self.maxBytes + 1)
        let count = read(fd, &buffer, buffer.count)
        guard count >= 0, count <= Self.maxBytes else { return nil }
        return try? JSONDecoder().decode(StartupBackoff.Record.self, from: Data(buffer[0..<count]))
    }

    /// Forgets the early exits: setup and the service restart/start
    /// commands call this, so the operator's own restart never waits.
    public func reset() {
        unlink(path)
    }

    /// Best effort: a record that cannot be written only loses the backoff.
    /// Written to a fresh `mkstemp` file (never an existing one, so a FIFO
    /// or symlink planted at a guessable name cannot hang or redirect it)
    /// and renamed, so a crash never leaves half a record. The directory is
    /// created owner-only like the log's.
    public func save(_ record: StartupBackoff.Record) {
        let directory = (path as NSString).deletingLastPathComponent
        guard (try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil,
            let data = try? JSONEncoder().encode(record)
        else { return }
        var template = Array((path + ".XXXXXX.tmp").utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { mkstemps($0.baseAddress!, 4) }
        guard fd >= 0 else { return }
        let temp = String(cString: template)
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == data.count, rename(temp, path) == 0 else {
            unlink(temp)
            return
        }
    }
}
