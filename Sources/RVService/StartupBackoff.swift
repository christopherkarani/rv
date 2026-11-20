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
/// that finds `running` knows the previous run died early. The delay happens
/// before rvd listens; once it serves, nothing here refuses a request.
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
    }

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
    /// Only decides whether a doomed start pauses before exiting; it never
    /// changes what rvd allows.
    public static func isSupervised(environment: [String: String]) -> Bool {
        if let label = environment["XPC_SERVICE_NAME"], label == RVService.machServiceName {
            return true
        }
        return environment["INVOCATION_ID"]?.isEmpty == false
    }
}

/// The record beside rvd's log, in rv's owner-only log directory.
public struct StartupBackoffStore: Sendable {
    public let path: String
    static let maxBytes = 4096

    public init(path: String) {
        self.path = path
    }

    public static func live(home: String) -> StartupBackoffStore {
        let directory = (RVDLogFile.path(home: home) as NSString).deletingLastPathComponent
        return StartupBackoffStore(path: directory + "/rvd-starts.json")
    }

    /// Nil when absent, not a small regular file of this user, or not a
    /// record: rvd then starts without backoff.
    public func load() -> StartupBackoff.Record? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(),
            Int(info.st_size) <= Self.maxBytes,
            let data = FileManager.default.contents(atPath: path)
        else { return nil }
        return try? JSONDecoder().decode(StartupBackoff.Record.self, from: data)
    }

    /// Forgets the early exits: setup and the service restart/start
    /// commands call this, so the operator's own restart never waits.
    public func reset() {
        unlink(path)
    }

    /// Best effort: a record that cannot be written only loses the backoff.
    /// Written to a temp file and renamed, so a crash never leaves half a
    /// record; the directory is created owner-only like the log's.
    public func save(_ record: StartupBackoff.Record) {
        let directory = (path as NSString).deletingLastPathComponent
        guard (try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil,
            let data = try? JSONEncoder().encode(record)
        else { return }
        let temp = path + ".\(getpid()).tmp"
        let fd = open(temp, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == data.count, rename(temp, path) == 0 else {
            unlink(temp)
            return
        }
    }
}
