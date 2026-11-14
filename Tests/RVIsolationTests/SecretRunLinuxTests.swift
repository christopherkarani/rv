#if os(Linux)
import Foundation
import Glibc
import Synchronization
import Testing
@testable import RVIsolation

/// `rv run`'s Linux spawn: the launcher (`rv-isolation-exec --stopped`), a
/// real child of it, and the `/proc` reading of rv's process group. The
/// launch, supervision and signal tests shared with macOS are in
/// SecretRunTests. Every wait has a deadline only so a broken run fails
/// instead of hanging.
@Suite("SecretRun Linux launcher", .serialized)
struct SecretRunLinuxTests {
    private func temporaryDirectory() throws -> URL {
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
            process.terminate()
            return nil
        }
        return process.terminationStatus
    }

    // MARK: - Pure

    @Test func theFloorIsOnePastTheHighestKeptDescriptorAndNeverBelowThree() {
        #expect(SecretRunLauncher.Floor(keeping: [Int32]())?.rawValue == 3)
        #expect(SecretRunLauncher.Floor(keeping: [0, 1, 2])?.rawValue == 3)
        #expect(SecretRunLauncher.Floor(keeping: [3])?.rawValue == 4)
        #expect(SecretRunLauncher.Floor(keeping: [0, 9, 4])?.rawValue == 10)
        #expect(SecretRunLauncher.Floor(keeping: [-1]) == nil)
        #expect(SecretRunLauncher.Floor(keeping: [Int32.max]) == nil)
    }

    @Test func theLaunchersArgumentsAreTheFloorTheExecutableAndTheCommandsOwn() throws {
        let floor = try #require(SecretRunLauncher.Floor(keeping: [0, 1, 2]))
        #expect(SecretRunLauncher.arguments(floor: floor, executable: "/bin/sh", arguments: ["sh", "-c", "--stopped"])
            == ["rv-isolation-exec", "--stopped", "3", "--", "/bin/sh", "sh", "-c", "--stopped"])
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
        let directory = try temporaryDirectory()
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
        ["--stopped", "3", "--", "/bin/true"],
        ["--stopped", "3", "/bin/true", "true", "x"],
        ["--stopped", "2", "--", "/bin/true", "true"],
        ["--stopped", "0", "--", "/bin/true", "true"],
        ["--stopped", "", "--", "/bin/true", "true"],
        ["--stopped", "+3", "--", "/bin/true", "true"],
        ["--stopped", "3x", "--", "/bin/true", "true"],
        ["--stopped", " 3", "--", "/bin/true", "true"],
        ["--stopped", "-1", "--", "/bin/true", "true"],
        ["--stopped", "99999999999", "--", "/bin/true", "true"],
        ["--stopped", "3", "--", "true", "true"],
        ["--stopped", "3", "--", "", "true"],
    ])
    func theLauncherRefusesArgumentsItDoesNotUnderstand(arguments: [String]) throws {
        #expect(try launcherExit(arguments) == 125)
    }

    @Test(.timeLimit(.minutes(1)))
    func theLauncherStopsBeforeItRunsAnything() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("ran").path
        #expect(try launcherExit(["--stopped", "3", "--", "/bin/sh", "sh", "-c", "touch \"$1\"", "sh", marker]) == nil)
        #expect(FileManager.default.fileExists(atPath: marker) == false)
    }

    // MARK: - A real child

    /// When `spawnSuspended` returns the child is stopped, leads its own
    /// group, is still the launcher (nothing of the command has run), and
    /// keeps its pid, group and start time through `exec`: what was captured
    /// while it was stopped is the command.
    @Test(.timeLimit(.minutes(1)))
    func theChildIsStoppedAsTheLauncherAndBecomesTheCommandWithTheSameIdentity() throws {
        let directory = try temporaryDirectory()
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
        #expect(ProcFSProcessTable().executable(pid) == ProcFSProcessTable().executable(pid))
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
        let directory = try temporaryDirectory()
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

    /// The capability probe hands its child one extra descriptor (3); the
    /// floor moves past it, and nothing above it survives.
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
        #expect(names.compactMap { Int($0) }.sorted() == [0, 1, 2, 3])
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
        var status: Int32 = 0
        #expect(waitpid(-1, &status, WNOHANG) <= 0, "the refused launcher was left unreaped")
    }

    /// The file was there when rv resolved it and gone at `exec`: the
    /// launcher says so on stderr and exits 126, as a failed spawn does.
    @Test(.timeLimit(.minutes(1)))
    func aCommandThatCannotBeExecutedExits126() throws {
        let directory = try temporaryDirectory()
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
