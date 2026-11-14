#if canImport(Darwin)
import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing
@testable import RVMCP

/// Polls `condition` for up to `seconds`; never blocks in a wait call.
private func eventually(_ seconds: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while condition() == false {
        guard Date() < deadline else { return false }
        usleep(20_000)
    }
    return true
}

/// Runs `executable` to its end and returns its output lines by their first
/// word. Hard bound: killed, and the test fails, after 20 seconds; the wait
/// polls instead of blocking in `waitid`.
private func probeLines(_ executable: String, _ arguments: [String]) throws -> [String: String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let finished = eventually(20) { process.isRunning == false }
    if finished == false {
        kill(process.processIdentifier, SIGKILL)
        Issue.record("the signal probe did not finish")
    }
    #expect(eventually(5) { process.isRunning == false })
    #expect(process.terminationReason == .exit && process.terminationStatus == 0)
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    var lines: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 1)
        lines[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
    }
    return lines
}

/// Read only: whether this process ignores none of the three, so the probe
/// starts with the defaults. A runner started under `nohup` does not.
private let ignoresNone = MCPShutdownSignals.handled.allSatisfy { number in
    var current = sigaction()
    let ignore = unsafeBitCast(SIG_IGN as sig_t?, to: Int.self)
    return sigaction(number, nil, &current) == 0 && unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self) != ignore
}

/// Serialized: the SIGURG tests share one process-wide signal.
@Suite("rv mcp serve: shutdown on a signal", .serialized)
struct MCPShutdownSignalTests {
    /// SIGURG is discarded by default, so sending it to this process ends
    /// nothing, and the test changes no disposition (`catching: false`).
    @Test(.timeLimit(.minutes(1)))
    func aHandledSignalReachesTheHandlerUntilCancelled() {
        let heard = Mutex<[Int32]>([])
        let signals = MCPShutdownSignals([SIGURG], catching: false)
        signals.forward { heard.withLock { $0.append(SIGURG) } }
        #expect(kill(getpid(), SIGURG) == 0)
        #expect(eventually { heard.withLock { $0 } == [SIGURG] })
        #expect(signals.first == SIGURG)
        signals.cancel()
        #expect(kill(getpid(), SIGURG) == 0)
        usleep(200_000)
        #expect(heard.withLock { $0 } == [SIGURG])
    }

    /// A signal heard before serve has a runtime to stop (while it plans,
    /// and probes with a stopped child) is passed on once it has one.
    @Test(.timeLimit(.minutes(1)))
    func aSignalHeardBeforeForwardingIsPassedOnOnce() {
        let signals = MCPShutdownSignals([SIGURG], catching: false)
        defer { signals.cancel() }
        #expect(kill(getpid(), SIGURG) == 0)
        #expect(eventually { signals.first == SIGURG })
        let heard = Mutex(0)
        signals.forward { heard.withLock { $0 += 1 } }
        #expect(heard.withLock { $0 } == 1)
        #expect(kill(getpid(), SIGURG) == 0)
        #expect(eventually { heard.withLock { $0 } == 2 })
    }

    /// In a child, so this process's dispositions never change. Installed:
    /// a real handler, not `SIG_IGN`, so a plain server spawned meanwhile
    /// starts with the defaults; the signal still reaches serve, which does
    /// not die of it; cancel puts the defaults back.
    @Test(.enabled(if: ignoresNone), .timeLimit(.minutes(1)))
    func caughtSignalsLeaveAPlainChildTheDefaultsAndAreRestored() throws {
        let lines = try probeLines(try mcpProbe().path, ["signals"])
        #expect(lines["inherited"] == "INT=default TERM=default HUP=default")
        #expect(lines["installed"] == "INT=handler TERM=handler HUP=handler")
        #expect(lines["child"] == "INT=default TERM=default HUP=default")
        #expect(lines["heard"] == "1 first \(SIGTERM)")
        #expect(lines["restored"] == "INT=default TERM=default HUP=default")
    }

    /// A signal rv inherited ignored (`nohup`) stays ignored, unhandled, and
    /// is left so, for serve and for its children.
    @Test(.enabled(if: ignoresNone), .timeLimit(.minutes(1)))
    func aSignalInheritedIgnoredStaysIgnored() throws {
        let lines = try probeLines("/usr/bin/nohup", [try mcpProbe().path, "signals"])
        #expect(lines["inherited"] == "INT=default TERM=default HUP=ignore")
        #expect(lines["installed"] == "INT=handler TERM=handler HUP=ignore")
        // Serve adds nothing: the child keeps HUP ignored, unless Foundation's
        // `Process` resets it, which this does not depend on.
        #expect(["INT=default TERM=default HUP=ignore", "INT=default TERM=default HUP=default"].contains(lines["child"]))
        #expect(lines["restored"] == "INT=default TERM=default HUP=ignore")
    }

    /// Only a serve that names a server with placeholders catches signals;
    /// any other keeps the defaults.
    @Test func onlyAServeWithAPlaceholderServerCatchesSignals() {
        let plain = MCPServerDefinition(name: "plain", command: "/bin/sh")
        let bound = MCPServerDefinition(name: "bound", command: "/bin/sh", placeholders: ["OPENAI_API_KEY"])
        #expect(MCPShutdownSignals.wanted(by: []) == false)
        #expect(MCPShutdownSignals.wanted(by: [plain]) == false)
        #expect(MCPShutdownSignals.wanted(by: [plain, bound]))
    }

    /// What the signal handler asks for: `run` stops every upstream and
    /// returns as if the client had closed its input.
    @Test(.timeLimit(.minutes(1)))
    func aShutdownRequestEndsRunAsTheClientLeavingWould() {
        let client = LineClient()
        let runtime = Self.runtime(client, connections: [])
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            runtime.run()
            done.signal()
        }
        runtime.requestShutdown()
        #expect(done.wait(timeout: .now() + 10) == .success)
        // The client reader thread ends with its input.
        try? client.toGateway.fileHandleForWriting.close()
    }

    /// A second request (a second Ctrl-C) cuts the grace short: a server
    /// that ignores SIGTERM is killed at once instead of after about 3 s.
    @Test(.timeLimit(.minutes(1)))
    func aSecondShutdownRequestKillsWithoutTheGrace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-hurry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid").path
        let launch = MCPUpstreamLaunch(
            server: "stubborn", executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; echo $$ > \"$0\"; exec /bin/sleep 30", pidFile], environment: [:])
        let client = LineClient()
        let runtime = Self.runtime(client, connections: [.process(launch)])
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            runtime.run()
            done.signal()
        }
        // Started once it wrote its pid. Never killed from here: if the hurry
        // fails, run's own schedule still kills it after about 3 s.
        #expect(eventually { FileManager.default.fileExists(atPath: pidFile) })
        let asked = Date()
        runtime.requestShutdown()
        runtime.requestShutdown()
        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(Date().timeIntervalSince(asked) < 1.5)
        try? client.toGateway.fileHandleForWriting.close()
    }

    private static func runtime(_ client: LineClient, connections: [MCPUpstreamConnection]) -> MCPGatewayRuntime {
        let core = MCPGatewayCore(
            configuration: MCPConfiguration(servers: []), upstreams: [],
            approvals: MCPApprovalGate(consumeGrant: { _, _, _, _, _ in .none }, request: { _, _, _, _, _ in nil }),
            pinning: .unenforced, recordForward: { _ in true })
        return MCPGatewayRuntime(
            core: core, connections: connections,
            input: client.toGateway.fileHandleForReading.fileDescriptor,
            output: client.fromGateway.fileHandleForWriting.fileDescriptor,
            audit: { _ in }, log: { _ in })
    }
}
#endif
