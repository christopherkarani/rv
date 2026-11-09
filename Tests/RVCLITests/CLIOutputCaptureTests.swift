import ArgumentParser
import Foundation
import Testing
@testable import RVCLI

struct CLIOutputCaptureTests {
    @Test func sinkSeparatesStdoutAndStderr() throws {
        let capture = CLIOutputCapture()
        try withCLIProcess(output: capture) {
            CommandContext.writeStdout("out-1 ")
            CommandContext.writeStderr("err-1\n")
            CommandContext.writeStdout("out-2")
            #expect(throws: ExitCode(3)) {
                try CommandContext.emit(stdout: "", stderr: "err-2\n", exitCode: 3)
            }
        }
        #expect(capture.stdout == "out-1 out-2")
        #expect(capture.stderr == "err-1\nerr-2\n")
    }

    @Test func failWritesMessageToStderrSink() throws {
        let capture = CLIOutputCapture()
        try withCLIProcess(output: capture) {
            #expect(throws: ExitCode(2)) {
                try CommandContext.fail("boom\n", exitCode: 2)
            }
        }
        #expect(capture.stderr == "boom\n")
        #expect(capture.stdout.isEmpty)
    }

    @Test func sinkIsScopedToTheInstalledContext() async throws {
        let first = CLIOutputCapture()
        let second = CLIOutputCapture()
        try await withCLIProcess(output: first) {
            CommandContext.writeStdout("a")
            try await withCLIProcess(output: second) {
                CommandContext.writeStdout("b")
            }
            CommandContext.writeStdout("c")
        }
        #expect(first.stdout == "ac")
        #expect(second.stdout == "b")
    }

    @Test func noContextOrNoSinkMeansNoRedirect() throws {
        // By construction: the sink is reachable only through the installed
        // context, so production (no context) and a context without a sink
        // both resolve to nil and take the FileHandle path.
        #expect(CLIProcess.context == nil)
        try withCLIProcess {
            #expect(CLIProcess.context != nil)
            #expect(CLIProcess.context?.output == nil)
        }
    }
}
