#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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

/// `eventually`, polled off the concurrency pool.
private func eventuallyOffThePool(_ seconds: TimeInterval = 60, _ condition: @escaping @Sendable () -> Bool) async -> Bool {
    await offThePool { eventually(seconds, condition) }
}

/// A plain stdio server that notes every SIGTERM, SIGINT and SIGHUP it or
/// its child gets in `<argv[1]>.signals` (and exits on SIGTERM, unless
/// `<argv[1]>.ignore-term` exists). At start
/// it writes its SIGHUP disposition to `.start`, then forks a child in its
/// group and writes both pids to `.pids`. Its one tool, `wait`, is never
/// answered; a call to it is noted in `.called`. It outlives its input, so
/// only a signal ends it.
let signalNotingServer = #"""
    import json, os, signal, sys, time
    record = sys.argv[1]
    def note(suffix, text):
        with open(record + suffix, "a") as f:
            f.write(text + "\n")
    hup = signal.getsignal(signal.SIGHUP)
    note(".start", "HUP=" + ("ignore" if hup == signal.SIG_IGN else "default" if hup == signal.SIG_DFL else "handler"))
    stubborn = os.path.exists(record + ".ignore-term")
    def heard(number, frame):
        note(".signals", signal.Signals(number).name[3:])
        if number == signal.SIGTERM and not stubborn:
            os._exit(0)
    for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(number, heard)
    child = os.fork()
    if child == 0:
        time.sleep(600)
        os._exit(0)
    note(".pids", "%d %d" % (os.getpid(), child))
    for line in sys.stdin:
        msg = json.loads(line)
        method, mid = msg.get("method"), msg.get("id")
        if mid is None:
            continue
        if method == "initialize":
            result = {"protocolVersion": msg["params"]["protocolVersion"], "capabilities": {"tools": {}},
                      "serverInfo": {"name": "plain", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "wait", "inputSchema": {"type": "object"}}]}
        elif method == "tools/call":
            note(".called", "wait")
            continue
        else:
            continue
        print(json.dumps({"jsonrpc": "2.0", "id": mid, "result": result}), flush=True)
    time.sleep(600)
    """#

/// One run of `signalNotingServer`: its files are `<directory>/server.*`.
private struct NotingServer {
    let directory: URL

    init(ignoringTerm: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-mcp-signal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(signalNotingServer.utf8).write(to: script)
        if ignoringTerm { try Data().write(to: URL(fileURLWithPath: record + ".ignore-term")) }
    }

    var script: URL { directory.appendingPathComponent("server.py") }
    var record: String { directory.appendingPathComponent("server").path }

    var launch: MCPUpstreamLaunch {
        MCPUpstreamLaunch(
            server: "plain", executable: "/usr/bin/env", arguments: ["python3", "-u", script.path, record],
            environment: ["PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"])
    }

    func lines(_ suffix: String) -> [String] {
        let text = (try? String(contentsOfFile: record + suffix, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    var called: Bool { lines(".called").isEmpty == false }
    var pids: [pid_t] { lines(".pids").first?.split(separator: " ").compactMap { pid_t($0) } ?? [] }

    /// The test's own cleanup, whatever happened: kills what is still there.
    func remove() {
        for pid in pids where MCPGatewayRestartRuntimeTests.gone(pid) == false { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: directory)
    }

    static let call = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"wait","arguments":{}}}"#
}

/// Serialized: the SIGURG tests share one process-wide signal.
@Suite("rv mcp serve: shutdown on a signal", .serialized)
struct MCPShutdownSignalTests {
    /// SIGURG is discarded by default, so sending it to this process ends
    /// nothing. On macOS the test changes no disposition (`catching:
    /// false`); on Linux a signal is heard only through a handler, which
    /// `cancel` takes away again.
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

    /// A signal to a serve of one plain server, with a call in flight: the
    /// call gets its interrupted record, the server's group (its child
    /// too) is gone, and the first signal the server gets is rv's SIGTERM.
    @Test(.timeLimit(.minutes(5)), .enabled(if: python3Available))
    func aSignalEndsAPlainServeWithItsCallInterruptedAndItsGroupGone() async throws {
        let server = try NotingServer()
        defer { server.remove() }
        let definition = MCPServerDefinition(name: "plain", command: "python3", tools: MCPToolPolicy(allow: ["*"]))
        let core = MCPGatewayCore(
            configuration: MCPConfiguration(servers: [definition]), upstreams: [MCPGatewayCore.Upstream(definition: definition)],
            approvals: MCPApprovalGate(consumeGrant: { _, _, _, _, _ in .none }, request: { _, _, _, _, _ in nil }),
            pinning: .unenforced, recordForward: { _ in true })
        let run = GatewayRun(core: core, connections: [.process(server.launch)])
        let signals = MCPShutdownSignals([SIGURG], catching: false)
        defer { signals.cancel() }
        let runtime = run.runtime
        signals.forward { runtime.requestShutdown() }
        #expect(await run.initialize())
        run.client.send(NotingServer.call)
        #expect(await eventuallyOffThePool { server.called }, "the call never reached the server")
        #expect(kill(getpid(), SIGURG) == 0)
        let ended = await run.ended(within: 60)
        #expect(ended, "the signal did not end serve")
        if ended == false { _ = await run.finish() }
        #expect(run.audits.items.withLock { $0.filter { $0.tool == "wait" }.map(\.outcome) } == [.interrupted(grant: nil)])
        let pids = server.pids
        #expect(pids.count == 2)
        for pid in pids {
            #expect(await eventuallyOffThePool { MCPGatewayRestartRuntimeTests.gone(pid) }, "\(pid) is still running")
        }
        #expect(server.lines(".signals").first == "TERM", "\(server.lines(".signals"))")
        try? run.client.toGateway.fileHandleForWriting.close()
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
    /// that ignores SIGTERM is killed at once instead of being sent SIGTERM
    /// after about 2 s and SIGKILL a second later. The server notes every
    /// SIGTERM it gets, so the test checks which path ran, not how fast.
    @Test(.timeLimit(.minutes(1)))
    func aSecondShutdownRequestKillsWithoutTheGrace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-hurry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid").path
        let termFile = pidFile + ".term"
        let launch = MCPUpstreamLaunch(
            server: "stubborn", executable: "/bin/sh",
            arguments: [
                "-c", "trap 'echo TERM >> \"$0.term\"' TERM; echo $$ > \"$0\"; while :; do /bin/sleep 0.1; done",
                pidFile,
            ], environment: [:])
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
        runtime.requestShutdown()
        runtime.requestShutdown()
        #expect(done.wait(timeout: .now() + 20) == .success)
        // The graceful path's SIGTERM would have been noted within 0.1 s of
        // arriving, and SIGKILL follows it by a second.
        #expect(FileManager.default.fileExists(atPath: termFile) == false)
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

    /// A signal blocked in the installing thread is unblocked while it is
    /// handled, and blocked again by `cancel` on that thread. One thread
    /// throughout: nothing here suspends.
    @Test func aBlockedSignalIsUnblockedWhileHandledAndBlockedAgainOnCancel() {
        func blocked() -> Bool {
            var current = sigset_t()
            sigemptyset(&current)
            _ = pthread_sigmask(SIG_BLOCK, nil, &current)
            return sigismember(&current, SIGURG) == 1
        }
        var urgent = sigset_t()
        sigemptyset(&urgent)
        sigaddset(&urgent, SIGURG)
        _ = pthread_sigmask(SIG_BLOCK, &urgent, nil)
        defer { _ = pthread_sigmask(SIG_UNBLOCK, &urgent, nil) }
        #expect(blocked())
        let signals = MCPShutdownSignals([SIGURG], catching: false)
        #expect(blocked() == false, "a handled signal stayed blocked")
        signals.cancel()
        #expect(blocked(), "cancel did not block it again")
    }

    /// Without the relay that makes signals heard on Linux, nothing is
    /// installed and serve is told so (`installed`): it refuses to run
    /// rather than run with no handler.
    @Test func withoutItsRelayNothingIsInstalled() {
        var before = sigaction()
        _ = sigaction(SIGURG, nil, &before)
        let signals = MCPShutdownSignals([SIGURG], catching: true, relay: { _ in false })
        defer { signals.cancel() }
        #expect(signals.installed == false)
        var after = sigaction()
        _ = sigaction(SIGURG, nil, &after)
        #expect(Self.handlerBits(after) == Self.handlerBits(before))
        let relayed = MCPShutdownSignals([SIGURG], catching: false)
        defer { relayed.cancel() }
        #expect(relayed.installed)
    }

    /// Planning is not waited on once a signal is heard: a plan that never
    /// returns (a hung secret provider) still ends at the first signal, and
    /// after one heard before planning, no plan starts at all.
    @Test(.timeLimit(.minutes(1)))
    func aSignalEndsPlanningThatNeverReturns() {
        let signals = MCPShutdownSignals([SIGURG], catching: false)
        defer { signals.cancel() }
        let started = DispatchSemaphore(value: 0)
        let hung = DispatchSemaphore(value: 0)
        defer { hung.signal() }
        Thread.detachNewThread {
            _ = started.wait(timeout: .now() + 30)
            usleep(100_000)
            kill(getpid(), SIGURG)
        }
        let planned: Int? = signals.plan {
            started.signal()
            // Never returns while the test waits on it.
            _ = hung.wait(timeout: .now() + 120)
            return 0
        }
        #expect(planned == nil)
        #expect(signals.first == SIGURG)
        let ran = Mutex(false)
        let late: Int? = signals.plan {
            ran.withLock { $0 = true }
            return 1
        }
        #expect(late == nil, "a plan after a signal was used")
        usleep(200_000)
        #expect(ran.withLock { $0 } == false, "a plan started after a signal was heard")
        let quiet = MCPShutdownSignals([SIGURG], catching: false)
        defer { quiet.cancel() }
        #expect(quiet.plan { 7 } == 7)
    }

    private static func handlerBits(_ action: sigaction) -> Int {
        #if canImport(Darwin)
        unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self)
        #else
        unsafeBitCast(action.__sigaction_handler.sa_handler, to: Int.self)
        #endif
    }

    /// In a child, so this process's dispositions never change. Installed:
    /// a real handler, not `SIG_IGN`, so a plain server spawned meanwhile
    /// starts with the defaults; the signal still reaches serve, which does
    /// not die of it; cancel puts the defaults back. The probe first sets
    /// the three to the default itself, so a runner started under `nohup`
    /// runs this test too rather than skipping it.
    @Test(.timeLimit(.minutes(1)))
    func caughtSignalsLeaveAPlainChildTheDefaultsAndAreRestored() throws {
        let lines = try probeLines(try mcpSignalProbe().path, ["signals", "INT", "TERM", "HUP"])
        #expect(lines["inherited"] == "INT=default TERM=default HUP=default")
        #expect(lines["installed"] == "INT=handler TERM=handler HUP=handler")
        #expect(lines["child"] == "INT=default TERM=default HUP=default")
        #expect(lines["heard"] == "1 first \(SIGTERM)")
        #expect(lines["restored"] == "INT=default TERM=default HUP=default")
    }

    /// A signal rv inherited ignored (`nohup`) stays ignored, unhandled, and
    /// is left so, for serve and for its children. `nohup` ignores HUP; the
    /// probe sets INT and TERM to the default whatever the runner had.
    @Test(.timeLimit(.minutes(1)))
    func aSignalInheritedIgnoredStaysIgnored() throws {
        let lines = try probeLines("/usr/bin/nohup", [try mcpSignalProbe().path, "signals", "INT", "TERM"])
        #expect(lines["inherited"] == "INT=default TERM=default HUP=ignore")
        #expect(lines["installed"] == "INT=handler TERM=handler HUP=ignore")
        // Serve adds nothing: the child keeps HUP ignored, unless Foundation's
        // `Process` resets it, which this does not depend on.
        #expect(["INT=default TERM=default HUP=ignore", "INT=default TERM=default HUP=default"].contains(lines["child"]))
        #expect(lines["restored"] == "INT=default TERM=default HUP=ignore")
    }

    /// The real dispositions, in the probe: SIGTERM, SIGINT or SIGHUP to a
    /// serve of one plain server with a call in flight ends serve as killed
    /// by that signal (128 plus it), after the call's interrupted record,
    /// with the server's group gone and rv's SIGTERM the first signal the
    /// server got.
    @Test(.timeLimit(.minutes(5)), .enabled(if: python3Available), arguments: [SIGTERM, SIGINT, SIGHUP])
    func aRealSignalEndsAPlainServeWithItsCallInterruptedAndItsGroupGone(_ number: Int32) async throws {
        let server = try NotingServer()
        defer { server.remove() }
        let serve = try ProbeServe(server, prefix: [], flags: ["INT", "TERM", "HUP"])
        defer { serve.kill() }
        #expect(await serve.initialize())
        // Listed first: with pins enforced, a call before the listing is refused.
        #expect(await serve.listed())
        serve.client.send(NotingServer.call)
        #expect(await eventuallyOffThePool { server.called }, "the call never reached the server: \(serve.drain())")
        #expect(kill(serve.process.processIdentifier, number) == 0)
        #expect(await eventuallyOffThePool { serve.process.isRunning == false }, "serve did not end")
        let process = serve.process
        #expect(process.isRunning == false && process.terminationReason == .exit, "serve was killed by the signal")
        #expect(process.isRunning == false && process.terminationStatus == 128 + number)
        #expect(serve.lines("audit") == ["wait interrupted"])
        let pids = server.pids
        #expect(pids.count == 2)
        for pid in pids {
            #expect(await eventuallyOffThePool { MCPGatewayRestartRuntimeTests.gone(pid) }, "\(pid) is still running")
        }
        #expect(server.lines(".signals").first == "TERM", "\(server.lines(".signals"))")
    }

    /// Serve started with SIGINT, SIGTERM and SIGHUP blocked (a parent
    /// thread's mask passes to what it starts; python execs the probe with
    /// them blocked, so every thread of it starts so) still hears them: it
    /// unblocks what it handles. A SIGTERM ends it as killed by it, after
    /// its server got rv's own SIGTERM. Linux is where this guards: macOS
    /// hears a signal through a kqueue source even while it is blocked, so
    /// there it passes with the unblock removed too (checked).
    @Test(.timeLimit(.minutes(5)), .enabled(if: python3Available))
    func aServeStartedWithItsSignalsBlockedStillHearsThem() async throws {
        let server = try NotingServer()
        defer { server.remove() }
        let blocking = "import os, signal, sys; "
            + "signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM, signal.SIGHUP}); "
            + "os.execv(sys.argv[1], sys.argv[1:])"
        let serve = try ProbeServe(server, prefix: ["/usr/bin/env", "python3", "-c", blocking], flags: ["INT", "TERM", "HUP"])
        defer { serve.kill() }
        #expect(await serve.initialize())
        #expect(await eventuallyOffThePool { server.pids.count == 2 })
        #expect(kill(serve.process.processIdentifier, SIGTERM) == 0)
        let process = serve.process
        #expect(await eventuallyOffThePool(30) { process.isRunning == false }, "serve did not hear SIGTERM")
        #expect(process.isRunning == false && process.terminationReason == .exit)
        #expect(process.isRunning == false && process.terminationStatus == 128 + SIGTERM)
        #expect(server.lines(".signals").first == "TERM", "\(server.lines(".signals"))")
    }

    /// A server starts with every signal at its default, even one serve
    /// inherited ignored (`nohup`'s SIGHUP): rv, not the server, decides
    /// when it stops, and it sends SIGTERM to the server's group.
    @Test(.timeLimit(.minutes(5)), .enabled(if: python3Available))
    func aServerStartsWithTheDefaultsWhateverServeInheritedIgnored() async throws {
        let server = try NotingServer()
        defer { server.remove() }
        let serve = try ProbeServe(server, prefix: ["/usr/bin/nohup"], flags: ["INT", "TERM"])
        defer { serve.kill() }
        #expect(await serve.initialize())
        #expect(await eventuallyOffThePool { server.lines(".start").isEmpty == false })
        #expect(server.lines(".start") == ["HUP=default"])
        #expect(await serve.ends(within: 60) == 0)
    }

    /// Serve sets SIGCHLD back to its default when it inherited it ignored:
    /// an ignored SIGCHLD reaps a server by itself, and its supervisor could
    /// then neither kill what is left of its group nor learn how it ended.
    @Test(.timeLimit(.minutes(5)), .enabled(if: python3Available))
    func serveTakesBackAnInheritedChildSignalIgnore() async throws {
        let server = try NotingServer()
        defer { server.remove() }
        let serve = try ProbeServe(server, prefix: [], flags: ["INT", "TERM", "HUP", "CHLD-ignored"])
        defer { serve.kill() }
        #expect(await serve.initialize())
        #expect(serve.lines("chld") == ["default"])
        #expect(await serve.ends(within: 60) == 0)
    }

    /// A second signal ends serve at once: a server that outlives SIGTERM
    /// is killed without the grace (it never gets rv's SIGTERM, due 60 s
    /// after the first signal), and serve exits as killed by the first one.
    @Test(.timeLimit(.minutes(5)), .enabled(if: python3Available))
    func aSecondRealSignalKillsWhatIsLeftAtOnce() async throws {
        let server = try NotingServer(ignoringTerm: true)
        defer { server.remove() }
        let serve = try ProbeServe(server, prefix: [], flags: ["INT", "TERM", "HUP", "long-grace"])
        defer { serve.kill() }
        #expect(await serve.initialize())
        #expect(await eventuallyOffThePool { server.pids.count == 2 })
        #expect(kill(serve.process.processIdentifier, SIGINT) == 0)
        // Far inside the 60 s serve gives a server before its SIGTERM.
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(kill(serve.process.processIdentifier, SIGTERM) == 0)
        let process = serve.process
        #expect(await eventuallyOffThePool { process.isRunning == false }, "serve did not end")
        #expect(process.isRunning == false && process.terminationReason == .exit)
        #expect(process.isRunning == false && process.terminationStatus == 128 + SIGINT)
        for pid in server.pids {
            #expect(await eventuallyOffThePool { MCPGatewayRestartRuntimeTests.gone(pid) }, "\(pid) is still running")
        }
        #expect(server.lines(".signals").contains("TERM") == false, "\(server.lines(".signals"))")
    }

    /// A signal while serve plans ends it at once, as killed by that
    /// signal, however long planning would take: no server is started.
    @Test(.timeLimit(.minutes(5)), .enabled(if: python3Available), arguments: [SIGTERM, SIGINT, SIGHUP])
    func aRealSignalWhilePlanningEndsServeAtOnce(_ number: Int32) async throws {
        let server = try NotingServer()
        defer { server.remove() }
        let serve = try ProbeServe(server, prefix: [], flags: ["INT", "TERM", "HUP", "plan-hangs"])
        defer { serve.kill() }
        #expect(await eventuallyOffThePool { serve.lines("planning").isEmpty == false }, "planning never started")
        #expect(kill(serve.process.processIdentifier, number) == 0)
        let process = serve.process
        #expect(await eventuallyOffThePool(10) { process.isRunning == false }, "serve did not end")
        #expect(process.isRunning == false && process.terminationReason == .exit)
        #expect(process.isRunning == false && process.terminationStatus == 128 + number)
        #expect(server.pids.isEmpty, "a server was started")
    }
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

/// `rv-mcp-probe serve` over `server`, with this test as its client.
/// Unchecked: `Process` is only read here, and its own state is locked.
private final class ProbeServe: @unchecked Sendable {
    let process: Process
    let client: LineClient
    let directory: URL

    init(_ server: NotingServer, prefix: [String], flags: [String]) throws {
        let probe = try mcpSignalProbe().path
        let process = Process()
        let arguments = [probe, "serve", server.directory.path, server.script.path] + flags
        process.executableURL = URL(fileURLWithPath: prefix.first ?? probe)
        process.arguments = prefix.isEmpty ? Array(arguments.dropFirst()) : Array(prefix.dropFirst()) + arguments
        let client = LineClient()
        process.standardInput = client.toGateway
        process.standardOutput = client.fromGateway
        try process.run()
        self.process = process
        self.client = client
        directory = server.directory
    }

    func lines(_ name: String) -> [String] {
        let text = (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    func initialize() async -> Bool {
        client.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        let reply = await client.next(timeout: 120)
        client.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        return reply?["result"]?["serverInfo"]?["name"] == .string("rv")
    }

    func listed() async -> Bool {
        client.send(#"{"jsonrpc":"2.0","id":10,"method":"tools/list"}"#)
        while let message = await client.next(timeout: 120) {
            if message["id"] == .int(10) { return message["result"]?["tools"]?.arrayValue?.count == 1 }
        }
        return false
    }

    /// What serve has written to the client and not yet read, for a failure message.
    func drain() -> String {
        var lines: [String] = []
        while let message = client.receive(timeout: 2) { lines.append("\(message)") }
        return lines.joined(separator: "\n")
    }

    /// Closes serve's input and returns its exit status, or nil if it did
    /// not exit by itself in time.
    func ends(within seconds: TimeInterval) async -> Int32? {
        try? client.toGateway.fileHandleForWriting.close()
        guard await eventuallyOffThePool(seconds, { self.process.isRunning == false }) else { return nil }
        return process.terminationReason == .exit ? process.terminationStatus : nil
    }

    func kill() {
        #if canImport(Darwin)
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        #else
        if process.isRunning { Glibc.kill(process.processIdentifier, SIGKILL) }
        #endif
    }
}
