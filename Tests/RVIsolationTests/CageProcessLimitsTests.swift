#if canImport(Darwin)
import Darwin
#endif
import Foundation
import RVDomain
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
    /// helper runs here with no supervisor watching it at all.
    @Test func theWatchdogKillsTheGroupWithoutTheHost() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let claim = try #require(resolvedPtyClaimPath(workspace: tree.workspaceURL.path))
        let pidFile = tree.workspaceURL.appendingPathComponent("bg.pid")
        let leader = Process()
        // perl makes the helper lead its own group, as the spawn does.
        leader.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        leader.arguments = [
            "-e", "setpgrp(0, 0); exec @ARGV or exit 126", claim,
            "--deadline-seconds=1", "-", "/bin/sh", "-c",
            "/bin/sleep 300 & echo $! > '\(pidFile.path)'; /bin/sleep 300",
        ]
        try leader.run()
        #expect(limitsWait(seconds: 20) { FileManager.default.fileExists(atPath: pidFile.path) })
        let background = try #require(pid_t(
            String(decoding: try Data(contentsOf: pidFile), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        leader.waitUntilExit()
        #expect(leader.terminationReason == .uncaughtSignal)
        #expect(leader.terminationStatus == SIGKILL)
        #expect(limitsWait(seconds: 10) { limitsProcessGone(background) })
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

    func close() {
        _ = supervisor.close()
        tree.tearDown()
    }
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
