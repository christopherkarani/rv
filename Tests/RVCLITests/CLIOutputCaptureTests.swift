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

    @Test func sinkIsScopedToTheInstalledContext() throws {
        let first = CLIOutputCapture()
        let second = CLIOutputCapture()
        try withCLIProcess(output: first) {
            CommandContext.writeStdout("a")
            try withCLIProcess(output: second) {
                CommandContext.writeStdout("b")
            }
            CommandContext.writeStdout("c")
        }
        #expect(first.stdout == "ac")
        #expect(second.stdout == "b")
    }

    @Test func sinkFollowsChildTasksAndConcurrentSinksStayApart() async throws {
        // Commands fan out through task groups (XPCClient) and `Task {}`
        // (InstallAnalytics); both inherit the task-local context. Sibling
        // contexts running concurrently must not see each other's output.
        let sinks = (0..<8).map { _ in CLIOutputCapture() }
        try await withThrowingTaskGroup(of: Void.self) { outer in
            for (index, sink) in sinks.enumerated() {
                outer.addTask {
                    try await withCLIProcess(output: sink) {
                        await withTaskGroup(of: Void.self) { group in
                            group.addTask { CommandContext.writeStderr("g\(index)\n") }
                        }
                        await Task { CommandContext.writeStdout("t\(index)") }.value
                    }
                }
            }
            try await outer.waitForAll()
        }
        for (index, sink) in sinks.enumerated() {
            #expect(sink.stdout == "t\(index)")
            #expect(sink.stderr == "g\(index)\n")
        }
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
