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
}
#endif
