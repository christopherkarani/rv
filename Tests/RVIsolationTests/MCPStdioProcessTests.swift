import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import RVDomain
import Synchronization
import Testing
@testable import RVIsolation

// MARK: - Helpers

private func catProcess() async throws -> MCPStdioProcess {
    let process = MCPStdioProcess()
    try await process.spawn(MCPStdioProcessSpawn(executablePath: "/bin/cat"))
    return process
}

private func shellProcess(_ script: String) async throws -> MCPStdioProcess {
    let process = MCPStdioProcess()
    try await process.spawn(MCPStdioProcessSpawn(executablePath: "/bin/sh", arguments: ["-c", script]))
    return process
}

private func expectClosed(_ operation: () async throws -> Data) async {
    do {
        _ = try await operation()
        Issue.record("expected transportClosed")
    } catch let error as MCPTransportError {
        #expect(error == .transportClosed)
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

private func expectMalformed(_ operation: () async throws -> Data) async {
    do {
        _ = try await operation()
        Issue.record("expected malformedEnvelope")
    } catch let error as MCPTransportError {
        #expect(error == .malformedEnvelope)
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

private func expectTimeout(_ operation: () async throws -> Data) async {
    do {
        _ = try await operation()
        Issue.record("expected requestTimeout")
    } catch let error as MCPTransportError {
        #expect(error == .requestTimeout)
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

private func expectOverloaded(_ operation: () async throws -> Data) async {
    do {
        _ = try await operation()
        Issue.record("expected exchangeOverloaded")
    } catch let error as MCPTransportError {
        #expect(error == .exchangeOverloaded)
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

private func expectCancellation(_ operation: () async throws -> Data) async {
    do {
        _ = try await operation()
        Issue.record("expected CancellationError")
    } catch is CancellationError {
        // Expected.
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

private func waitUntilStopped(_ process: MCPStdioProcess) async {
    for _ in 0..<200 {
        if await process.isRunning == false { return }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
}

private func sessionForChannel(token: String = "caller") throws -> MCPTransportSession {
    MCPTransportSession(
        id: MCPSessionID(),
        resource: try #require(MCPResourceID(rawValue: "test-resource")),
        callerToken: MCPCallerToken(rawValue: token),
        kind: .stdio
    )
}

private struct FramedStubError: Error {}

private func scriptedChunks(_ chunks: [Data?]) -> () async throws -> Data? {
    let remaining = Mutex(chunks)
    return {
        remaining.withLock { queue in
            queue.isEmpty ? nil : queue.removeFirst()
        }
    }
}

private func openFDCount() -> Int {
    #if os(Linux)
    let dir = "/proc/self/fd"
    #else
    let dir = "/dev/fd"
    #endif
    return (try? FileManager.default.contentsOfDirectory(atPath: dir).count) ?? -1
}

private func childCount(matching pattern: String) -> Int {
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    probe.arguments = ["-f", pattern]
    let out = Pipe()
    probe.standardOutput = out
    probe.standardError = FileHandle.nullDevice
    do {
        try probe.run()
    } catch {
        return -1
    }
    probe.waitUntilExit()
    let text = (try? out.fileHandleForReading.readToEnd()) ?? Data()
    return String(data: text, encoding: .utf8)?.split(separator: "\n").count ?? -1
}

@Suite("MCPStdioProcess", .serialized)
struct MCPStdioProcessTests {
    // MARK: - Spawn

    @Test func spawnCatRuns() async throws {
        let process = try await catProcess()
        #expect(await process.isRunning == true)
        await process.close()
    }

    @Test func doubleSpawnIsRejected() async throws {
        let process = try await catProcess()
        do {
            try await process.spawn(MCPStdioProcessSpawn(executablePath: "/bin/cat"))
            Issue.record("expected alreadySpawned")
        } catch {
            #expect(error == .alreadySpawned)
        }
        await process.close()
    }

    @Test func spawnAfterCloseIsRejected() async throws {
        let process = try await catProcess()
        await process.close()
        do {
            try await process.spawn(MCPStdioProcessSpawn(executablePath: "/bin/cat"))
            Issue.record("expected alreadySpawned")
        } catch {
            #expect(error == .alreadySpawned)
        }
    }

    @Test func spawnRejectsRelativePath() async {
        let process = MCPStdioProcess()
        do {
            try await process.spawn(MCPStdioProcessSpawn(executablePath: "bin/cat"))
            Issue.record("expected spawnFailed")
        } catch {
            #expect(error == .spawnFailed)
        }
        #expect(await process.isRunning == false)
    }

    @Test func spawnRejectsMissingExecutable() async {
        let process = MCPStdioProcess()
        do {
            try await process.spawn(MCPStdioProcessSpawn(executablePath: "/nonexistent/mcp-server"))
            Issue.record("expected spawnFailed")
        } catch {
            #expect(error == .spawnFailed)
        }
    }

    @Test func spawnRejectsDirectoryAsExecutable() async {
        let process = MCPStdioProcess()
        do {
            try await process.spawn(MCPStdioProcessSpawn(executablePath: "/tmp"))
            Issue.record("expected spawnFailed")
        } catch {
            #expect(error == .spawnFailed)
        }
    }

    @Test func spawnRejectsUnexecutableScript() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-badexec-\(UUID().uuidString)")
        try "not a script\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        defer { try? FileManager.default.removeItem(at: url) }
        let process = MCPStdioProcess()
        do {
            try await process.spawn(MCPStdioProcessSpawn(executablePath: url.path))
            Issue.record("expected spawnFailed")
        } catch {
            #expect(error == .spawnFailed)
        }
    }

    @Test func isAbsoluteExecutablePathMatrix() {
        #expect(MCPStdioProcess.isAbsoluteExecutablePath("/bin/cat") == true)
        #expect(MCPStdioProcess.isAbsoluteExecutablePath("bin/cat") == false)
        #expect(MCPStdioProcess.isAbsoluteExecutablePath("/nonexistent/x") == false)
    }

    // MARK: - Environment (oracle e2e stdio-mcp.test.ts: daemon env withheld)

    @Test func defaultEnvironmentWithholdsDaemonVariables() async throws {
        setenv("RV_X1_STDIO_CANARY", "present", 1)
        defer { unsetenv("RV_X1_STDIO_CANARY") }
        // Full-dict pin: absence of the canary plus exact presence of every
        // minimal entry (PATH, LANG=C, LC_ALL=C) — the allowlist starts the
        // child with nothing else.
        let process = try await shellProcess(
            "read a; /usr/bin/env | grep -c RV_X1_STDIO_CANARY; read b; /usr/bin/env | grep -c '^PATH=/usr/bin:/bin$'; read c; /usr/bin/env | grep -c '^LANG=C$'; read d; /usr/bin/env | grep -c '^LC_ALL=C$'"
        )
        let canary = try await process.send(Data("one".utf8))
        #expect(canary == Data("0".utf8))
        let path = try await process.send(Data("two".utf8))
        #expect(path == Data("1".utf8))
        let lang = try await process.send(Data("three".utf8))
        #expect(lang == Data("1".utf8))
        let lcAll = try await process.send(Data("four".utf8))
        #expect(lcAll == Data("1".utf8))
        await process.close()
    }

    @Test func customEnvironmentReachesChild() async throws {
        let process = MCPStdioProcess()
        try await process.spawn(
            MCPStdioProcessSpawn(
                executablePath: "/bin/sh",
                arguments: ["-c", "read a; /usr/bin/env | grep -c '^RV_X1_STDIO_CANARY=yes$'"],
                environment: ["RV_X1_STDIO_CANARY": "yes", "PATH": "/usr/bin:/bin"]
            )
        )
        #expect(try await process.send(Data("one".utf8)) == Data("1".utf8))
        await process.close()
    }

    // MARK: - Roundtrips over cat

    @Test func catRoundtripsOneFrame() async throws {
        let process = try await catProcess()
        #expect(try await process.send(Data("hello".utf8)) == Data("hello".utf8))
        await process.close()
    }

    @Test func catRoundtripsEmptyFrame() async throws {
        let process = try await catProcess()
        #expect(try await process.send(Data()) == Data())
        await process.close()
    }

    @Test func catRoundtripsMultibyteUTF8() async throws {
        let process = try await catProcess()
        let frame = Data("héllo-wörld-🎉".utf8)
        #expect(try await process.send(frame) == frame)
        await process.close()
    }

    @Test func catRoundtripsBinaryBytes() async throws {
        let process = try await catProcess()
        let frame = Data([0x00, 0x01, 0xFF, 0x7F, 0x80])
        #expect(try await process.send(frame) == frame)
        await process.close()
    }

    @Test func catRoundtripsAcrossChunkBoundaries() async throws {
        let process = try await catProcess()
        let frame = Data(repeating: 0x41, count: 8_192)
        #expect(try await process.send(frame) == frame)
        await process.close()
    }

    @Test func embeddedNewlineSplitsAcrossSends() async throws {
        let process = try await catProcess()
        #expect(try await process.send(Data("a\nb".utf8)) == Data("a".utf8))
        #expect(try await process.send(Data("c".utf8)) == Data("b".utf8))
        await process.close()
    }

    @Test func oversizedFrameRejectedBeforeWriting() async throws {
        let process = try await catProcess()
        await expectMalformed { try await process.send(Data(repeating: 0x41, count: 70_000)) }
        #expect(await process.isRunning == true)
        #expect(try await process.send(Data("still-alive".utf8)) == Data("still-alive".utf8))
        await process.close()
    }

    @Test func oversizedReplyLineIsMalformed() async throws {
        let process = try await shellProcess("read line; head -c 70000 /dev/zero | tr \"\\0\" \"A\"; echo")
        await expectMalformed { try await process.send(Data("go".utf8)) }
        await process.close()
    }

    @Test func oversizedReplyWithoutNewlineIsMalformed() async throws {
        let process = try await shellProcess(
            "read line; head -c 70000 /dev/zero | tr \"\\0\" \"A\"; sleep 5"
        )
        await expectMalformed { try await process.send(Data("go".utf8)) }
        await process.close()
    }

    // MARK: - Exchange errors

    @Test func sendBeforeSpawnIsClosed() async {
        await expectClosed { try await MCPStdioProcess().send(Data("x".utf8)) }
    }

    @Test func sendAfterCloseIsClosed() async throws {
        let process = try await catProcess()
        await process.close()
        await expectClosed { try await process.send(Data("x".utf8)) }
    }

    @Test func sendAfterChildExitIsClosed() async throws {
        let process = MCPStdioProcess()
        try await process.spawn(MCPStdioProcessSpawn(executablePath: "/usr/bin/true"))
        await waitUntilStopped(process)
        #expect(await process.isRunning == false)
        await expectClosed { try await process.send(Data("x".utf8)) }
        await process.close()
    }

    @Test func writeToClosedStdinIsClosed() async throws {
        let process = try await shellProcess("exec 0<&-; echo ready; sleep 5")
        let first = try? await process.send(Data("one".utf8))
        #expect(first == nil || first == Data("ready".utf8))
        await expectClosed { try await process.send(Data("two".utf8)) }
        await process.close()
    }

    @Test func cleanEOFIsClosed() async throws {
        let process = try await shellProcess("read line; exit 3")
        await expectClosed { try await process.send(Data("go".utf8)) }
        #expect(await process.waitForExit() == 3)
        await process.close()
    }

    @Test func partialLineAtEOFIsMalformed() async throws {
        let process = try await shellProcess("read line; printf partial; exit 0")
        await expectMalformed { try await process.send(Data("go".utf8)) }
        #expect(await process.waitForExit() == 0)
        await process.close()
    }

    // Sleep-ordered (150 ms), but the claim is deliberately weak: the
    // outcome is identical if the ordering inverts (send-after-close also
    // yields nil), so this proves only that no send succeeds around close,
    // never in-flight failure specifically.
    @Test func noSendSucceedsAroundClose() async throws {
        let process = try await shellProcess("sleep 5")
        async let first: Data? = try? await process.send(Data("x".utf8))
        async let second: Data? = try? await process.send(Data("y".utf8))
        try await Task.sleep(nanoseconds: 150_000_000)
        await process.close()
        #expect(await first == nil)
        #expect(await second == nil)
        #expect(await process.isRunning == false)
    }

    // MARK: - Exchange timeout (per-exchange deadline)

    @Test func exchangeTimeoutFailsClosed() async throws {
        let process = try await shellProcess("sleep 5")
        await expectTimeout { try await process.send(Data("x".utf8), timeoutSeconds: 0.2) }
        // The transport failed closed: the child is gone and later sends refuse.
        #expect(await process.isRunning == false)
        await expectClosed { try await process.send(Data("y".utf8)) }
        await process.close()
    }

    @Test func nonPositiveTimeoutFailsImmediately() async throws {
        let process = try await catProcess()
        for budget in [0.0, -1.0, Double.nan, Double.infinity] {
            await expectTimeout { try await process.send(Data("x".utf8), timeoutSeconds: budget) }
        }
        // The budget failed before queueing: the handle is unharmed.
        #expect(try await process.send(Data("alive".utf8)) == Data("alive".utf8))
        await process.close()
    }

    @Test func cancelledWaiterWithdrawsFromLock() async throws {
        let process = try await shellProcess("sleep 30")
        let occupant = Task { try await process.send(Data("x".utf8), timeoutSeconds: 30) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let waiter = Task { try await process.send(Data("y".utf8), timeoutSeconds: 30) }
        try await Task.sleep(nanoseconds: 300_000_000)
        waiter.cancel()
        await expectCancellation { try await waiter.value }
        // The occupant still owns the exchange: closing fails it closed,
        // and the withdrawn waiter never held the lock.
        await process.close()
        await expectClosed { try await occupant.value }
        await process.close()
    }

    @Test func waiterQueueIsBounded() async throws {
        let process = try await shellProcess("sleep 30")
        // The occupant holds the lock with a self-limiting budget: even if
        // scheduling slop leaves the queue short, the occupant times out
        // (failing the parked sends closed) instead of hanging this test.
        let occupant = Task { try? await process.send(Data("x".utf8), timeoutSeconds: 4) }
        try await Task.sleep(nanoseconds: 300_000_000)
        var waiters: [Task<Data, Error>] = []
        for _ in 0..<MCPStdioProcess.maximumExchangeWaiters {
            waiters.append(Task { try await process.send(Data("y".utf8), timeoutSeconds: 30) })
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        // One more overflows instead of queueing.
        await expectOverloaded { try await process.send(Data("z".utf8), timeoutSeconds: 30) }
        // Tear down: every parked send fails closed, none hangs.
        await process.close()
        for waiter in waiters {
            await expectClosed { try await waiter.value }
        }
        _ = await occupant.value
        await process.close()
    }

    // MARK: - Framing resync (oversize never poisons pairing)

    @Test func oversizedReplyDoesNotConfuseNextExchange() async throws {
        // A's 100 KiB reply line exceeds the cap, and its tail is still in
        // flight when the read throws: without the drain-to-newline resync,
        // B would frame A's tail as its own (successful) reply.
        let process = try await shellProcess(
            "read a; head -c 100000 /dev/zero | tr \"\\0\" \"A\"; echo; read b; echo \"ok-$b\""
        )
        await expectMalformed { try await process.send(Data("first".utf8)) }
        #expect(try await process.send(Data("second".utf8)) == Data("ok-second".utf8))
        await process.close()
    }

    @Test func undrainedReplyFailsTransportClosed() async throws {
        // Over-cap line with no trailing newline and a hung child: the
        // drain cannot resync, so the transport fails closed instead of
        // hanging (or pairing the next exchange onto a torn frame).
        let process = try await shellProcess(
            "read line; head -c 70000 /dev/zero | tr \"\\0\" \"A\"; exec sleep 30"
        )
        await expectMalformed { try await process.send(Data("go".utf8)) }
        #expect(await process.isRunning == false)
        await expectClosed { try await process.send(Data("x".utf8)) }
        await process.close()
    }

    @Test func oversizedReplyAtEOFResyncsToEmpty() async throws {
        // The child exits right after the fat line: the drain meets EOF and
        // resyncs to empty, so the next send fails closed at EOF instead of
        // reading stale framing.
        let process = try await shellProcess("read line; head -c 70000 /dev/zero | tr \"\\0\" \"A\"")
        await expectMalformed { try await process.send(Data("go".utf8)) }
        await expectClosed { try await process.send(Data("x".utf8)) }
        await process.close()
    }

    @Test func drainToNewlineResyncsFramingDirectly() async throws {
        // Direct resync coverage: a broken fd fails the drain (false),
        // EOF resyncs to empty (true), a newline resyncs to its tail (true).
        let process = MCPStdioProcess()
        #expect(await process.drainToNewline(fd: -1) == false)
        let null = open("/dev/null", O_RDONLY)
        #expect(null >= 0)
        #expect(await process.drainToNewline(fd: null) == true)
        close(null)
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("abc\ndef".utf8))
        try pipe.fileHandleForWriting.close()
        #expect(
            await process.drainToNewline(fd: pipe.fileHandleForReading.fileDescriptor) == true
        )
    }

    @Test func closeDuringDrainFailsTheSendClosed() async throws {
        // Close lands while the drain parks on a newline that never comes:
        // the retired fd fails the drain, and the send still reports the
        // original malformed reply (not the close underneath it).
        let process = try await shellProcess(
            "read line; head -c 70000 /dev/zero | tr \"\\0\" \"A\"; sleep 30"
        )
        let sender = Task { try await process.send(Data("go".utf8)) }
        try await Task.sleep(nanoseconds: 500_000_000)
        await process.close()
        await expectMalformed { try await sender.value }
        await process.close()
    }

    @Test func closeDuringBlockedWriteFailsTheSend() async throws {
        // A 64 KiB frame overfills the pipe against a child that never
        // reads, so the write parks; close retires the pipes and kills the
        // child underneath it, and the exchange fails closed.
        let process = try await shellProcess("sleep 30")
        let sender = Task {
            try await process.send(Data(repeating: 0x58, count: 65_536), timeoutSeconds: 30)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        await process.close()
        await expectClosed { try await sender.value }
        await process.close()
    }

    @Test func cancelDuringReadFailsTheTransportClosed() async throws {
        // Cancelling an in-flight exchange fails the transport closed: the
        // reply that may already be in flight must never frame a later
        // exchange, so no later exchange is allowed.
        let process = try await shellProcess("sleep 30")
        let reader = Task { try await process.send(Data("x".utf8), timeoutSeconds: 30) }
        try await Task.sleep(nanoseconds: 300_000_000)
        reader.cancel()
        await expectCancellation { try await reader.value }
        #expect(await process.isRunning == false)
        await expectClosed { try await process.send(Data("y".utf8)) }
        await process.close()
    }

    @Test func sendInCancelledGroupFailsFast() async throws {
        // A child of an already-cancelled group starts cancelled: the send
        // fails before touching the pipe, and the handle is unharmed.
        let process = try await catProcess()
        await withThrowingTaskGroup(of: Void.self) { group in
            group.cancelAll()
            group.addTask {
                await expectCancellation { try await process.send(Data("x".utf8)) }
            }
        }
        #expect(try await process.send(Data("alive".utf8)) == Data("alive".utf8))
        await process.close()
    }

    @Test func cancelledGroupChildNeverQueuesBehindOccupant() async throws {
        // Same, behind a held lock: the cancelled waiter fails before
        // queueing instead of parking, and the occupant is unaffected.
        let process = try await shellProcess("sleep 30")
        let occupant = Task { try? await process.send(Data("x".utf8), timeoutSeconds: 30) }
        try await Task.sleep(nanoseconds: 300_000_000)
        await withThrowingTaskGroup(of: Void.self) { group in
            group.cancelAll()
            group.addTask {
                await expectCancellation { try await process.send(Data("y".utf8), timeoutSeconds: 30) }
            }
        }
        await process.close()
        _ = await occupant.value
        await process.close()
    }

    // MARK: - Close + waitForExit (oracle finally: always close)

    @Test func closeWithoutSpawnIsNoOp() async {
        let process = MCPStdioProcess()
        await process.close()
        #expect(await process.isRunning == false)
        #expect(await process.waitForExit() == nil)
    }

    @Test func doubleCloseIsNoOp() async throws {
        let process = try await catProcess()
        await process.close()
        await process.close()
        #expect(await process.isRunning == false)
    }

    @Test func closeExitsCatNaturally() async throws {
        let process = try await catProcess()
        await process.close()
        #expect(await process.isRunning == false)
        #expect(await process.waitForExit() == 0)
    }

    @Test func closeTerminatesSleepingChild() async throws {
        let process = try await shellProcess("sleep 5")
        await process.close()
        #expect(await process.isRunning == false)
        #expect(await process.waitForExit() != nil)
    }

    @Test func closeKillsTermIgnoringChild() async throws {
        let process = try await shellProcess("trap \"\" TERM; echo ready; sleep 5")
        #expect(try await process.send(Data("sync".utf8)) == Data("ready".utf8))
        await process.close()
        #expect(await process.isRunning == false)
        #expect(await process.waitForExit() != nil)
    }

    @Test func waitForExitReportsNaturalStatus() async throws {
        let process = MCPStdioProcess()
        try await process.spawn(MCPStdioProcessSpawn(executablePath: "/usr/bin/true"))
        #expect(await process.waitForExit() == 0)
        #expect(await process.waitForExit() == 0)
        await process.close()
    }

    @Test func waitForExitReachesConcurrentWaiters() async throws {
        let process = try await shellProcess("exit 7")
        async let first = process.waitForExit()
        async let second = process.waitForExit()
        #expect(await first == 7)
        #expect(await second == 7)
        await process.close()
    }

    // MARK: - readChunk (direct)

    @Test func readChunkSyncReadsBytesEOFAndError() throws {
        let pipe = Pipe()
        let readFD = pipe.fileHandleForReading.fileDescriptor
        pipe.fileHandleForWriting.write(Data([1, 2, 3]))
        let bytes = try MCPStdioProcess.readChunkSync(fd: readFD)
        #expect(bytes == Data([1, 2, 3]))
        try pipe.fileHandleForWriting.close()
        let eof = try MCPStdioProcess.readChunkSync(fd: readFD)
        #expect(eof == nil)
        pipe.fileHandleForReading.closeFile()
        do {
            _ = try MCPStdioProcess.readChunkSync(fd: readFD)
            Issue.record("expected throw on closed fd")
        } catch let error as MCPTransportError {
            #expect(error == .transportClosed)
        }
    }

    @Test func readChunkAsyncReadsAndEOF() async throws {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data("hi".utf8))
        try pipe.fileHandleForWriting.close()
        #expect(try await MCPStdioProcess.readChunk(fd: pipe.fileHandleForReading.fileDescriptor) == Data("hi".utf8))
        #expect(try await MCPStdioProcess.readChunk(fd: pipe.fileHandleForReading.fileDescriptor) == nil)
    }

    @Test func readChunkThrowsWhenFDErrors() async {
        let pipe = Pipe()
        let readFD = pipe.fileHandleForReading.fileDescriptor
        let task = Task { try await MCPStdioProcess.readChunk(fd: readFD) }
        pipe.fileHandleForReading.closeFile()
        do {
            _ = try await task.value
            Issue.record("expected throw")
        } catch let error as MCPTransportError {
            #expect(error == .transportClosed)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    // MARK: - readFramedLine (scripted, deterministic)

    @Test func framedLineFromSingleChunk() async throws {
        let framed = try await MCPStdioProcess.readFramedLine(from: Data()) {
            Data("hi\n".utf8)
        }
        #expect(framed.line == Data("hi".utf8))
        #expect(framed.rest == Data())
    }

    @Test func framedLineCarriesOverReadRest() async throws {
        let framed = try await MCPStdioProcess.readFramedLine(from: Data(), nextChunk: scriptedChunks([Data("a\nb\n".utf8)]))
        #expect(framed.line == Data("a".utf8))
        #expect(framed.rest == Data("b\n".utf8))
    }

    @Test func framedLineAssemblesAcrossChunks() async throws {
        let framed = try await MCPStdioProcess.readFramedLine(
            from: Data("ab".utf8), nextChunk: scriptedChunks([Data("c".utf8), Data("d\nef".utf8)])
        )
        #expect(framed.line == Data("abcd".utf8))
        #expect(framed.rest == Data("ef".utf8))
    }

    @Test func framedLineRejectsOverCapLine() async throws {
        do {
            _ = try await MCPStdioProcess.readFramedLine(
                from: Data(),
                nextChunk: scriptedChunks([
                    Data(repeating: 0x41, count: 65_536),
                    Data(repeating: 0x41, count: 100) + Data("\n".utf8),
                ])
            )
            Issue.record("expected malformedEnvelope")
        } catch let error as MCPTransportError {
            #expect(error == .malformedEnvelope)
        }
    }

    @Test func framedLineRejectsOverCapBuffer() async throws {
        do {
            _ = try await MCPStdioProcess.readFramedLine(
                from: Data(),
                nextChunk: scriptedChunks([Data(repeating: 0x41, count: 65_536), Data([0x41])])
            )
            Issue.record("expected malformedEnvelope")
        } catch let error as MCPTransportError {
            #expect(error == .malformedEnvelope)
        }
    }

    @Test func framedLineCleanEOFIsClosed() async throws {
        do {
            _ = try await MCPStdioProcess.readFramedLine(from: Data(), nextChunk: scriptedChunks([nil]))
            Issue.record("expected transportClosed")
        } catch let error as MCPTransportError {
            #expect(error == .transportClosed)
        }
    }

    @Test func framedLinePartialEOFIsMalformed() async throws {
        do {
            _ = try await MCPStdioProcess.readFramedLine(
                from: Data("abc".utf8), nextChunk: scriptedChunks([nil])
            )
            Issue.record("expected malformedEnvelope")
        } catch let error as MCPTransportError {
            #expect(error == .malformedEnvelope)
        }
    }

    @Test func framedLineMapsReadErrorToClosed() async throws {
        do {
            _ = try await MCPStdioProcess.readFramedLine(from: Data()) {
                throw FramedStubError()
            }
            Issue.record("expected transportClosed")
        } catch let error as MCPTransportError {
            #expect(error == .transportClosed)
        }
    }

    @Test func framedLineToleratesEmptyChunk() async throws {
        let framed = try await MCPStdioProcess.readFramedLine(
            from: Data(), nextChunk: scriptedChunks([Data(), Data("a\n".utf8)])
        )
        #expect(framed.line == Data("a".utf8))
    }

    // MARK: - Latch (first reason wins)

    @Test func latchDeliversFirstReasonAndDropsRest() async {
        let latch = MCPStdioExitLatch()
        let reason = await withCheckedContinuation { continuation in
            latch.arm(continuation)
            latch.finish(.interrupted)
            latch.finish(.terminated)
        }
        #expect(reason == .interrupted)
    }

    // MARK: - Monitor statics (direct)

    @Test func isDevNullMatrix() throws {
        let null = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        defer { null.closeFile() }
        var nullStatus = stat()
        #expect(fstat(null.fileDescriptor, &nullStatus) == 0)
        #expect(MCPStdioExitMonitor.isDevNull(nullStatus, nullPath: "/dev/null") == true)
        let pipe = Pipe()
        var pipeStatus = stat()
        #expect(fstat(pipe.fileHandleForReading.fileDescriptor, &pipeStatus) == 0)
        #expect(MCPStdioExitMonitor.isDevNull(pipeStatus, nullPath: "/dev/null") == false)
        #expect(MCPStdioExitMonitor.isDevNull(pipeStatus, nullPath: "/nonexistent-null") == false)
    }

    @Test func stdinIsMonitorableMatrix() throws {
        let pipe = Pipe()
        var fifoStatus = stat()
        #expect(fstat(pipe.fileHandleForReading.fileDescriptor, &fifoStatus) == 0)
        #expect(MCPStdioExitMonitor.stdinIsMonitorable(fifoStatus) == true)
        var pair: [Int32] = [-1, -1]
        let socketResult: Int32 = pair.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return -1 }
            return socketpair(AF_UNIX, SOCK_STREAM, 0, base)
        }
        #expect(socketResult == 0)
        defer {
            for fd in pair { if fd >= 0 { close(fd) } }
        }
        var socketStatus = stat()
        #expect(fstat(pair[0], &socketStatus) == 0)
        #expect(MCPStdioExitMonitor.stdinIsMonitorable(socketStatus) == true)
        let null = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        defer { null.closeFile() }
        var nullStatus = stat()
        #expect(fstat(null.fileDescriptor, &nullStatus) == 0)
        #expect(MCPStdioExitMonitor.stdinIsMonitorable(nullStatus) == true)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-stdio-reg-\(UUID().uuidString)")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { handle.closeFile() }
        var fileStatus = stat()
        #expect(fstat(handle.fileDescriptor, &fileStatus) == 0)
        #expect(MCPStdioExitMonitor.stdinIsMonitorable(fileStatus) == false)
    }

    // MARK: - Watcher (direct)

    @Test func watcherEOFCallsBack() {
        let pipe = Pipe()
        pipe.fileHandleForWriting.closeFile()
        let fired = Mutex(false)
        let watcher = MCPStdioStdinWatcher(
            fd: pipe.fileHandleForReading.fileDescriptor,
            queue: DispatchQueue(label: "rv-stdio-test"),
            backoffMs: 10_000
        ) {
            fired.withLock { $0 = true }
        }
        watcher.start()
        defer { watcher.teardown() }
        watcher.handleActivity()
        #expect(fired.withLock { $0 } == true)
    }

    @Test func watcherDataBacksOffWithoutEOF() async throws {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data([7]))
        let fired = Mutex(false)
        let watcher = MCPStdioStdinWatcher(
            fd: pipe.fileHandleForReading.fileDescriptor,
            queue: DispatchQueue(label: "rv-stdio-test"),
            backoffMs: 10
        ) {
            fired.withLock { $0 = true }
        }
        watcher.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(fired.withLock { $0 } == false)
        watcher.teardown()
    }

    @Test func watcherReviveHonorsGenerations() {
        let pipe = Pipe()
        let watcher = MCPStdioStdinWatcher(
            fd: pipe.fileHandleForReading.fileDescriptor,
            queue: DispatchQueue(label: "rv-stdio-test"),
            backoffMs: 100_000
        ) {}
        watcher.start()
        defer { watcher.teardown() }
        watcher.maybeRevive(generation: 0)
        watcher.backoff()
        watcher.teardown()
        watcher.maybeRevive(generation: 0)
        watcher.maybeRevive(generation: 1)
    }

    // MARK: - Live lifetime (oracle waitForExit: SIGINT / SIGTERM / stdin end+close)

    @Test func liveLifetimeSeesClosedStdin() async {
        let pipe = Pipe()
        let fd = pipe.fileHandleForReading.fileDescriptor
        pipe.fileHandleForReading.closeFile()
        pipe.fileHandleForWriting.closeFile()
        let reason = await MCPStdioLifetime.live(stdinFD: fd, backoffMs: 10).waitForExit()
        #expect(reason == .stdinClosed)
    }

    @Test func liveLifetimeSeesDevNullAsEnded() async throws {
        let null = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        defer { null.closeFile() }
        let reason = await MCPStdioLifetime.live(stdinFD: null.fileDescriptor, backoffMs: 10).waitForExit()
        #expect(reason == .stdinEnded)
    }

    @Test func liveLifetimeSeesPipeEOFAsEnded() async throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.close()
        let reason = await MCPStdioLifetime.live(
            stdinFD: pipe.fileHandleForReading.fileDescriptor, backoffMs: 10
        ).waitForExit()
        #expect(reason == .stdinEnded)
    }

    @Test func liveLifetimeIgnoresDataAndHonorsSIGTERM() async throws {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data([9]))
        let lifetime = MCPStdioLifetime.live(stdinFD: pipe.fileHandleForReading.fileDescriptor, backoffMs: 10)
        let task = Task { await lifetime.waitForExit() }
        try await Task.sleep(nanoseconds: 250_000_000)
        kill(getpid(), SIGTERM)
        #expect(await task.value == .terminated)
        #expect(signal(SIGTERM, SIG_DFL) == nil)
    }

    @Test func liveLifetimeHonorsSIGINT() async throws {
        let pipe = Pipe()
        let lifetime = MCPStdioLifetime.live(stdinFD: pipe.fileHandleForReading.fileDescriptor, backoffMs: 10)
        let task = Task { await lifetime.waitForExit() }
        try await Task.sleep(nanoseconds: 100_000_000)
        kill(getpid(), SIGINT)
        #expect(await task.value == .interrupted)
        #expect(signal(SIGINT, SIG_DFL) == nil)
    }

    @Test func liveLifetimeHonorsSIGTERM() async throws {
        let pipe = Pipe()
        let lifetime = MCPStdioLifetime.live(stdinFD: pipe.fileHandleForReading.fileDescriptor, backoffMs: 10)
        let task = Task { await lifetime.waitForExit() }
        try await Task.sleep(nanoseconds: 100_000_000)
        kill(getpid(), SIGTERM)
        #expect(await task.value == .terminated)
    }

    @Test func liveLifetimeSkipsRegularFilesButKeepsSignals() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-stdio-life-\(UUID().uuidString)")
        try "data".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { handle.closeFile() }
        let lifetime = MCPStdioLifetime.live(stdinFD: handle.fileDescriptor, backoffMs: 10)
        let task = Task { await lifetime.waitForExit() }
        try await Task.sleep(nanoseconds: 100_000_000)
        kill(getpid(), SIGTERM)
        #expect(await task.value == .terminated)
    }

    @Test func liveLifetimeMonitorsCharacterDevices() async throws {
        let zero = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/zero"))
        defer { zero.closeFile() }
        let lifetime = MCPStdioLifetime.live(stdinFD: zero.fileDescriptor, backoffMs: 10)
        let task = Task { await lifetime.waitForExit() }
        try await Task.sleep(nanoseconds: 100_000_000)
        kill(getpid(), SIGTERM)
        #expect(await task.value == .terminated)
    }

    @Test func scriptedLifetimeReturnsReason() async {
        #expect(await MCPStdioLifetime.scripted(.stdinEnded).waitForExit() == .stdinEnded)
    }

    // MARK: - serve (oracle runMcpStdioServer shape)

    @Test func serveClosesProcessOnExit() async throws {
        let process = try await catProcess()
        let reason = await MCPStdioRunner.serve(process: process, lifetime: .scripted(.terminated))
        #expect(reason == .terminated)
        #expect(await process.isRunning == false)
        await expectClosed { try await process.send(Data("x".utf8)) }
    }

    @Test func serveWithoutSpawnStillReturns() async {
        let reason = await MCPStdioRunner.serve(process: MCPStdioProcess(), lifetime: .scripted(.stdinClosed))
        #expect(reason == .stdinClosed)
    }

    // MARK: - Channel wiring (MCPStdioChannel pipe seam)

    @Test func channelExchangesEnvelopesOverCat() async throws {
        let process = try await catProcess()
        let session = try sessionForChannel()
        let channel = MCPStdioChannel(session: session, send: process.exchange)
        try await channel.start()
        let envelope = MCPMessageEnvelope(
            resource: "test-resource", address: "tools.i.o.c.t", arguments: "{}", idempotencyKey: "k"
        )
        let reply = try await channel.exchange(envelope)
        #expect(reply == envelope.encoded())
        await channel.close()
        await process.close()
    }

    @Test func transportRoundtripsOverCat() async throws {
        let process = try await catProcess()
        let session = try sessionForChannel()
        let channel = MCPStdioChannel(session: session, send: process.exchange)
        try await channel.start()
        let request = MCPTransportRequest(
            address: try MCPToolAddress.parse("tools.i.o.c.t"),
            argumentsJSON: "{}",
            idempotencyKey: "k"
        )
        let response = try await MCPStdioTransport(channel: channel).roundtrip(request, session: session)
        let expected = MCPMessageEnvelope(
            resource: "test-resource", address: "tools.i.o.c.t", arguments: "{}", idempotencyKey: "k"
        )
        #expect(response.body == String(data: try #require(expected.encoded()), encoding: .utf8))
        await channel.close()
        await process.close()
    }

    @Test func composedChannelCloseCascadesToProcess() async throws {
        // The composed owner: channel.close() cascades to process.close(),
        // so the child cannot leak when the owner drops the channel.
        let process = MCPStdioProcess()
        try await process.spawn(
            MCPStdioProcessSpawn(executablePath: "/bin/sh", arguments: ["-c", "exec sleep 31337"])
        )
        let channel = MCPStdioChannel(session: try sessionForChannel(), process: process)
        try await channel.start()
        #expect(await process.isRunning == true)
        await channel.close()
        #expect(await channel.lifecycle == .closed)
        #expect(await process.isRunning == false)
        // Process accounting: no child survives the cascade.
        let deadline = Date().addingTimeInterval(10)
        while childCount(matching: "sleep 31337") != 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(childCount(matching: "sleep 31337") == 0)
        await process.close()
    }

    // MARK: - Stress

    @Test func fiftySequentialRoundtrips() async throws {
        let process = try await catProcess()
        for index in 0..<50 {
            let frame = Data("frame-\(index)".utf8)
            #expect(try await process.send(frame) == frame)
        }
        await process.close()
    }

    @Test func fiveSpawnCloseCycles() async throws {
        for _ in 0..<5 {
            let process = try await catProcess()
            #expect(try await process.send(Data("ping".utf8)) == Data("ping".utf8))
            await process.close()
            #expect(await process.isRunning == false)
        }
    }

    @Test func concurrentSendsAllSucceed() async throws {
        let process = try await shellProcess(
            "read first; sleep 1; echo \"got:$first\"; while read line; do echo \"got:$line\"; done"
        )
        let pairs = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for index in 0..<10 {
                group.addTask { (index, try await process.send(Data("job-\(index)".utf8))) }
            }
            var collected: [(Int, Data)] = []
            for try await pair in group { collected.append(pair) }
            return collected
        }
        #expect(pairs.count == 10)
        for (index, reply) in pairs {
            #expect(reply == Data("got:job-\(index)".utf8))
        }
        await process.close()
    }

    @Test func attachStormOfBridges() async throws {
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    let process = MCPStdioProcess()
                    try await process.spawn(MCPStdioProcessSpawn(executablePath: "/bin/cat"))
                    var mismatched = 0
                    for index in 0..<10 {
                        let frame = Data("storm-\(index)".utf8)
                        let reply = try await process.send(frame)
                        if reply != frame { mismatched += 1 }
                    }
                    await process.close()
                    return mismatched
                }
            }
            for try await mismatched in group {
                #expect(mismatched == 0)
            }
        }
    }

    // MARK: - Review hardening (X1-N)

    @Test func waitForExitWaitsForRunningChild() async throws {
        let process = try await shellProcess("sleep 30")
        async let status = process.waitForExit()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await process.isRunning == true)
        await process.close()
        #expect(await status != nil)
        #expect(await process.isRunning == false)
    }

    @Test func frameAtCapRoundtripsAndOneByteOverIsMalformed() async throws {
        let process = try await catProcess()
        let atCap = Data(repeating: 0x41, count: MCPMessageEnvelope.maximumBytes)
        #expect(try await process.send(atCap) == atCap)
        await expectMalformed {
            try await process.send(Data(repeating: 0x41, count: MCPMessageEnvelope.maximumBytes + 1))
        }
        #expect(try await process.send(Data("alive".utf8)) == Data("alive".utf8))
        await process.close()
    }

    @Test func spawnCloseCyclesLeakNoFDs() async throws {
        // Bounded slack plus a quiescence poll: parallel suites hold
        // transient FDs (spawn pipes mid-flight), so the count settles
        // within slack of `before` instead of matching it exactly after a
        // fixed nap. Leak sensitivity holds: a real 4-fd/cycle leak floors
        // at before+20, above the slack at every sample.
        let slack = 4
        let warm = try await catProcess()
        await warm.close()
        let before = openFDCount()
        #expect(before >= 0)
        for _ in 0..<5 {
            let process = try await catProcess()
            #expect(try await process.send(Data("ping".utf8)) == Data("ping".utf8))
            await process.close()
        }
        let deadline = Date().addingTimeInterval(10)
        var settled = openFDCount()
        while settled > before + slack, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            settled = openFDCount()
        }
        #expect(settled <= before + slack)
    }

    @Test func noChildProcessesRemainAfterClose() async throws {
        let process = MCPStdioProcess()
        try await process.spawn(MCPStdioProcessSpawn(executablePath: "/bin/sh", arguments: ["-c", "sleep 31337"]))
        #expect(await process.isRunning == true)
        #expect(childCount(matching: "sleep 31337") >= 1)
        await process.close()
        #expect(await process.isRunning == false)
        #expect(await process.waitForExit() != nil)
        // Poll until reaped: close() guarantees exit, but the transient
        // zombie window needs a deadline, not a fixed nap.
        let deadline = Date().addingTimeInterval(10)
        while childCount(matching: "sleep 31337") != 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(childCount(matching: "sleep 31337") == 0)
    }

    @Test func signalDuringFrameExchangeEndsServeAndCloses() async throws {
        let pipe = Pipe()
        let process = try await catProcess()
        let lifetime = MCPStdioLifetime.live(stdinFD: pipe.fileHandleForReading.fileDescriptor, backoffMs: 10)
        let serveTask = Task { await MCPStdioRunner.serve(process: process, lifetime: lifetime) }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(try await process.send(Data("one".utf8)) == Data("one".utf8))
        kill(getpid(), SIGTERM)
        #expect(await serveTask.value == .terminated)
        #expect(await process.isRunning == false)
        await expectClosed { try await process.send(Data("x".utf8)) }
    }

    @Test func stdinEOFDuringWaitEndsLifetime() async throws {
        let pipe = Pipe()
        let lifetime = MCPStdioLifetime.live(stdinFD: pipe.fileHandleForReading.fileDescriptor, backoffMs: 10)
        let task = Task { await lifetime.waitForExit() }
        try await Task.sleep(nanoseconds: 100_000_000)
        try pipe.fileHandleForWriting.close()
        #expect(await task.value == .stdinEnded)
    }

    @Test func invalidateForReadingRetiresFD() {
        let pipe = Pipe()
        let fd = pipe.fileHandleForReading.fileDescriptor
        pipe.fileHandleForWriting.write(Data([1]))
        MCPStdioProcess.invalidateForReading(pipe.fileHandleForReading)
        #expect(fcntl(fd, F_GETFD) == -1)
        pipe.fileHandleForWriting.closeFile()
    }

    @Test func invalidateForReadingFallsBackToPlainClose() {
        let pipe = Pipe()
        let fd = pipe.fileHandleForReading.fileDescriptor
        MCPStdioProcess.invalidateForReading(pipe.fileHandleForReading, nullPath: "/nonexistent-null-path")
        #expect(fcntl(fd, F_GETFD) == -1)
        pipe.fileHandleForWriting.closeFile()
    }
}
