#if os(Linux)
import Foundation
import Glibc
import Synchronization
import Testing
@testable import RVIsolation

/// `rv run`'s Linux spawn: the launcher (`rv-isolation-exec --stopped`), a
/// real child of it, and the `/proc` reading of rv's process group. Part of
/// the serialized launch suite: these change the process's signal
/// dispositions and wait for children, as the tests shared with macOS do.
extension SecretRunLaunchTests {
    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rv-run-linux-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func read(_ url: URL) -> String {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The launcher's exit code for `arguments`, run directly; nil if it did
    /// not exit within 20 s (it stopped: the arguments were accepted).
    private func launcherExit(_ arguments: [String]) throws -> Int32? {
        let path = try #require(SecretRunLauncher.path())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline {
            // Stopped, not running: the arguments were accepted.
            if case .value(let bytes) = ProcFSReader.file("/proc/\(process.processIdentifier)/stat"),
                ProcFSParse.stat(bytes)?.state == UInt8(ascii: "T")
            {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                return nil
            }
            usleep(5_000)
        }
        guard process.isRunning == false else {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            Issue.record("the launcher neither exited nor stopped")
            return nil
        }
        return process.terminationStatus
    }

    // MARK: - Pure

    @Test func theFloorIsOnePastTheKeptDescriptorsWhichLeaveNoGap() {
        #expect(SecretRunLauncher.Floor(keeping: [Int32]())?.rawValue == 3)
        #expect(SecretRunLauncher.Floor(keeping: [0, 1, 2])?.rawValue == 3)
        #expect(SecretRunLauncher.Floor(keeping: [3])?.rawValue == 4)
        #expect(SecretRunLauncher.Floor(keeping: [0, 1, 2, 3, 4])?.rawValue == 5)
        // A gap below the floor would pass on whatever rv has open there.
        #expect(SecretRunLauncher.Floor(keeping: [4]) == nil)
        #expect(SecretRunLauncher.Floor(keeping: [0, 9, 3]) == nil)
        #expect(SecretRunLauncher.Floor(keeping: [-1]) == nil)
        #expect(SecretRunLauncher.Floor(keeping: [Int32.max]) == nil)
        #expect(SecretRunProcess.spawnSuspended(
            executable: "/usr/bin/true", arguments: ["true"], environment: [], descriptors: [5: 0])
            == .failure(.spawnFailed("spawn file actions")))
    }

    /// "Inherit this descriptor as it is" never passes on one of rv's own:
    /// rv's are close-on-exec, the ones it was started with are not. When
    /// rv is started with a standard descriptor closed (`<&-`), its number
    /// goes to something rv opens, and the command must not get that.
    @Test func aClosedOrCloseOnExecDescriptorIsNotPassedOnAsItIs() throws {
        #expect(SecretRunProcess.passesOn(descriptorFlags: -1) == false)
        #expect(SecretRunProcess.passesOn(descriptorFlags: FD_CLOEXEC) == false)
        #expect(SecretRunProcess.passesOn(descriptorFlags: 0))
        var ends: [Int32] = [-1, -1]
        try #require(pipe(&ends) == 0)
        let own = fcntl(ends[0], F_DUPFD_CLOEXEC, 100)
        defer { [ends[0], ends[1], own].forEach { _ = close($0) } }
        #expect(SecretRunProcess.passesOn(descriptorFlags: fcntl(own, F_GETFD)) == false)
        #expect(SecretRunProcess.passesOn(descriptorFlags: fcntl(ends[0], F_GETFD)))
        #expect(SecretRunProcess.passesOn(descriptorFlags: fcntl(own + 1_000, F_GETFD)) == false)
    }

    @Test func theLaunchersArgumentsAreTheFloorTheExecutableAndTheCommandsOwn() throws {
        let floor = try #require(SecretRunLauncher.Floor(keeping: [0, 1, 2]))
        #expect(SecretRunLauncher.arguments(
            floor: floor, parent: 4_321, executable: "/bin/sh", arguments: ["sh", "-c", "--stopped"])
            == ["rv-isolation-exec", "--stopped", "3", "4321", "--", "/bin/sh", "sh", "-c", "--stopped"])
    }

    /// Only a stop by `SIGSTOP` is the launcher's own; everything else is a
    /// launch that must not be bound.
    @Test func onlyAStopBySIGSTOPIsReady() {
        #expect(SecretRunLauncher.state(code: Int32(CLD_STOPPED), status: SIGSTOP) == .ready)
        #expect(SecretRunLauncher.state(code: Int32(CLD_STOPPED), status: SIGTSTP) == .stopped(by: SIGTSTP))
        #expect(SecretRunLauncher.state(code: Int32(CLD_EXITED), status: 125) == .exited(125))
        #expect(SecretRunLauncher.state(code: Int32(CLD_EXITED), status: 0) == .exited(0))
        #expect(SecretRunLauncher.state(code: Int32(CLD_KILLED), status: SIGKILL) == .killed(by: SIGKILL))
        #expect(SecretRunLauncher.state(code: Int32(CLD_DUMPED), status: SIGSEGV) == .killed(by: SIGSEGV))
        #expect(SecretRunLauncher.state(code: Int32(CLD_CONTINUED), status: SIGCONT) == nil)
        #expect(SecretRunLauncher.state(code: Int32(CLD_TRAPPED), status: SIGTRAP) == nil)
        #expect(SecretRunLauncher.state(code: 0, status: 0) == nil)
        for state in [nil, .stopped(by: SIGTSTP), .exited(125), .killed(by: SIGKILL)] as [SecretRunLauncher.State?] {
            #expect(SecretRunLauncher.refusal(state).exitCode == 126)
        }
    }

    @Test func theLauncherIsFoundOnlyBesideTheExecutable() throws {
        let path = try #require(SecretRunLauncher.path())
        #expect(path.hasSuffix("/rv-isolation-exec"))
        #expect(URL(fileURLWithPath: path).deletingLastPathComponent().path
            == URL(fileURLWithPath: try #require(posixRealpath("/proc/self/exe"))).deletingLastPathComponent().path)
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let elsewhere = directory.appendingPathComponent("rv-cli").path
        #expect(SecretRunLauncher.path(besideExecutable: elsewhere) == nil)
        #expect(SecretRunLauncher.path(besideExecutable: nil) == nil)
        // A directory, or a file that is not executable, is not the launcher.
        let stand = directory.appendingPathComponent("rv-isolation-exec")
        try FileManager.default.createDirectory(at: stand, withIntermediateDirectories: true)
        #expect(SecretRunLauncher.path(besideExecutable: elsewhere) == nil)
        try FileManager.default.removeItem(at: stand)
        try Data("#!/bin/sh\n".utf8).write(to: stand)
        #expect(chmod(stand.path, 0o644) == 0)
        #expect(SecretRunLauncher.path(besideExecutable: elsewhere) == nil)
        #expect(chmod(stand.path, 0o755) == 0)
        #expect(SecretRunLauncher.path(besideExecutable: elsewhere) == stand.path)
    }

    // MARK: - The launcher binary

    /// Arguments it does not fully understand exit 125 before the stop, so
    /// nothing is ever bound to a launcher that would exec something else.
    @Test(.timeLimit(.minutes(1)), arguments: [
        ["--stopped"],
        ["--stopped", "3", "SELF", "--", "/bin/true"],
        ["--stopped", "3", "SELF", "/bin/true", "true", "x"],
        ["--stopped", "3", "--", "/bin/true", "true", "x"],
        ["--stopped", "2", "SELF", "--", "/bin/true", "true"],
        ["--stopped", "0", "SELF", "--", "/bin/true", "true"],
        ["--stopped", "", "SELF", "--", "/bin/true", "true"],
        ["--stopped", "+3", "SELF", "--", "/bin/true", "true"],
        ["--stopped", "3x", "SELF", "--", "/bin/true", "true"],
        ["--stopped", " 3", "SELF", "--", "/bin/true", "true"],
        ["--stopped", "-1", "SELF", "--", "/bin/true", "true"],
        ["--stopped", "99999999999", "SELF", "--", "/bin/true", "true"],
        ["--stopped", "3", "SELF", "--", "true", "true"],
        ["--stopped", "3", "SELF", "--", "", "true"],
        // Not the process that started it: 1, nobody, and a malformed pid.
        ["--stopped", "3", "1", "--", "/bin/true", "true"],
        ["--stopped", "3", "0", "--", "/bin/true", "true"],
        ["--stopped", "3", "", "--", "/bin/true", "true"],
        ["--stopped", "3", "SELFx", "--", "/bin/true", "true"],
        ["--stopped", "3", "-SELF", "--", "/bin/true", "true"],
    ])
    func theLauncherRefusesArgumentsItDoesNotUnderstand(arguments: [String]) throws {
        // SELF: this process, the launcher's real parent.
        let own = String(getpid())
        #expect(try launcherExit(arguments.map { $0.replacingOccurrences(of: "SELF", with: own) }) == 125)
    }

    @Test(.timeLimit(.minutes(1)))
    func theLauncherStopsBeforeItRunsAnything() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("ran").path
        #expect(try launcherExit(
            ["--stopped", "3", String(getpid()), "--", "/bin/sh", "sh", "-c", "touch \"$1\"", "sh", marker]) == nil)
        #expect(FileManager.default.fileExists(atPath: marker) == false)
    }

    // MARK: - A real child

    /// When `spawnSuspended` returns the child is stopped, leads its own
    /// group, is still the launcher (nothing of the command has run), and
    /// keeps its pid, group and start time through `exec`: what was captured
    /// while it was stopped is the command.
    @Test(.timeLimit(.minutes(1)))
    func theChildIsStoppedAsTheLauncherAndBecomesTheCommandWithTheSameIdentity() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pid = try SecretRunProcess.spawnSuspended(
            executable: "/bin/sh",
            arguments: ["sh", "-c", "echo $$ > \"$1/pid.tmp\"; mv \"$1/pid.tmp\" \"$1/pid\"; exec sleep 300", "sh", directory.path],
            environment: ["PATH=/usr/bin:/bin"], descriptors: [0: 0, 1: 1, 2: 2]
        ).get()
        defer { SecretRunProcess.discard(pid) }
        guard case .value(let bytes) = ProcFSReader.file("/proc/\(pid)/stat"), let stopped = ProcFSParse.stat(bytes) else {
            Issue.record("the child is not readable")
            return
        }
        #expect(stopped.state == UInt8(ascii: "T"))
        #expect(stopped.group == UInt32(pid))
        #expect(stopped.parent == UInt32(getpid()))
        let launcher = try #require(SecretRunLauncher.path())
        guard case .file(let running, _) = ProcFSProcessTable().executable(pid) else {
            Issue.record("the child's executable is unreadable")
            return
        }
        #expect(running == launcher)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pid").path) == false)
        // No stop report is left for the supervisor to mistake for Ctrl-Z.
        #expect(SecretRunProcess.consumeStop(pid) == nil)
        let captured = try #require(ProcessGroupRecovery.capture(pid: pid))

        #expect(kill(pid, SIGCONT) == 0)
        let deadline = Date().addingTimeInterval(20)
        while read(directory.appendingPathComponent("pid")).isEmpty, Date() < deadline { usleep(10_000) }
        #expect(read(directory.appendingPathComponent("pid")) == String(pid))
        guard case .file(let command, _) = ProcFSProcessTable().executable(pid) else {
            Issue.record("the command's executable is unreadable")
            return
        }
        #expect(command != launcher)
        #expect(ProcessGroupRecovery.capture(pid: pid) == captured)
    }

    /// Descriptors rv holds that are not close-on-exec (here a pipe and a
    /// listening socket, as the gateway's would be if one ever lost the
    /// flag) do not reach the command: it has stdio and nothing else.
    @Test(.timeLimit(.minutes(1)))
    func theCommandInheritsStdioAndNothingElse() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var ends: [Int32] = [-1, -1]
        try #require(pipe(&ends) == 0)
        let listener = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        try #require(listener >= 0)
        let high = fcntl(listener, F_DUPFD, 200)
        try #require(high >= 200)
        defer { [ends[0], ends[1], listener, high].forEach { _ = close($0) } }
        for leaked in [ends[0], ends[1], listener, high] {
            #expect(fcntl(leaked, F_GETFD) & FD_CLOEXEC == 0, "the fixture descriptor must be inheritable")
        }
        // `[ -e ]` is a builtin: the shell opens nothing while it looks.
        let script = """
            out=; n=0
            while [ $n -lt 1024 ]; do [ -e /proc/$$/fd/$n ] && out="$out $n"; n=$((n+1)); done
            echo "$out" > "$1/fds"
            """
        let result = SecretRunProcess.launch(
            executable: "/bin/sh", arguments: ["sh", "-c", script, "sh", directory.path],
            environment: ["PATH=/usr/bin:/bin"], manageTerminal: false
        ) { _ in .success(()) }
        #expect(result == .success(0))
        #expect(read(directory.appendingPathComponent("fds")) == "0 1 2")
    }

    /// The capability probe hands its child one descriptor (3) and nothing
    /// else: the floor moves past it, nothing above it survives, and a
    /// standard descriptor it was not given is closed, as on macOS.
    @Test(.timeLimit(.minutes(1)))
    func aDescriptorGivenToTheChildIsKeptAndEverythingAboveItClosed() throws {
        var ends: [Int32] = [-1, -1]
        try #require(pipe(&ends) == 0)
        let given = fcntl(ends[0], F_DUPFD_CLOEXEC, 50)
        let leaked = fcntl(ends[1], F_DUPFD, 60)
        try #require(given >= 50 && leaked >= 60)
        defer { [ends[0], ends[1], given, leaked].forEach { _ = close($0) } }
        let pid = try SecretRunProcess.spawnSuspended(
            executable: "/usr/bin/true", arguments: ["true"], environment: [], descriptors: [3: given]).get()
        defer { SecretRunProcess.discard(pid) }
        guard case .value(let names) = ProcFSReader.directory("/proc/\(pid)/fd") else {
            Issue.record("the child's descriptors are unreadable")
            return
        }
        #expect(names.compactMap { Int($0) }.sorted() == [3])
        // Descriptor 3 is the pipe end it was given.
        var mine = Glibc.stat()
        try #require(fstat(given, &mine) == 0)
        #expect(ProcFSReader.link("/proc/\(pid)/fd/3").value == "pipe:[\(mine.st_ino)]")
    }

    /// A launch that cannot be bound never runs the command, and one whose
    /// executable is not absolute never gets as far as a stop.
    @Test(.timeLimit(.minutes(1)))
    func aLauncherThatRefusesIsReapedAndReported() {
        let result = SecretRunProcess.spawnSuspended(
            executable: "sh", arguments: ["sh"], environment: [], descriptors: [0: 0, 1: 1, 2: 2])
        #expect(result == .failure(.spawnFailed("the launcher refused to start it (exit 125)")))
        #expect(launchersBelowThisProcess().isEmpty, "the refused launcher was left behind")
    }

    /// This process's children that are still the launcher.
    private func launchersBelowThisProcess() -> [pid_t] {
        let table = ProcFSProcessTable()
        let launcher = SecretRunLauncher.path()
        return (table.children(of: getpid()) ?? []).filter { child in
            if case .file(let path, _) = table.executable(child) { path == launcher } else { false }
        }
    }

    /// A stand-in launcher: a script at `rv-isolation-exec` in a directory of its own.
    private func fakeLauncher(_ script: String) throws -> (path: String, directory: URL) {
        let directory = try scratchDirectory()
        let path = directory.appendingPathComponent("rv-isolation-exec").path
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: URL(fileURLWithPath: path))
        try #require(chmod(path, 0o755) == 0)
        return (path, directory)
    }

    /// A launcher that stops for any reason but its own `SIGSTOP`, or never
    /// stops, is killed and reaped, and nothing is bound to it.
    @Test(.timeLimit(.minutes(1)), arguments: [
        ("kill -TSTP $$; sleep 300", "the launcher was stopped by signal \(SIGTSTP) before it was ready"),
        ("sleep 300", "the launcher did not stop within 1 seconds"),
        ("exit 0", "the launcher refused to start it (exit 0)"),
        ("kill -KILL $$", "the launcher was killed by signal \(SIGKILL)"),
    ])
    func aLauncherThatDoesNotStopItselfIsKilledAndRefused(script: String, reason: String) throws {
        let fake = try fakeLauncher(script)
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        let result = SecretRunProcess.spawnSuspended(
            executable: "/bin/true", arguments: ["true"], environment: ["PATH=/usr/bin:/bin"],
            descriptors: [0: 0, 1: 1, 2: 2], launcher: fake.path, deadline: 1)
        #expect(result == .failure(.spawnFailed(reason)))
        // The shell running the stand-in has its path in its command line.
        let running = (ProcFSProcessTable().children(of: getpid()) ?? []).filter { child in
            guard case .value(let bytes) = ProcFSReader.file("/proc/\(child)/cmdline") else { return false }
            return String(decoding: bytes, as: UTF8.self).contains(fake.path)
        }
        #expect(running.isEmpty, "the stand-in launcher was left running")
    }

    @Test func aMissingLauncherIsARefusalThatSaysWhatToInstall() {
        let result = SecretRunProcess.spawnSuspended(
            executable: "/bin/true", arguments: ["true"], environment: [], descriptors: [:], launcher: nil)
        guard case .failure(.spawnFailed(let reason)) = result else {
            Issue.record("a launch without the launcher did not fail")
            return
        }
        #expect(reason.contains("rv-isolation-exec is not installed beside rv") && reason.contains("reinstall rv"))
        #expect(SecretRunRefusal.spawnUnavailable.message.contains("reinstall rv"))
    }

    /// rv died while the launcher was stopped: the kernel continues an
    /// orphaned stopped group, and nothing bound the command. The launcher
    /// sees its parent changed and runs nothing.
    @Test(.timeLimit(.minutes(1)))
    func aLauncherContinuedAfterItsParentDiedRunsNothing() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launcher = try #require(SecretRunLauncher.path())
        let marker = directory.appendingPathComponent("ran").path
        let pidFile = directory.appendingPathComponent("pid").path
        // A shell starts the launcher, waits until it has stopped (as rv
        // does), records its pid and exits, orphaning it. The wait is
        // bounded: a launcher that never stops must fail this, not hang it.
        let script = """
            "$1" --stopped 3 $$ -- /usr/bin/touch touch "$2" &
            tries=0
            while [ "$(cut -d' ' -f3 /proc/$!/stat 2>/dev/null)" != T ] && [ $tries -lt 1000 ]; do
              sleep 0.01; tries=$((tries + 1))
            done
            echo $! > "$3"
            """
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sh")
        parent.arguments = ["-c", script, "sh", launcher, marker, pidFile]
        try parent.run()
        parent.waitUntilExit()
        let pid = try #require(pid_t(read(URL(fileURLWithPath: pidFile))))
        defer { kill(pid, SIGKILL) }
        let deadline = Date().addingTimeInterval(20)
        func state() -> UInt8? {
            guard case .value(let bytes) = ProcFSReader.file("/proc/\(pid)/stat") else { return nil }
            return ProcFSParse.stat(bytes)?.state
        }
        while state() != UInt8(ascii: "T"), state() != nil, Date() < deadline { usleep(5_000) }
        // Stopped, or already continued by the kernel and gone: either way it must not have run.
        _ = kill(pid, SIGCONT)
        while state() != nil, state() != UInt8(ascii: "Z"), Date() < deadline { usleep(5_000) }
        #expect(state() == nil || state() == UInt8(ascii: "Z"), "the orphaned launcher is still running")
        #expect(FileManager.default.fileExists(atPath: marker) == false)
    }

    /// The file was there when rv resolved it and gone at `exec`: the
    /// launcher says so on stderr and exits 126, as a failed spawn does.
    @Test(.timeLimit(.minutes(1)))
    func aCommandThatCannotBeExecutedExits126() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let errors = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        let sink = open(errors.path, O_WRONLY | O_CLOEXEC)
        try #require(sink >= 0)
        defer { close(sink) }
        let missing = directory.appendingPathComponent("gone").path
        let pid = try SecretRunProcess.spawnSuspended(
            executable: missing, arguments: ["gone"], environment: [], descriptors: [0: 0, 1: 1, 2: sink]).get()
        #expect(kill(pid, SIGCONT) == 0)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        #expect(SecretRunExit.code(waitStatus: status) == 126)
        #expect(read(errors) == "rv run: could not start the command: No such file or directory")
    }

    /// The whole of `rv run`'s capability check passes here by doing what it
    /// checks: a real stopped child, bound by the kernel peer check.
    @Test(.timeLimit(.minutes(1)))
    func thisHostStartsCommandsStoppedAndBindsThem() {
        #expect(SecretRunProcess.isAvailable)
        #expect(GatewayPeerBinding.isVerifiable)
        #expect(SecretRunProcess.bindsProcessGroups(.runtime))
        #expect(SecretRunCapability.check(.runtime) == nil)
    }

    // MARK: - rv's process group, from /proc

    @Test func groupMembersAndAncestorsComeFromTheListing() throws {
        let proc = try ProcFixture()
        try proc.process(10, parent: 1, group: 10)
        try proc.process(20, parent: 10, group: 20)
        try proc.process(21, parent: 20, group: 20)
        try proc.process(22, parent: 21, group: 20, state: "Z")
        try proc.process(30, parent: 21, group: 30)
        #expect(proc.table.groupMembers(20)?.sorted() == [20, 21])
        #expect(proc.table.groupMembers(999) == [])
        #expect(proc.table.ancestors(of: 30) == [21, 20, 10])
        #expect(proc.table.ancestors(of: 10) == [])
        #expect(proc.table.ancestors(of: 4242) == [])
        // A listing that cannot be read is no list: the terminal stays put.
        let hidden = try ProcFixture(mountOptions: "rw,hidepid=2")
        #expect(hidden.table.groupMembers(100) == nil)
        #expect(SecretRunJobControl.sharesGroup(members: hidden.table.groupMembers(100) ?? [], rv: 100, ancestors: []))
    }

    /// A pipeline's other commands share rv's group; rv's own parents do
    /// not count. Here a child started into this process's group is the
    /// "other command".
    @Test(.timeLimit(.minutes(1)))
    func aProcessSharingThisGroupIsSeenAndThisProcesssParentsAreNot() throws {
        func shares() -> Bool {
            let table = ProcFSProcessTable()
            return SecretRunJobControl.sharesGroup(
                members: table.groupMembers(getpgrp()) ?? [], rv: getpid(), ancestors: table.ancestors(of: getpid()))
        }
        let table = ProcFSProcessTable()
        #expect(table.groupMembers(getpgrp())?.contains(getpid()) == true)
        #expect(table.ancestors(of: getpid()).contains(getppid()))
        let before = Set(table.groupMembers(getpgrp()) ?? [])
        // Started into this process's group (no `POSIX_SPAWN_SETPGROUP`).
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("sleep"), strdup("300"), nil]
        defer { argv.forEach { free($0) } }
        var sibling: pid_t = 0
        try #require(posix_spawn(&sibling, "/bin/sleep", nil, nil, &argv, environ) == 0)
        defer {
            kill(sibling, SIGKILL)
            var status: Int32 = 0
            waitpid(sibling, &status, 0)
        }
        try #require(getpgid(sibling) == getpgrp())
        #expect(ProcFSProcessTable().groupMembers(getpgrp())?.contains(sibling) == true)
        #expect(shares())
        // Whatever else was in the group before is not this test's to judge.
        #expect(before.contains(sibling) == false)
    }
}
private extension ProcFSRead {
    var value: Value? {
        if case .value(let value) = self { value } else { nil }
    }
}
#endif
