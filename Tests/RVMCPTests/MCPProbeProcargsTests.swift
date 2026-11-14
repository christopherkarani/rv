#if os(macOS)
import Darwin
import Foundation
import Testing

/// The probe's `KERN_PROCARGS2` parse, which the live placeholder test relies
/// on for "the caged server sees no environment of its parent".
@Suite("rv-mcp-probe procargs")
struct MCPProbeProcargsTests {
    /// Empty arguments are still arguments. Read of its own process (which
    /// the kernel answers with the environment), started with two empty
    /// arguments and only `HOME` set: the parse must step over exactly argc
    /// strings and still find `HOME=`. Dropping empty strings before
    /// counting skips past it and reports `home=no`.
    @Test(.timeLimit(.minutes(1)))
    func emptyArgumentsDoNotHideTheEnvironment() throws {
        let probe = try mcpProbe()
        let process = Process()
        process.executableURL = probe
        process.arguments = ["procargs", "self", "", ""]
        process.environment = ["HOME": "/rv-procargs-sentinel"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        // Hard bound: polls, never blocks in `waitid`; killed after 20 s.
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            Issue.record("the procargs probe did not finish")
            return
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(process.terminationStatus == 0, "\(text)")
        #expect(text.hasPrefix("ok argc=5 "), "\(text)")
        #expect(text.hasSuffix(" home=yes"), "\(text)")
    }

    /// An empty `argv[0]` is one NUL, like the padding after the exec path.
    /// Skipping every NUL there takes it for padding, steps over `HOME=` as
    /// the last argument, and reports `home=no`. Arguments start at the
    /// padding's alignment, so the parse must start there. `Process` cannot
    /// set `argv[0]`, so this spawns with `posix_spawn`.
    @Test(.timeLimit(.minutes(1)))
    func anEmptyFirstArgumentIsNotTakenForPadding() throws {
        let probe = try mcpProbe()
        var pipeFDs: [Int32] = [0, 0]
        try #require(pipe(&pipeFDs) == 0)
        defer { close(pipeFDs[0]) }
        for descriptor in pipeFDs { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        var actions: posix_spawn_file_actions_t?
        try #require(posix_spawn_file_actions_init(&actions) == 0)
        defer { posix_spawn_file_actions_destroy(&actions) }
        try #require(posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], STDOUT_FILENO) == 0)
        var attributes: posix_spawnattr_t?
        try #require(posix_spawnattr_init(&attributes) == 0)
        defer { posix_spawnattr_destroy(&attributes) }
        try #require(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0)
        var argv: [UnsafeMutablePointer<CChar>?] = ["", "procargs", "self"].map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = [strdup("HOME=/rv-procargs-sentinel"), nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, probe.path, &actions, &attributes, &argv, &envp)
        close(pipeFDs[1])
        try #require(spawned == 0)
        // Hard bound: polls with WNOHANG, never blocks in `waitid`; killed after 20 s.
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(20)
        var reaped = waitpid(pid, &status, WNOHANG)
        while reaped == 0, Date() < deadline {
            usleep(20_000)
            reaped = waitpid(pid, &status, WNOHANG)
        }
        if reaped == 0 {
            kill(pid, SIGKILL)
            _ = waitpid(pid, &status, 0)
            Issue.record("the procargs probe did not finish")
            return
        }
        // The probe has exited, so its line is already in the pipe. Read
        // without blocking: a child another test spawned meanwhile could hold
        // the write end open.
        _ = fcntl(pipeFDs[0], F_SETFL, O_NONBLOCK)
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(pipeFDs[0], &chunk, chunk.count)
            guard count > 0 else { break }
            bytes += chunk.prefix(count)
        }
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(reaped == pid && status == 0, "\(text)")
        #expect(text.hasPrefix("ok argc=3 "), "\(text)")
        #expect(text.hasSuffix(" home=yes"), "\(text)")
    }

    /// The same parse over a hand-built `KERN_PROCARGS2` buffer, so layouts
    /// no real process produces are covered: no exec path terminator, padding
    /// that is not NUL or runs past the buffer, and fewer than argc
    /// arguments each fail the read, never pass for "no environment".
    @Test(.timeLimit(.minutes(1)), arguments: [
        // argc 1, "/a" with no NUL.
        ("01000000" + "2f61", "failed no exec path"),
        // argc 1, "/a\0", padding to byte 12 holds an 'x'.
        ("01000000" + "2f6100" + "0078000000", "failed padding"),
        // argc 1, "/a\0", the buffer ends inside the padding.
        ("01000000" + "2f6100" + "0000", "failed padding"),
        // argc 2, "/a\0", padding, one argument only.
        ("02000000" + "2f6100" + "0000000000" + "6100", "failed truncated argc=2"),
        // argc 1, "/a\0", padding, an empty argv[0], then HOME=/x.
        ("01000000" + "2f6100" + "0000000000" + "00" + "484f4d453d2f7800", "ok argc=1 strings=1 home=yes"),
        // A negative argc word.
        ("ffffffff" + "2f6100", "failed argc=-1"),
    ])
    func malformedBuffersFailTheRead(_ hex: String, _ expected: String) throws {
        let probe = try mcpProbe()
        let process = Process()
        process.executableURL = probe
        process.arguments = ["procargs-bytes", hex]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        // Hard bound: polls, never blocks in `waitid`; killed after 20 s.
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            Issue.record("the procargs-bytes probe did not finish")
            return
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(process.terminationStatus == 0, "\(text)")
        #expect(text == expected)
    }
}
#endif
