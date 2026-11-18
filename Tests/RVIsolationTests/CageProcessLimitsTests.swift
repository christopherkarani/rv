#if canImport(Darwin)
import Darwin
#endif
import Foundation
import RVDomain
import Synchronization
import Testing
@testable import RVIsolation

@Suite("Cage process limits")
struct CageProcessLimitsTests {
    @Test func standardLimitsDisableCoreDumpsAndCapDescriptorsAndFiles() {
        #expect(CageProcessLimits.standard.helperArguments() == [
            "--rlimit=core:0",
            "--rlimit=nofile:\(CageProcessLimits.defaultOpenFiles)",
            "--rlimit=fsize:\(CageProcessLimits.defaultFileSizeBytes)",
        ])
    }

    @Test func policyCapsAndDeadlineBecomeHelperArguments() {
        let limits = CageProcessLimits(policy: RuntimeProcessLimits(
            openFiles: 256, fileSizeBytes: 1 << 20, cpuSeconds: 30, timeoutSeconds: 60
        ))
        #expect(limits.helperArguments(injectFailure: true) == [
            "--rlimit=core:0",
            "--rlimit=nofile:256",
            "--rlimit=fsize:1048576",
            "--rlimit=cpu:30",
            "--deadline-seconds=\(60 + CageProcessLimits.watchdogGraceSeconds)",
            "--rlimit-fault",
        ])
        #expect(limits.withoutDeadline.helperArguments().contains { $0.hasPrefix("--deadline") } == false)
    }

    @Test func aRequestedTimeoutShortensButNeverExtendsThePolicy() {
        let capped = CageProcessLimits(policy: RuntimeProcessLimits(timeoutSeconds: 60))
        #expect(capped.withRequestedTimeout(nil).timeoutSeconds == 60)
        #expect(capped.withRequestedTimeout(10).timeoutSeconds == 10)
        #expect(capped.withRequestedTimeout(600).timeoutSeconds == 60)
        #expect(CageProcessLimits.standard.withRequestedTimeout(nil).timeoutSeconds == nil)
        #expect(CageProcessLimits.standard.withRequestedTimeout(5).timeoutSeconds == 5)
    }
}

#if os(macOS)
/// The limits and deadline through the real cage: `rv-pty-claim` applies
/// them in the leader before `sandbox-exec`, so the payload sees them.
@Suite("Cage process limits through Seatbelt", .serialized)
struct CageProcessLimitsSeatbeltTests {
    @Test func theCagedPayloadSeesTheConfiguredLimits() throws {
        let opened = try LimitsWorkspace()
        defer { opened.close() }
        opened.supervisor.configureProcessLimits(RuntimeProcessLimits(
            openFiles: 256, fileSizeBytes: 1 << 20, cpuSeconds: 120
        ))
        let output = try opened.runToCompletion(
            "{ ulimit -c; ulimit -Sn; ulimit -Hn; ulimit -Hf; ulimit -Ht; } > limits.txt"
        )
        // bash's `ulimit -f` counts 1024-byte blocks.
        #expect(output == ["0", "256", "256", "1024", "120"])
    }

    @Test func aCapAboveTheInheritedLimitDoesNotRaiseIt() throws {
        var inherited = rlimit()
        #expect(getrlimit(RLIMIT_NOFILE, &inherited) == 0)
        let opened = try LimitsWorkspace()
        defer { opened.close() }
        opened.supervisor.configureProcessLimits(RuntimeProcessLimits(
            openFiles: RuntimeProcessLimits.openFilesRange.upperBound
        ))
        let output = try opened.runToCompletion("{ ulimit -Sn; ulimit -Hn; } > limits.txt")
        #expect(output.count == 2)
        let soft = try #require(output.first.flatMap { UInt64($0) })
        let hard = try #require(output.last.flatMap { $0 == "unlimited" ? UInt64.max : UInt64($0) })
        #expect(soft <= UInt64(inherited.rlim_cur))
        #expect(hard <= UInt64(inherited.rlim_max))
        #expect(soft <= hard)
    }

    @Test func aLimitTheKernelRefusesStopsTheLaunchBeforeThePayload() throws {
        let opened = try LimitsWorkspace()
        defer { opened.close() }
        let marker = opened.tree.workspaceURL.appendingPathComponent("must-not-run")
        let launched = opened.supervisor.launch(
            host: nil,
            command: try limitsShell("printf ran > must-not-run"),
            plan: compileContainedPlan(workspace: opened.supervisor.snapshot.policyWorkspace),
            io: .discard,
            admission: .failClosed,
            sessionStore: .file(opened.runtimeLog),
            spawnFault: .rlimit
        )
        guard case .failure = launched else {
            Issue.record("a refused limit must fail the launch, got \(launched)")
            return
        }
        Thread.sleep(forTimeInterval: 0.5)
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
        #expect(opened.supervisor.runtimeFacts().contains { $0.running } == false)
    }

    @Test func theDeadlineKillsTheWholeGroupAndRecordsTimeout() throws {
        let opened = try LimitsWorkspace()
        defer { opened.close() }
        let running = try opened.supervisor.launch(
            host: nil,
            command: try limitsShell("/bin/sleep 300 & echo $! > bg.pid; /bin/sleep 300"),
            plan: compileContainedPlan(workspace: opened.supervisor.snapshot.policyWorkspace),
            io: .discard,
            admission: .failClosed,
            sessionStore: .file(opened.runtimeLog),
            timeoutSeconds: 1
        ).get()
        let leader = try #require(running.session.child?.pid)
        let pidFile = opened.tree.workspaceURL.appendingPathComponent("bg.pid")
        #expect(limitsWait(seconds: 20) { FileManager.default.fileExists(atPath: pidFile.path) })
        let background = try #require(pid_t(
            String(decoding: try Data(contentsOf: pidFile), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        #expect(limitsWait(seconds: 30) {
            opened.supervisor.runtimeFacts().contains { $0.running } == false
        })
        #expect(limitsWait(seconds: 10) { limitsProcessGone(leader) && limitsProcessGone(background) })
        #expect(limitsWait(seconds: 10) {
            WorkspaceLifecycleLog.records(at: opened.lifeLog).contains {
                $0.kind == .runtimeEnded && $0.endReason == "timeout"
            }
        })
    }

    @Test func aRuntimeThatEndsInTimeRecordsNoTimeout() throws {
        let opened = try LimitsWorkspace()
        defer { opened.close() }
        _ = try opened.supervisor.launch(
            host: nil,
            command: try limitsShell("true"),
            plan: compileContainedPlan(workspace: opened.supervisor.snapshot.policyWorkspace),
            io: .discard,
            admission: .failClosed,
            sessionStore: .file(opened.runtimeLog),
            timeoutSeconds: 60
        ).get()
        #expect(limitsWait(seconds: 30) {
            WorkspaceLifecycleLog.records(at: opened.lifeLog).contains { $0.kind == .runtimeEnded }
        })
        let ended = WorkspaceLifecycleLog.records(at: opened.lifeLog).filter { $0.kind == .runtimeEnded }
        #expect(ended.allSatisfy { $0.endReason == nil })
    }

    /// The watchdog is the deadline when nothing on the host acts: the
    /// helper runs here with no supervisor watching it at all. Children
    /// that left the group (setpgid) or the session (setsid) die too.
    @Test func theWatchdogKillsTheTreeWithoutTheHost() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let claim = try #require(resolvedPtyClaimPath(workspace: tree.workspaceURL.path))
        let files = ["bg", "pg", "sid"].map { tree.workspaceURL.appendingPathComponent("\($0).pid") }
        let leader = Process()
        // Process makes the helper lead its own group, as the spawn does.
        leader.executableURL = URL(fileURLWithPath: claim)
        leader.arguments = [
            "--deadline-seconds=8", "-", "/bin/sh", "-c",
            "/bin/sleep 300 & echo $! > '\(files[0].path)'; "
                + "/usr/bin/perl -e 'setpgrp(0, 0); sleep 300' & echo $! > '\(files[1].path)'; "
                + "/usr/bin/perl -e 'use POSIX; POSIX::setsid(); sleep 300' & echo $! > '\(files[2].path)'; "
                + "/bin/sleep 300",
        ]
        try leader.run()
        #expect(limitsWait(seconds: 20) {
            files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        })
        let children = try files.map { file in
            try #require(pid_t(
                String(decoding: try Data(contentsOf: file), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        let ended = limitsWait(seconds: 90) { leader.isRunning == false }
        if ended == false { leader.terminate() }
        #expect(ended, "the watchdog did not end the leader")
        leader.waitUntilExit()
        #expect(leader.terminationReason == .uncaughtSignal)
        #expect(leader.terminationStatus == SIGKILL)
        #expect(limitsWait(seconds: 10) { children.allSatisfy(limitsProcessGone) })
        for child in children where limitsProcessGone(child) == false {
            kill(child, SIGKILL)
        }
    }

    /// XNU's RLIMIT_CPU only signals SIGXCPU once; the watchdog is what
    /// stops a process that ignores it.
    @Test func theCPUCapHoldsWhenSIGXCPUIsIgnored() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let claim = try #require(resolvedPtyClaimPath(workspace: tree.workspaceURL.path))
        let spinner = Process()
        spinner.executableURL = URL(fileURLWithPath: claim)
        spinner.arguments = [
            "--rlimit=cpu:1", "-", "/usr/bin/perl", "-e", "$SIG{XCPU} = 'IGNORE'; 1 while 1",
        ]
        try spinner.run()
        let bounded = limitsWait(seconds: 240) { spinner.isRunning == false }
        if bounded == false { spinner.terminate() }
        #expect(bounded)
        spinner.waitUntilExit()
        #expect(spinner.terminationReason == .uncaughtSignal)
        #expect(spinner.terminationStatus == SIGKILL)
    }

    @Test func aMissingHelperRefusesTheLaunch() throws {
        let opened = try LimitsWorkspace()
        defer { opened.close() }
        let marker = opened.tree.workspaceURL.appendingPathComponent("must-not-run")
        let launched = opened.supervisor.launch(
            host: nil,
            command: try limitsShell("printf ran > must-not-run"),
            plan: compileContainedPlan(workspace: opened.supervisor.snapshot.policyWorkspace),
            io: .discard,
            admission: .failClosed,
            sessionStore: .file(opened.runtimeLog),
            spawnFault: .missingHelper
        )
        guard case .failure(.apply(.lifetimeBoundaryFailed)) = launched else {
            Issue.record("a missing helper must refuse the launch, got \(launched)")
            return
        }
        Thread.sleep(forTimeInterval: 0.5)
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
        #expect(opened.supervisor.runtimeFacts().contains { $0.running } == false)
    }

    @Test func oneShotsCarryTheRuntimeCapsAndNeedTheHelper() throws {
        let command = try #require(IsolatedCommand(executable: "/usr/bin/touch", arguments: ["x"]))
        var launch = AdmittedLaunchContext(
            plan: compileContainedPlan(workspace: try #require(WorkingDirectory(validating: "/tmp/w"))),
            profileSource: "(version 1)",
            workspacePath: "/tmp/w"
        )
        launch.processLimits = CageProcessLimits(policy: RuntimeProcessLimits(
            openFiles: 256, fileSizeBytes: 1 << 20, cpuSeconds: 30, timeoutSeconds: 60
        ))
        #expect(admittedOneShotArguments(helper: nil, command: command, launch: launch, nonce: "n") == nil)
        let arguments = try #require(admittedOneShotArguments(
            helper: "/opt/rv/rv-pty-claim", command: command, launch: launch, nonce: "n"
        ))
        #expect(Array(arguments.prefix(6)) == [
            "/opt/rv/rv-pty-claim",
            "--rlimit=core:0", "--rlimit=nofile:256", "--rlimit=fsize:1048576", "--rlimit=cpu:30",
            "-",
        ])
        // One-shots live under the owning runtime's clock, not their own.
        #expect(arguments.contains { $0.hasPrefix("--deadline") } == false)
        #expect(arguments.contains { $0.hasPrefix("--owner-pid") } == false)
        #expect(Array(arguments.suffix(2)) == ["/usr/bin/touch", "x"])
        launch.sessionLeader = 4242
        let owned = try #require(admittedOneShotArguments(
            helper: "/opt/rv/rv-pty-claim", command: command, launch: launch, nonce: "n"
        ))
        #expect(Array(owned[5...6]) == ["--owner-pid=4242", "-"])
    }

    /// An admitted one-shot's own watchdog ends it when the runtime leader
    /// it serves exits, with no host to stop it.
    @Test func aOneShotEndsWithItsOwnerWithoutTheHost() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let claim = try #require(resolvedPtyClaimPath(workspace: tree.workspaceURL.path))
        let owner = Process()
        owner.executableURL = URL(fileURLWithPath: "/bin/sleep")
        owner.arguments = ["300"]
        try owner.run()
        defer { if owner.isRunning { owner.terminate() } }
        let file = tree.workspaceURL.appendingPathComponent("bg.pid")
        let oneShot = Process()
        oneShot.executableURL = URL(fileURLWithPath: claim)
        oneShot.arguments = [
            "--owner-pid=\(owner.processIdentifier)", "-", "/bin/sh", "-c",
            "/bin/sleep 300 & echo $! > '\(file.path)'; /bin/sleep 300",
        ]
        try oneShot.run()
        #expect(limitsWait(seconds: 20) { FileManager.default.fileExists(atPath: file.path) })
        let child = try #require(pid_t(
            String(decoding: try Data(contentsOf: file), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        // The payload ran, so the helper's watchdog is armed on the owner.
        #expect(oneShot.isRunning)
        owner.terminate()
        owner.waitUntilExit()
        let ended = limitsWait(seconds: 30) { oneShot.isRunning == false }
        if ended == false { oneShot.terminate() }
        #expect(ended)
        oneShot.waitUntilExit()
        #expect(oneShot.terminationStatus == SIGKILL)
        #expect(limitsWait(seconds: 10) { limitsProcessGone(child) })
        if limitsProcessGone(child) == false { kill(child, SIGKILL) }
    }

    @Test func aOneShotWhoseOwnerIsGoneDoesNotStart() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let claim = try #require(resolvedPtyClaimPath(workspace: tree.workspaceURL.path))
        let owner = Process()
        owner.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try owner.run()
        owner.waitUntilExit()
        let marker = tree.workspaceURL.appendingPathComponent("must-not-run")
        let oneShot = Process()
        oneShot.executableURL = URL(fileURLWithPath: claim)
        oneShot.arguments = ["--owner-pid=\(owner.processIdentifier)", "-", "/usr/bin/touch", marker.path]
        oneShot.standardError = FileHandle.nullDevice
        try oneShot.run()
        oneShot.waitUntilExit()
        #expect(oneShot.terminationStatus == 125)
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
    }

    @Test(arguments: [
        ["--owner-pid=0"],
        ["--owner-pid=1"],
        ["--owner-pid=2147483648"],
        ["--owner-pid="],
        ["--owner-pid=12x"],
        ["--owner-pid=4242", "--owner-pid=4242"],
    ])
    func aBadOwnerPidIsRefusedBeforeExec(owner: [String]) throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let claim = try #require(resolvedPtyClaimPath(workspace: tree.workspaceURL.path))
        let marker = tree.workspaceURL.appendingPathComponent("must-not-run")
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: claim)
        helper.arguments = owner + ["-", "/usr/bin/touch", marker.path]
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        helper.waitUntilExit()
        #expect(helper.terminationStatus == 127)
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
    }

    /// The host's deadline reaches the terminal's exit notice, which is
    /// what makes `rv workspace run` exit 124.
    @Test func aTimedOutTerminalRuntimeReportsItsDeadline() throws {
        let opened = try LimitsWorkspace()
        defer { opened.close() }
        let notices = try opened.terminalNotices("/bin/sleep 300", timeoutSeconds: 1)
        let exit = try #require(limitsExit(notices, seconds: 60))
        #expect(exit.timedOutAfter == 1)
    }

    /// A leader that exited on its own just before the deadline check keeps
    /// its status: the check reaps it instead of calling it a timeout. The
    /// child here has already exited (proved without reaping), which is the
    /// race the check closes, with no sleep timing involved.
    @Test func aLeaderThatAlreadyExitedAtTheDeadlineIsNotATimeout() throws {
        let exited = try limitsSpawn(["/bin/sh", "-c", "exit 3"])
        var info = siginfo_t()
        #expect(waitid(P_PID, id_t(exited), &info, WEXITED | WNOWAIT) == 0)
        #expect(seatbeltDeadlineCheck(root: exited) == .exited(3))
        let running = try limitsSpawn(["/bin/sleep", "300"])
        #expect(seatbeltDeadlineCheck(root: running) == .running)
        kill(running, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(running, &status, 0)
    }

    /// An older client refuses a frame with an unknown key, so the reason
    /// goes only to a subscriber that named `runtimeExitReasonV1`.
    @Test func theExitReasonGoesOnlyToSubscribersThatAskForIt() {
        let runtime = UUID()
        let notice = TerminalNotice.exited(9, timedOutAfter: 30)
        guard case .runtimeExited(let opted) = workspaceTerminalMessage(notice, runtime: runtime, exitReasons: true).payload,
            case .runtimeExited(let legacy) = workspaceTerminalMessage(notice, runtime: runtime, exitReasons: false).payload
        else {
            Issue.record("an exit notice must become runtimeExited")
            return
        }
        #expect(opted.timedOutAfter == 30)
        #expect(opted.exitStatus == 9)
        #expect(legacy.timedOutAfter == nil)
        #expect(legacy.exitStatus == 9)
    }

    /// A SIGKILL that is not the deadline's is reported as the status
    /// alone, never as a timeout.
    @Test func aKilledTerminalRuntimeIsNotReportedAsATimeout() throws {
        let opened = try LimitsWorkspace()
        defer { opened.close() }
        let notices = try opened.terminalNotices("kill -9 $$", timeoutSeconds: 60)
        let exit = try #require(limitsExit(notices, seconds: 60))
        #expect(exit.status == SIGKILL)
        #expect(exit.timedOutAfter == nil)
    }

    @Test func theWatchdogRefusesALeaderOutsideItsOwnGroup() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let claim = try #require(resolvedPtyClaimPath(workspace: tree.workspaceURL.path))
        let marker = tree.workspaceURL.appendingPathComponent("must-not-run")
        let leader = Process()
        // Process makes its child a group leader; the forked grandchild is
        // a member of that group, not its leader.
        leader.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        leader.arguments = [
            "-e", "my $p = fork(); if ($p == 0) { exec @ARGV or exit 126 } waitpid($p, 0); exit($? >> 8)",
            claim, "--deadline-seconds=1", "-", "/usr/bin/touch", marker.path,
        ]
        leader.standardError = FileHandle.nullDevice
        try leader.run()
        leader.waitUntilExit()
        #expect(leader.terminationStatus == 125)
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
    }
}

private struct LimitsWorkspace {
    let tree: ContainmentTree
    let supervisor: WorkspaceSessionSupervisor
    let runtimeLog: URL
    let lifeLog: URL

    init() throws {
        tree = try ContainmentTree()
        runtimeLog = tree.rootURL.appendingPathComponent("runtime-\(UUID().uuidString).jsonl")
        lifeLog = tree.rootURL.appendingPathComponent("workspace-\(UUID().uuidString).jsonl")
        let directory = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
        supervisor = try WorkspaceSessionSupervisor.open(directory, lifecycleLog: .file(lifeLog)).get()
    }

    /// Runs `script` in the cage; returns the lines it wrote to limits.txt.
    func runToCompletion(_ script: String) throws -> [String] {
        _ = try supervisor.launch(
            host: nil,
            command: try limitsShell(script),
            plan: compileContainedPlan(workspace: supervisor.snapshot.policyWorkspace),
            io: .discard,
            admission: .failClosed,
            sessionStore: .file(runtimeLog)
        ).get()
        let output = tree.workspaceURL.appendingPathComponent("limits.txt")
        #expect(limitsWait(seconds: 30) {
            WorkspaceLifecycleLog.records(at: lifeLog).contains { $0.kind == .runtimeEnded }
        })
        return String(decoding: try Data(contentsOf: output), as: UTF8.self)
            .split(separator: "\n").map(String.init)
    }

    /// Launches `script` on a host-owned terminal and records its notices.
    func terminalNotices(_ script: String, timeoutSeconds: UInt64) throws -> LimitsNotices {
        let running = try supervisor.launch(
            host: nil,
            command: try limitsShell(script),
            plan: compileContainedPlan(workspace: supervisor.snapshot.policyWorkspace),
            io: .pseudoTerminal(rows: 24, columns: 80),
            admission: .failClosed,
            sessionStore: .file(runtimeLog),
            timeoutSeconds: timeoutSeconds
        ).get()
        let notices = LimitsNotices()
        let client = UUID()
        try supervisor.subscribeTerminal(runtime: running.id.rawValue, client: client) { notice in
            notices.box.withLock { $0.append(notice) }
            return true
        }.get()
        supervisor.activateTerminal(runtime: running.id.rawValue, client: client)
        return notices
    }

    func close() {
        _ = supervisor.close()
        tree.tearDown()
    }
}

/// Spawns `argv` as this process's own child, so the test (not Foundation)
/// decides when it is reaped.
private func limitsSpawn(_ argv: [String]) throws -> pid_t {
    var pid: pid_t = 0
    let pointers = argv.map { strdup($0) } + [nil]
    defer { pointers.forEach { free($0) } }
    let spawned = pointers.withUnsafeBufferPointer { buffer in
        posix_spawn(&pid, argv[0], nil, nil, UnsafeMutablePointer(mutating: buffer.baseAddress), environ)
    }
    try #require(spawned == 0 && pid > 1)
    return pid
}

private final class LimitsNotices: Sendable {
    let box = Mutex<[TerminalNotice]>([])
}

private func limitsExit(
    _ notices: LimitsNotices, seconds: TimeInterval
) -> (status: Int32, timedOutAfter: UInt64?)? {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        let found = notices.box.withLock { list -> (Int32, UInt64?)? in
            for notice in list {
                if case .exited(let status, let timedOutAfter) = notice { return (status, timedOutAfter) }
            }
            return nil
        }
        if let found { return (found.0, found.1) }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    return nil
}

private func limitsShell(_ script: String) throws -> IsolatedCommand {
    try #require(IsolatedCommand(executable: "/bin/sh", arguments: ["-c", script]))
}

private func limitsWait(seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return condition()
}

private func limitsProcessGone(_ pid: pid_t) -> Bool {
    if kill(pid, 0) == 0 { return false }
    return errno == ESRCH
}
#endif
