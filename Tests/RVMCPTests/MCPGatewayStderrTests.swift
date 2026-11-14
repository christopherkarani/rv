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

/// Pipe ends this test holds are never inherited by a child another test
/// starts meanwhile, which would keep a closed read end open.
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
        let process = Process()
        process.executableURL = try mcpProbe()
        process.arguments = ["stderr", String(1 << 20), "closed"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        closeOnExec(input)
        closeOnExec(output)
        closeOnExec(errors)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        killLater(process)
        try errors.fileHandleForReading.close()
        try input.fileHandleForWriting.close()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationReason == .exit && process.terminationStatus == 0, "\(text)")
        #expect(text == "returned\n")
    }
}
#endif
