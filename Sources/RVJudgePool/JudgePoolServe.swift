#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

/// The supervisor's diagnostic log, `~/Library/Logs/rv/judge.log`.
///
/// launchd gives the agent stderr on /dev/null; the supervisor points it at
/// an owner-only file instead, and the workers inherit it, so a Core ML
/// assertion or LLVM abort in a worker lands here. Only fixed lifecycle
/// lines are written by rv code (spawn, ready, exit status, kill): never a
/// command or a verdict. Rotated once at startup past `maxBytes`.
public enum JudgePoolLog {
    public static let maxBytes = 1 << 20

    public static func path(home: String) -> String {
        #if os(macOS)
        home + "/Library/Logs/rv/judge.log"
        #else
        home + "/.local/state/rv/judge.log"
        #endif
    }

    /// Redirects stderr into the log when it is /dev/null. Returns whether
    /// it did.
    @discardableResult
    public static func captureDiscardedStderr(home: String) -> Bool {
        guard isDevNull(STDERR_FILENO) else { return false }
        let file = path(home: home)
        let directory = (file as NSString).deletingLastPathComponent
        guard mkdirAll(directory) else { return false }
        var info = stat()
        if lstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > maxBytes {
            _ = rename(file, file + ".1")
        }
        guard let fd = openLog(at: file) else { return false }
        defer { close(fd) }
        return dup2(fd, STDERR_FILENO) == STDERR_FILENO
    }

    /// Opens `path` for appending, only when it is (or is created as) a
    /// regular file the supervisor can write without blocking: never through
    /// a symlink, and never a FIFO or device someone planted there (an open
    /// of a FIFO with no reader would hang the supervisor at startup).
    static func openLog(at path: String) -> Int32? {
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            return nil
        }
        return fd
    }

    /// One timestamped line on stderr. Control characters become spaces so a
    /// message cannot forge another line.
    public static func line(_ message: String) {
        let clean = String(String.UnicodeScalarView(message.unicodeScalars.map {
            $0.properties.generalCategory == .control || $0 == "\u{2028}" || $0 == "\u{2029}" ? " " : $0
        }).prefix(512))
        let stamp = ISO8601DateFormatter().string(from: Date())
        write("\(stamp) rv-judge[\(getpid())] \(clean)\n", to: STDERR_FILENO)
    }

    /// One `write(2)`, errors ignored: a full disk or a closed stderr must
    /// not raise (FileHandle does) or stall the supervisor.
    static func write(_ text: String, to fd: Int32) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBytes { raw in
            #if canImport(Darwin)
            _ = Darwin.write(fd, raw.baseAddress, raw.count)
            #else
            _ = Glibc.write(fd, raw.baseAddress, raw.count)
            #endif
        }
    }

    private static func isDevNull(_ fd: Int32) -> Bool {
        var mine = stat()
        var null = stat()
        guard fstat(fd, &mine) == 0, stat("/dev/null", &null) == 0 else { return false }
        return mine.st_dev == null.st_dev && mine.st_ino == null.st_ino
    }

    private static func mkdirAll(_ directory: String) -> Bool {
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return true
        } catch {
            return false
        }
    }
}

/// The running executable's on-disk identity. An upgrade replaces the file;
/// a supervisor that notices exits so launchd (KeepAlive) restarts it from
/// the new bytes, and never spawns workers from bytes newer than itself.
public struct ExecutableIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modified: Int

    public init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        device = UInt64(info.st_dev)
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        #if canImport(Darwin)
        modified = info.st_mtimespec.tv_sec
        #else
        modified = info.st_mtim.tv_sec
        #endif
    }
}

/// Refuses to spawn from an executable that changed under the supervisor:
/// exits instead, for launchd to restart the supervisor on the new bytes.
struct UpgradeGuardedSpawner: WorkerSpawning {
    let base: any WorkerSpawning
    let executable: String
    let identity: ExecutableIdentity?
    let onUpgrade: @Sendable () -> Void

    func spawn(
        slot: WorkerSlot, key: ModelKey, output: @escaping @Sendable (WorkerOutput) -> Void
    ) throws -> any WorkerProcess {
        if ExecutableIdentity(path: executable) != identity { onUpgrade() }
        return try base.spawn(slot: slot, key: key, output: output)
    }
}

/// `rv-judge serve`: the `dev.rv.judge` launchd agent.
public enum JudgePoolServe {
    /// How often an idle supervisor checks for an upgraded executable.
    public static let upgradeCheckInterval: Duration = .seconds(30)

    /// Only these variables reach a worker; PATH is fixed.
    public static func workerEnvironment(_ environment: [String: String]) -> [String: String] {
        var out = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for name in ["HOME", "USER", "LOGNAME", "TMPDIR"] {
            if let value = environment[name], !value.isEmpty { out[name] = value }
        }
        return out
    }

    /// The canonical path of the running executable.
    public static func runningExecutable() -> String? {
        #if canImport(Darwin)
        var capacity = UInt32(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: Int(capacity))
        guard _NSGetExecutablePath(&buffer, &capacity) == 0 else { return nil }
        let raw = String(cString: buffer)
        #else
        guard let raw = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") else { return nil }
        #endif
        guard let resolved = realpath(raw, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public static func run() -> Never {
        #if canImport(XPC)
        signal(SIGPIPE, SIG_IGN)
        let environment = ProcessInfo.processInfo.environment
        guard let home = environment["HOME"], home.hasPrefix("/") else {
            FileHandle.standardError.write(Data("rv-judge serve: HOME is required, as an absolute path\n".utf8))
            exit(1)
        }
        JudgePoolLog.captureDiscardedStderr(home: home)
        guard let executable = runningExecutable() else {
            JudgePoolLog.line("cannot resolve own executable; exiting")
            exit(1)
        }
        let identity = ExecutableIdentity(path: executable)
        let upgraded: @Sendable () -> Void = {
            JudgePoolLog.line("executable changed on disk; exiting for launchd to restart the new one")
            exit(0)
        }
        let spawner = UpgradeGuardedSpawner(
            base: PosixWorkerSpawner(
                executable: executable,
                environment: workerEnvironment(environment),
                arguments: PosixWorkerSpawner.judgeWorkerArguments),
            executable: executable, identity: identity, onUpgrade: upgraded)
        let supervisor = JudgePoolSupervisor(spawner: spawner, log: JudgePoolLog.line)
        let siblingClient = ((executable as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("rvd")
        let listener = JudgePoolXPCListener(supervisor: supervisor) { message in
            JudgePoolTrust.authorizeClient(message: message, siblingClientPath: siblingClient)
        }
        listener.start()
        JudgePoolLog.line("serving \(JudgePoolWire.machServiceName) (protocol \(JudgePoolWire.protocolVersion))")
        let watch = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let interval = JudgePoolSupervisor.dispatchInterval(upgradeCheckInterval)
        watch.schedule(deadline: .now() + interval, repeating: interval)
        watch.setEventHandler {
            if ExecutableIdentity(path: executable) != identity {
                supervisor.stop()
                upgraded()
            }
        }
        watch.resume()
        withExtendedLifetime((listener, watch)) { dispatchMain() }
        #else
        FileHandle.standardError.write(Data("rv-judge serve: the judge pool needs Core ML (macOS); Linux runs packs-only\n".utf8))
        exit(1)
        #endif
    }
}
