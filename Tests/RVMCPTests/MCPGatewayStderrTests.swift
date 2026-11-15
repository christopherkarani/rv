#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import RVMCP

private final class Started: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

/// The probe ends within 30 s or is killed, so a hung write fails the test
/// instead of holding it. Only a probe still running is killed.
private func killLater(_ process: Process) {
    let started = Started(process)
    DispatchQueue(label: "rv.test.stderr.watchdog").asyncAfter(deadline: .now() + 30) {
        if started.process.isRunning { kill(started.process.processIdentifier, SIGKILL) }
    }
}

/// Pipe ends this test holds are not inherited by a child another test
/// spawns later without POSIX_SPAWN_CLOEXEC_DEFAULT (Foundation's `Process`
/// passes none on macOS, measured). Darwin has no pipe2, so a spawn between
/// `Pipe()` and this call can still inherit an end; here that only delays
/// EOF until that child exits. The closed-stderr tests do not depend on it:
/// the probe makes and closes its own stderr.
private func closeOnExec(_ pipe: Pipe) {
    _ = fcntl(pipe.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
    _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
}

/// `MCPGatewayRuntime.writeStderrLine`, serve's one stderr writer, run in
/// the probe so this process's stderr and signal dispositions are untouched.
@Suite("MCP gateway stderr writer")
struct MCPGatewayStderrTests {
    /// 4 MB through a 64 KB pipe, under a 1 ms SIGALRM without SA_RESTART:
    /// writes come back short or interrupted, and the line still arrives
    /// whole, once.
    @Test(.timeLimit(.minutes(1)))
    func anInterruptedLongLineArrivesWhole() throws {
        let count = 4 << 20
        let process = Process()
        process.executableURL = try mcpProbe()
        process.arguments = ["stderr", String(count), "interrupted"]
        let output = Pipe(), errors = Pipe()
        closeOnExec(output)
        closeOnExec(errors)
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        killLater(process)
        let written = errors.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationReason == .exit && process.terminationStatus == 0, "\(text)")
        #expect(text == "returned\n")
        #expect(written.count == count + 1)
        #expect(written.dropLast().allSatisfy { $0 == UInt8(ascii: "x") } && written.last == 0x0A)
    }

    /// With SIGPIPE ignored, as serve does, a write to a stderr nobody reads
    /// fails with EPIPE and returns. `FileHandle.write` raised there instead,
    /// which ended the process.
    @Test(.timeLimit(.minutes(1)))
    func aClosedStderrReturnsInsteadOfRaising() throws {
        try Self.expectReturnsOnAClosedStderr("closed")
    }

    /// With SIGPIPE at its default, as while serve plans its servers, the
    /// write still fails and returns: the writer does not depend on the
    /// process's disposition, so a closed stderr cannot end serve there.
    @Test(.timeLimit(.minutes(1)))
    func aClosedStderrReturnsWithSIGPIPEAtItsDefault() throws {
        try Self.expectReturnsOnAClosedStderr("closed-default")
    }

    static func expectReturnsOnAClosedStderr(_ mode: String) throws {
        let process = Process()
        process.executableURL = try mcpProbe()
        process.arguments = ["stderr", String(1 << 20), mode]
        let output = Pipe()
        closeOnExec(output)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        killLater(process)
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationReason == .exit && process.terminationStatus == 0, "\(mode): \(text)")
        #expect(text == "returned\n", "\(mode)")
    }
}
#endif
