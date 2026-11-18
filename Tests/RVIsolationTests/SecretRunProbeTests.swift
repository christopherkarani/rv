#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
@testable import RVIsolation

/// `rv run`'s signal guard with real dispositions and real signals, in
/// `rv-run-probe`: the guard changes process-wide dispositions, so in this
/// process every child another suite spawned meanwhile would inherit the
/// signals rv ignores. No test in this process installs a guard; they all
/// use detached ones.
@Suite("SecretRun signals out of process")
struct SecretRunProbeTests {
    /// Every guard shares one installation, which the last one out
    /// restores whichever order they leave in; a real SIGINT reaches every
    /// guard; SIGCHLD is default meanwhile; what rv inherited ignored
    /// (SIGHUP, SIGPIPE) is reported, and what it ignores itself is not.
    @Test(.timeLimit(.minutes(1)))
    func signalGuardsShareOneInstallationThatTheLastOutRestores() throws {
        let directory = try probeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("log")
        let probe = try spawnProbe(["guards"], environment: [], log: log)
        let status = waitBounded(probe, killing: [])
        expectNoFailures(log)
        #expect(status.flatMap(exitCode) == 0, "\(probeOutput(log))")
    }

    /// The production path, real handlers and a live command: a SIGTERM
    /// sent to rv alone ends the command's group, rv exits 143 (rather than
    /// dying of the SIGTERM), the gateway
    /// is gone and rv's dispositions are back. Under `nohup` and a parent
    /// that ignores SIGPIPE, the command keeps both ignored and gets the
    /// default for every signal rv ignores itself.
    @Test(.enabled(if: hostRunsSecretRun), .timeLimit(.minutes(1)))
    func aSignalToRvReachesTheCommandAndTheRunIsUndone() throws {
        let directory = try probeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let config = home.appendingPathComponent(".config/rv", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let secrets = SecretsConfiguration.fileURL(configDirectory: config)
        try Data(probeSecrets.utf8).write(to: secrets)
        #expect(chmod(secrets.path, 0o600) == 0)
        let fifo = directory.appendingPathComponent("fifo").path
        #expect(mkfifo(fifo, 0o600) == 0)
        // Blocks opening the fifo, which nothing ever writes: only a signal ends it.
        let script = """
            echo "$OPENAI_BASE_URL" > "$1/url"; echo $$ > "$1/pid.tmp"; mv "$1/pid.tmp" "$1/pid"
            read line < "$1/fifo"; exit 0
            """
        let log = directory.appendingPathComponent("log")
        let probe = try spawnProbe(
            ["run", directory.path, "/bin/sh", "-c", script, "sh", directory.path],
            environment: [
                "HOME=\(home.path)", "TMPDIR=\(FileManager.default.temporaryDirectory.path)", "PATH=/usr/bin:/bin",
                "FAKE_OPENAI=sk-live-PROBE-0123456789",
            ],
            log: log)
        let marker = directory.appendingPathComponent("pid").path
        let command = waitForMarker(marker, while: probe)
        guard command > 1 else {
            Issue.record("the command never ran: \(probeOutput(log))")
            _ = kill(-probe, SIGKILL)
            _ = waitBounded(probe, killing: [])
            // The command may have started after all, too late for the marker.
            endLeftover(pid_t(markerText(marker)) ?? 0)
            expectNoFailures(log)
            return
        }

        // Nothing below throws before the probe is signalled and reaped.
        let commandMasks = signalMasks(of: command)
        #expect(commandMasks != nil)
        if let ignored = commandMasks?.ignored {
            for number in [SIGHUP, SIGPIPE] { #expect(ignores(ignored, number)) }
            for number in [SIGINT, SIGQUIT, SIGTERM, SIGTTOU] { #expect(ignores(ignored, number) == false) }
        }
        // rv itself while it supervises. The probe has a SIGCHLD handler of
        // its own, set aside meanwhile (the kernel lists a default SIGCHLD
        // as ignored, so only "not caught" can be read).
        let rvMasks = signalMasks(of: probe)
        #expect(rvMasks != nil)
        if let rv = rvMasks {
            for number in [SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGTTOU] { #expect(ignores(rv.ignored, number)) }
            #expect(ignores(rv.caught, SIGCHLD) == false)
        }

        #expect(kill(probe, SIGTERM) == 0)
        let status = waitBounded(probe, killing: [command])
        // Read before the cleanup below ends a group rv left behind.
        let commandGone = kill(-command, 0) == -1 && errno == ESRCH
        endLeftover(command)
        expectNoFailures(log)
        // rv exits 143 itself; a SIGTERM that killed it is a missing guard.
        #expect(
            status.flatMap(exitCode) == 128 + SIGTERM,
            "wait status \(String(describing: status)): \(probeOutput(log))")
        #expect(commandGone)
    }
}

/// Whether the real spawn and kernel peer check work here, as for the
/// in-process launches in `SecretRunTests`.
private let hostRunsSecretRun = SecretRunCapability.check(.runtime) == nil

/// The exit code in a raw wait status; nil if a signal ended the process
/// (or it is stopped).
private func exitCode(_ status: Int32) -> Int32? {
    status & 0x7f == 0 ? (status >> 8) & 0xff : nil
}

/// Kills the command's group if rv left it behind (blocked on the fifo,
/// nothing else would end it). Called once the probe is reaped. While any
/// member lives the kernel hands out no pid equal to the group id, and pids
/// are handed out in sequence, so the id is not someone else's this soon.
private func endLeftover(_ command: pid_t) {
    guard command > 1, kill(-command, 0) == 0 else { return }
    Issue.record("the command's group outlived rv")
    _ = kill(-command, SIGKILL)
}

private let probeSecrets = """
    {"version":1,"secrets":[
      {"name":"OPENAI_API_KEY","source":{"hostEnvironment":{"variable":"FAKE_OPENAI"}},
       "delivery":{"gateway":{"upstream":"https://api.example.com/v1","baseURLEnv":"OPENAI_BASE_URL",
                              "placeholderPrefix":"sk-"}}}
    ]}
    """

private func probeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-run-probe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private struct MissingRunProbe: Error {}

/// The probe built with this test bundle (beside it) first, so a probe left
/// in another configuration's directory never stands in for it.
private func builtRunProbe() throws -> URL {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    var candidates = [
        Bundle(for: ProbeExit.self).bundleURL.deletingLastPathComponent().appendingPathComponent("rv-run-probe")
    ]
    var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    for _ in 0..<8 {
        candidates.append(directory.appendingPathComponent("rv-run-probe"))
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { break }
        directory = parent
    }
    candidates += [
        root.appendingPathComponent(".build/out/Products/Debug/rv-run-probe"),
        root.appendingPathComponent(".build/debug/rv-run-probe"),
        root.appendingPathComponent(".build/arm64-apple-macosx/debug/rv-run-probe"),
    ]
    if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
        return found
    }
    Issue.record("missing built product rv-run-probe")
    throw MissingRunProbe()
}

private struct ProbeSpawnFailed: Error {}

/// Starts the probe in a session of its own (so it has no controlling
/// terminal, and rv takes none), every signal at its default, stdin
/// `/dev/null`, stdout and stderr to `log`.
private func spawnProbe(_ arguments: [String], environment: [String], log: URL) throws -> pid_t {
    let executable = try builtRunProbe().path
    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else { throw ProbeSpawnFailed() }
    defer { posix_spawnattr_destroy(&attributes) }
    var noMask = sigset_t()
    sigemptyset(&noMask)
    var everySignal = sigset_t()
    sigfillset(&everySignal)
    let flags = Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
    guard posix_spawnattr_setflags(&attributes, flags) == 0,
        posix_spawnattr_setsigmask(&attributes, &noMask) == 0,
        posix_spawnattr_setsigdefault(&attributes, &everySignal) == 0
    else { throw ProbeSpawnFailed() }
    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { throw ProbeSpawnFailed() }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, log.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600) == 0,
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO) == 0
    else { throw ProbeSpawnFailed() }
    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    let envp = environment.map { strdup($0) } + [nil]
    defer { (argv + envp).forEach { free($0) } }
    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
    guard spawned == 0, pid > 1 else {
        Issue.record("could not start rv-run-probe: \(String(cString: strerror(spawned)))")
        throw ProbeSpawnFailed()
    }
    return pid
}

/// The probe's raw wait status, once it exits (so an exit with 143 and a
/// death by SIGTERM stay apart). After 30 seconds the probe's session and
/// the `groups` are killed and the hang recorded.
private func waitBounded(_ probe: pid_t, killing groups: [pid_t]) -> Int32? {
    let outcome = ProbeExit()
    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        var status: Int32 = 0
        let reaped = waitpidRetrying(probe, &status)
        outcome.code.withLock { $0 = reaped ? status : nil }
        finished.signal()
    }
    if finished.wait(timeout: .now() + 30) == .timedOut {
        // Both are unreaped until then (the probe by this test, the command
        // by the probe), so neither group id can have been reused.
        Issue.record("rv-run-probe did not exit within 30 seconds")
        for group in groups + [probe] where group > 1 { _ = kill(-group, SIGKILL) }
        _ = finished.wait(timeout: .now() + 10)
    }
    return outcome.code.withLock { $0 }
}

private final class ProbeExit: Sendable {
    let code = Mutex<Int32?>(nil)
}

private func waitpidRetrying(_ pid: pid_t, _ status: inout Int32) -> Bool {
    while true {
        if waitpid(pid, &status, 0) == pid { return true }
        guard errno == EINTR else { return false }
    }
}

/// The pid the command wrote to `marker` (renamed into place, so never
/// half written), or 0 if the probe exited first or 20 seconds passed.
private func waitForMarker(_ marker: String, while probe: pid_t) -> pid_t {
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        if let pid = pid_t(markerText(marker)), pid > 1 { return pid }
        var info = siginfo_t()
        // WNOWAIT: only looks; `waitBounded` reaps it.
        if waitid(P_PID, id_t(probe), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == probe { return 0 }
        usleep(5_000)
    }
    return 0
}

private func markerText(_ marker: String) -> String {
    ((try? String(contentsOfFile: marker, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// What the probe (and rv, and the command) wrote to stdout and stderr.
/// rv writes secret names there, never values.
private func probeOutput(_ log: URL) -> String {
    (try? String(contentsOf: log, encoding: .utf8)) ?? ""
}

/// Each `rv-run-probe: FAIL` line in the probe's output, as an issue.
private func expectNoFailures(_ log: URL) {
    for line in probeOutput(log).split(separator: "\n") where line.hasPrefix("rv-run-probe: FAIL") {
        Issue.record("\(line)")
    }
}

/// The signals `pid` ignores and catches, from the kernel.
private func signalMasks(of pid: pid_t) -> (ignored: UInt32, caught: UInt32)? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    let length = u_int(name.count)
    guard sysctl(&name, length, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return (info.kp_proc.p_sigignore, info.kp_proc.p_sigcatch)
}

private func ignores(_ mask: UInt32, _ number: Int32) -> Bool {
    mask & (UInt32(1) << UInt32(number - 1)) != 0
}
#endif
