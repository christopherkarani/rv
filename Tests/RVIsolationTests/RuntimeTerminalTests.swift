import Foundation
import RVDomain
import Synchronization
import Testing
@testable import RVIsolation
#if canImport(Darwin)
import Darwin
#endif

@Test func terminalReplayDropsTheOldestBytes() {
    var buffer = TerminalReplayBuffer()
    var written = Data()
    var next = Int64(1)
    for index in 0..<20 {
        let chunk = Data(repeating: UInt8(index), count: 4_000)
        written.append(chunk)
        let sequence = next
        next += 1
        buffer.append(sequence: sequence, bytes: chunk, limit: 10_000, nextSequence: &next)
    }
    #expect(buffer.byteCount <= 10_000)
    let retained = buffer.chunks.reduce(into: Data()) { $0.append($1.bytes) }
    #expect(written.suffix(retained.count) == retained)
    #expect(buffer.chunks.first?.sequence != 1)
    #expect(Set(buffer.chunks.map(\.sequence)).count == buffer.chunks.count)
}

@Test func terminalBytesRoundTripThroughBase64() {
    let payload = Data([0x00, 0x03, 0x0d, 0x1b, 0x5b, 0xff, 0xfe, 0xc3, 0xa9])
    let encoded = TerminalBytesCodec.encode(payload)
    let decoded = TerminalBytesCodec.decode(encoded, maximum: payload.count)
    #expect(decoded == payload)
    let extra = Data(#"{"v":1,"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","op":"launchRuntime","executable":"/bin/sh","pty":true}"#.utf8)
    #expect(WorkspaceControlCodec.decode(extra) == .invalid)
    let unknown = Data(#"{"v":1,"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","op":"stealTerminal","runtime":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"}"#.utf8)
    guard case .message(let unknownMessage) = WorkspaceControlCodec.decode(unknown) else {
        Issue.record("an unknown operation is a v1 message the host rejects")
        return
    }
    #expect(unknownMessage.op == "stealTerminal")
    #expect(WorkspaceControlOp(rawValue: unknownMessage.op) == nil)
    let rows = Data(#"{"v":1,"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","op":"resizeTerminal","runtime":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","rows":0,"cols":80}"#.utf8)
    #expect(WorkspaceControlCodec.decode(rows) == .invalid)
    let wide = Data(#"{"v":1,"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","op":"resizeTerminal","runtime":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","rows":24,"cols":513}"#.utf8)
    #expect(WorkspaceControlCodec.decode(wide) == .invalid)
    let legacy = Data(#"{"v":1,"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","op":"launchRuntime","executable":"/bin/echo"}"#.utf8)
    guard case .message(let message) = WorkspaceControlCodec.decode(legacy) else {
        Issue.record("a launch without io must remain a v1 message")
        return
    }
    #expect(message.io == nil)
}

#if os(Linux)
@Test func linuxContainedPTYStaysUnsupported() async throws {
    let tree = try ContainmentTree()
    defer { tree.tearDown() }
    let command = try #require(IsolatedCommand(executable: "/bin/true"))
    let result = await IsolationBackends.applyOffPool(
        tree.contained,
        command: command,
        io: .pseudoTerminal(rows: 24, columns: 80)
    )
    guard case .failure(.containedGuaranteesUnsupported) = result else {
        Issue.record("Linux contained PTY launch must stay unsupported, got \(result)")
        return
    }
}
#endif

#if os(macOS)
@Suite("Runtime terminal", .serialized)
struct RuntimeTerminalTests {
    @Test func openRejectsDimensionsAndFaultsDoNotLeakMasters() throws {
        #expect(RuntimeTerminal.open(rows: 0, columns: 80) == nil)
        #expect(RuntimeTerminal.open(rows: 24, columns: 513) == nil)
        let before = ttyPaths()
        for fault in [TerminalOpenFault.master, .grant, .slaveName, .slaveOpen, .configure, .stopPipe] {
            TerminalTestInjection.openFault.withLock { $0 = fault }
            defer { TerminalTestInjection.openFault.withLock { $0 = nil } }
            #expect(RuntimeTerminal.open(rows: 24, columns: 80) == nil)
        }
        TerminalTestInjection.openFault.withLock { $0 = nil }
        #expect(ttyPaths() == before)
    }

    @Test func subscribersShareOneOrderedBinaryStream() throws {
        let terminal = try #require(RuntimeTerminal.open(rows: 24, columns: 80))
        let slave = try openSlave(terminal.slavePath)
        defer {
            close(slave)
            terminal.shutdownMaster()
        }
        terminal.startReader()
        let payload = binaryPayload(count: 20_000)
        let first = NoticeBox()
        let second = NoticeBox()
        let firstID = UUID()
        let secondID = UUID()
        #expect(terminal.subscribe(client: firstID, emit: first.append).isSuccess)
        #expect(terminal.subscribe(client: secondID, emit: second.append).isSuccess)
        terminal.activate(client: firstID)
        terminal.activate(client: secondID)
        #expect(writeAll(fd: slave, bytes: payload))
        #expect(waitUntil(seconds: 5) { first.bytes == payload && second.bytes == payload })
        #expect(first.bytes == second.bytes)
        #expect(first.sequences == second.sequences)
        #expect(first.sequences.count > 1)
        #expect(zip(first.sequences, first.sequences.dropFirst()).allSatisfy { $0 < $1 })
        terminal.finish(status: 0)
        #expect(waitUntil(seconds: 2) { first.exitStatus == 0 && second.exitStatus == 0 })
        #expect(terminal.replayByteCount <= TerminalStreamLimits.replayBytes)
        #expect(terminal.hasInputOwner == false)
    }

    @Test func replayKeepsOnlyTheRecentSuffixAndLiveBytesFollow() throws {
        let terminal = try #require(RuntimeTerminal.open(rows: 24, columns: 80))
        let slave = try openSlave(terminal.slavePath)
        defer {
            close(slave)
            terminal.shutdownMaster()
        }
        terminal.startReader()
        let payload = binaryPayload(count: 90_000)
        #expect(writeAll(fd: slave, bytes: payload))
        #expect(waitUntil(seconds: 5) { terminal.replayByteCount > 0 })
        Thread.sleep(forTimeInterval: 0.2)
        #expect(terminal.replayByteCount <= TerminalStreamLimits.replayBytes)
        let late = NoticeBox()
        let lateID = UUID()
        #expect(terminal.subscribe(client: lateID, emit: late.append).isSuccess)
        terminal.activate(client: lateID)
        let tail = Data("LIVE".utf8)
        #expect(writeAll(fd: slave, bytes: tail))
        #expect(waitUntil(seconds: 3) { late.bytes.suffix(tail.count) == tail })
        let replay = late.replayBytes
        #expect(replay.isEmpty == false)
        #expect(payload.suffix(replay.count) == replay)
        #expect(late.bytes.starts(with: replay))
        #expect(late.sequences == late.sequences.sorted())
        terminal.finish(status: 0)
    }

    @Test func slowSubscriberIsDroppedAndDoesNotStallTheReader() throws {
        let terminal = try #require(RuntimeTerminal.open(rows: 24, columns: 80))
        let slave = try openSlave(terminal.slavePath)
        defer {
            close(slave)
            terminal.shutdownMaster()
        }
        terminal.startReader()
        let slow = BlockingBox()
        let healthy = NoticeBox()
        let slowID = UUID()
        let healthyID = UUID()
        #expect(terminal.subscribe(client: slowID, emit: slow.append).isSuccess)
        #expect(terminal.subscribe(client: healthyID, emit: healthy.append).isSuccess)
        terminal.activate(client: slowID)
        terminal.activate(client: healthyID)
        #expect(writeAll(fd: slave, bytes: Data([0x01])))
        #expect(waitUntil(seconds: 2) { slow.isBlocked })
        let payload = binaryPayload(count: 80_000)
        #expect(writeAll(fd: slave, bytes: payload))
        slow.unblock()
        let expected = Data([0x01]) + payload
        #expect(waitUntil(seconds: 5) { slow.sawOverflow && healthy.bytes == expected })
        #expect(waitUntil(seconds: 2) {
            if case .success = terminal.subscribe(client: slowID, emit: { _ in true }) {
                terminal.detach(client: slowID)
                return true
            }
            return false
        })
        #expect(terminal.hasSubscribers)
        #expect(healthy.bytes == expected)
        #expect(terminal.replayByteCount <= TerminalStreamLimits.replayBytes)
        #expect(healthy.exitStatus == nil)
    }

    @Test func detachWaitsUntilFlushLeavesEmit() throws {
        let terminal = try #require(RuntimeTerminal.open(rows: 24, columns: 80))
        let slave = try openSlave(terminal.slavePath)
        defer {
            close(slave)
            terminal.shutdownMaster()
        }
        terminal.startReader()
        let slow = BlockingBox()
        let id = UUID()
        #expect(terminal.subscribe(client: id, emit: slow.append).isSuccess)
        terminal.activate(client: id)
        #expect(writeAll(fd: slave, bytes: Data([0x01])))
        #expect(waitUntil(seconds: 2) { slow.isBlocked })
        let finished = FinishedFlag()
        let thread = Thread {
            terminal.detach(client: id)
            finished.set()
        }
        thread.name = "rv-detach-wait"
        thread.start()
        Thread.sleep(forTimeInterval: 0.1)
        #expect(finished.isSet == false)
        slow.unblock()
        #expect(waitUntil(seconds: 2) { finished.isSet })
        #expect(terminal.subscribe(client: id, emit: { _ in true }).isSuccess)
        terminal.detach(client: id)
    }

    @Test func failedSendDropsTheSubscriberAfterOneOverflow() throws {
        let terminal = try #require(RuntimeTerminal.open(rows: 24, columns: 80))
        let slave = try openSlave(terminal.slavePath)
        defer {
            close(slave)
            terminal.shutdownMaster()
        }
        terminal.startReader()
        let failed = FailSendBox()
        let id = UUID()
        #expect(terminal.subscribe(client: id, emit: failed.append).isSuccess)
        terminal.activate(client: id)
        #expect(terminal.acquireInput(client: id).isSuccess)
        #expect(writeAll(fd: slave, bytes: Data([0x02])))
        #expect(waitUntil(seconds: 2) { failed.sawOverflow })
        #expect(failed.calls >= 2)
        #expect(terminal.hasInputOwner == false)
        #expect(terminal.subscribe(client: id, emit: { _ in true }).isSuccess)
        terminal.detach(client: id)
    }

    @Test func resizeUpdatesTheSlaveWindowAndRejectsBounds() throws {
        let terminal = try #require(RuntimeTerminal.open(rows: 24, columns: 80))
        defer { terminal.shutdownMaster() }
        let slave = try openSlave(terminal.slavePath)
        defer { close(slave) }
        var size = winsize()
        #expect(ioctl(slave, TIOCGWINSZ, &size) == 0)
        #expect(size.ws_row == 24)
        #expect(size.ws_col == 80)
        #expect(terminal.resize(rows: 0, columns: 80).isFailure)
        #expect(terminal.resize(rows: 24, columns: 513).isFailure)
        #expect(terminal.resize(rows: 40, columns: 120).isSuccess)
        #expect(ioctl(slave, TIOCGWINSZ, &size) == 0)
        #expect(size.ws_row == 40)
        #expect(size.ws_col == 120)
    }

    @Test func localRawModeRestoresTheSavedTermios() throws {
        let terminal = try #require(RuntimeTerminal.open(rows: 24, columns: 80))
        let slave = try openSlave(terminal.slavePath)
        defer {
            close(slave)
            terminal.shutdownMaster()
        }
        let original = try termFlags(slave)
        let restorer = try #require(LocalTerminalRestorer.engage(slave, signals: false))
        let raw = try termFlags(slave)
        #expect((raw.local & tcflag_t(ICANON)) == 0)
        restorer.restore()
        restorer.restore()
        #expect(try termFlags(slave) == original)
    }

    @Test func containedPTYIsAForegroundSessionAndAdmissionStaysOnFourAndFive() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let probe = try compileProbe(in: tree.workspaceURL)
        let report = tree.workspaceURL.appendingPathComponent("topology.txt")
        let deny = tree.siblingURL.appendingPathComponent("deny-marker")
        let outside = tree.siblingURL.appendingPathComponent("must-not-touch")
        var fillers: [Int32] = []
        let nullFD = open("/dev/null", O_RDWR | O_CLOEXEC)
        try #require(nullFD >= 0)
        fillers.append(nullFD)
        for slot in 3..<64 {
            if fcntl(Int32(slot), F_GETFD) >= 0 { continue }
            let copied = fcntl(nullFD, F_DUPFD_CLOEXEC, Int32(slot))
            if copied >= 0 { fillers.append(copied) }
        }
        defer { fillers.forEach { close($0) } }
        let spy = PTYHTTPSpy()
        let configuration = RuntimeAdmissionConfiguration(
            normalize: ptyAdmissionNormalize,
            executor: .containedCommand,
            http: .effect { action, _, _ in spy.run(action) },
            approval: { _ in nil },
            policy: { _ in .empty },
            evidence: RuntimeAdmissionEvidence()
        )
        let command = try #require(IsolatedCommand(
            executable: probe.path,
            arguments: ["admit", report.path, outside.path, deny.path]
        ))
        let result = await IsolationBackends.applyLaunchOffPool(
            tree.contained,
            command: command,
            io: .pseudoTerminal(rows: 24, columns: 80),
            host: .opencode,
            sessionStore: .file(tree.rootURL.appendingPathComponent("pty-admit.jsonl")),
            admission: configuration
        )
        let run = try result.get()
        #expect(run.exitStatus == 0)
        let text = try String(contentsOf: report, encoding: .utf8)
        let fields = dictionary(text)
        let pid = try #require(Int32(fields["pid"] ?? ""))
        let sid = try #require(Int32(fields["sid"] ?? ""))
        let pgid = try #require(Int32(fields["pgid"] ?? ""))
        let tpgid = try #require(Int32(fields["tpgid"] ?? ""))
        #expect(pid > 1)
        #expect(sid == pid)
        #expect(pgid == pid)
        #expect(tpgid == pid)
        #expect(getsid(getpid()) != sid)
        #expect(getpgrp() != pgid)
        #expect(fields["tty"] == "1 1 1")
        #expect(fields["fd3"] == "closed")
        #expect(fields["fd4"] == "fifo")
        #expect(fields["fd5"] == "fifo")
        #expect(fields["open"] == "0 1 2 4 5")
        let replies = try String(contentsOf: tree.workspaceURL.appendingPathComponent("admit-replies"), encoding: .utf8)
        #expect(replies.contains("\"status\":\"executed\""))
        #expect(replies.contains("\"status\":\"denied\""))
        #expect(replies.contains("\"status\":\"pending\""))
        #expect(replies.contains("\"status\":\"replay\"") || replies.contains("replay"))
        #expect(replies.contains("invalidCapability"))
        #expect(replies.contains("\"status\":\"http\""))
        #expect(replies.contains("204"))
        #expect(spy.calls == 1)
        #expect(FileManager.default.fileExists(atPath: tree.workspaceURL.appendingPathComponent("admitted-marker").path))
        #expect(FileManager.default.fileExists(atPath: outside.path) == false)
        #expect(FileManager.default.fileExists(atPath: deny.path) == false)
    }

    @Test func containedSessionSurvivesSetsIDAndDoubleForkUntilCancel() throws {
        let opened = try PTYHost()
        defer { opened.close() }
        let probe = try compileProbe(in: opened.tree.workspaceURL)
        let leader = opened.tree.workspaceURL.appendingPathComponent("leader.txt")
        let grand = opened.tree.workspaceURL.appendingPathComponent("grand.txt")
        let survived = opened.tree.workspaceURL.appendingPathComponent("survived")
        let client = try WorkspaceClient.connect(opened.server.endpoint).get()
        let runtime = try client.launchRuntime(
            executable: probe.path,
            arguments: ["escape", leader.path, grand.path, survived.path],
            terminalRows: 24,
            terminalColumns: 80
        ).get()
        #expect(waitUntil(seconds: 20) { FileManager.default.fileExists(atPath: grand.path) })
        let leaderFields = dictionary(try String(contentsOf: leader, encoding: .utf8))
        let grandFields = dictionary(try String(contentsOf: grand, encoding: .utf8))
        let leaderPID = try #require(Int32(leaderFields["pid"] ?? ""))
        #expect(getsid(leaderPID) == leaderPID)
        #expect(getpgid(leaderPID) == leaderPID)
        var info = proc_bsdinfo()
        let wrote = proc_pidinfo(leaderPID, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.stride))
        #expect(wrote > 0)
        #expect(info.pbi_pgid == UInt32(leaderPID))
        #expect(Int32(grandFields["setsid"] ?? "") == EPERM)
        #expect(Int32(grandFields["setpgid"] ?? "") == EPERM)
        #expect(Int32(grandFields["pgid"] ?? "") == leaderPID)
        let grandPID = try #require(Int32(grandFields["pid"] ?? ""))
        #expect(client.cancelRuntime(runtime.runtime).isSuccess)
        #expect(processIsGone(leaderPID))
        #expect(processIsGone(grandPID))
        #expect(FileManager.default.fileExists(atPath: survived.path) == false)
        #expect(opened.supervisor.snapshot.phase == .active)
        #expect(opened.supervisor.publishCount == 0)
    }

    @Test func controlCInterruptsTheForegroundGroupWithoutKillingTheHost() throws {
        let opened = try PTYHost()
        defer { opened.close() }
        let probe = try compileProbe(in: opened.tree.workspaceURL)
        let ready = opened.tree.workspaceURL.appendingPathComponent("interrupt-ready")
        let client = try WorkspaceClient.connect(opened.server.endpoint).get()
        let runtime = try client.launchRuntime(
            executable: probe.path,
            arguments: ["interrupt", ready.path],
            terminalRows: 24,
            terminalColumns: 80
        ).get()
        #expect(waitUntil(seconds: 20) { FileManager.default.fileExists(atPath: ready.path) })
        let fields = dictionary(try String(contentsOf: ready, encoding: .utf8))
        let pid = try #require(Int32(fields["pid"] ?? ""))
        #expect(Int32(fields["tpgid"] ?? "") == pid)
        #expect(fields["isig"] == "1", "\(fields)")
        #expect(fields["vintr"] == "3", "\(fields)")
        #expect(client.subscribeTerminal(runtime.runtime).isSuccess)
        #expect(client.acquireTerminalInput(runtime.runtime).isSuccess)
        #expect(client.writeTerminal(runtime.runtime, bytes: Data([0x03])).isSuccess)
        let events = readEvents(client, seconds: 10)
        let status = events.compactMap { event -> Int32? in
            if case .exited(let status) = event.body { return status }
            return nil
        }.first
        #expect(status == SIGINT)
        #expect(processIsGone(pid))
        #expect(opened.supervisor.snapshot.phase == .active)
        let again = try client.launchRuntime(
            executable: "/bin/echo",
            arguments: ["still-here"],
            terminalRows: 24,
            terminalColumns: 80
        ).get()
        #expect(again.terminal)
        #expect(again.runtime != runtime.runtime)
    }

    @Test func childObservesResizeAndSignal() throws {
        let opened = try PTYHost()
        defer { opened.close() }
        let probe = try compileProbe(in: opened.tree.workspaceURL)
        let initial = opened.tree.workspaceURL.appendingPathComponent("winsz-initial")
        let resized = opened.tree.workspaceURL.appendingPathComponent("winsz-resized")
        let client = try WorkspaceClient.connect(opened.server.endpoint).get()
        let runtime = try client.launchRuntime(
            executable: probe.path,
            arguments: ["winsz", initial.path, resized.path],
            terminalRows: 24,
            terminalColumns: 80
        ).get()
        #expect(waitUntil(seconds: 20) { FileManager.default.fileExists(atPath: initial.path) })
        #expect(try String(contentsOf: initial, encoding: .utf8).contains("24 80"))
        #expect(client.resizeTerminal(runtime.runtime, rows: 0, columns: 80).isFailure(.invalidRequest))
        #expect(client.resizeTerminal(runtime.runtime, rows: 24, columns: 513).isFailure(.invalidRequest))
        #expect(client.resizeTerminal(runtime.runtime, rows: 40, columns: 100).isSuccess)
        #expect(waitUntil(seconds: 15) {
            guard let text = try? String(contentsOf: resized, encoding: .utf8) else { return false }
            return text.contains("signal")
        })
        let text = (try? String(contentsOf: resized, encoding: .utf8)) ?? ""
        #expect(text.contains("40 100"))
        #expect(text.contains("signal 1"))
    }

    @Test func twoViewersDetachReattachAndKeepInputExclusive() throws {
        let opened = try PTYHost()
        defer { opened.close() }
        let clientA = try WorkspaceClient.connect(opened.server.endpoint).get()
        let clientB = try WorkspaceClient.connect(opened.server.endpoint).get()
        let runtime = try clientA.launchRuntime(
            executable: "/bin/sh",
            arguments: ["-c", reattachScript],
            terminalRows: 24,
            terminalColumns: 80
        ).get()
        #expect(runtime.terminal)
        #expect(clientA.subscribeTerminal(runtime.runtime).isSuccess)
        #expect(clientB.subscribeTerminal(runtime.runtime).isSuccess)
        let beforeA = readUntil(clientA, contains: Data("before".utf8), seconds: 10)
        let beforeB = readUntil(clientB, contains: Data("before".utf8), seconds: 10)
        #expect(beforeA.contains(Data("before".utf8)))
        #expect(beforeB.contains(Data("before".utf8)))
        #expect(clientA.acquireTerminalInput(runtime.runtime).isSuccess)
        #expect(clientB.acquireTerminalInput(runtime.runtime).isFailure(.terminalBusy))
        #expect(clientB.writeTerminal(runtime.runtime, bytes: Data("nope\n".utf8)).isFailure(.terminalBusy))
        #expect(clientA.unsubscribeTerminal(runtime.runtime).isSuccess)
        let stillRunning = try clientB.listRuntimes().get()
        #expect(stillRunning.contains { $0.runtime == runtime.runtime && $0.running })
        FileManager.default.createFile(
            atPath: opened.tree.workspaceURL.appendingPathComponent("stage-during").path,
            contents: Data()
        )
        #expect(clientB.detach().isSuccess)
        let clientC = try WorkspaceClient.connect(opened.server.endpoint).get()
        #expect(clientC.subscribeTerminal(runtime.runtime).isSuccess)
        let replay = readUntil(clientC, contains: Data("during".utf8), seconds: 10)
        #expect(replay.contains(Data("during".utf8)))
        #expect(clientC.acquireTerminalInput(runtime.runtime).isSuccess)
        FileManager.default.createFile(
            atPath: opened.tree.workspaceURL.appendingPathComponent("stage-after").path,
            contents: Data()
        )
        let after = readUntil(clientC, contains: Data("after".utf8), seconds: 10)
        let combined = replay + after
        #expect(combined.contains(Data("during".utf8)))
        #expect(combined.contains(Data("after".utf8)))
        let during = combined.range(of: Data("during".utf8))
        let later = combined.range(of: Data("after".utf8))
        if let during, let later {
            #expect(during.lowerBound < later.lowerBound)
        } else {
            Issue.record("reattach stream missing during or after")
        }
        #expect(opened.supervisor.publishCount == 0)
        #expect(opened.supervisor.snapshot.phase == .active)
    }

    @Test func inputReachesOnlyTheAddressedRuntime() throws {
        let opened = try PTYHost()
        defer { opened.close() }
        let client = try WorkspaceClient.connect(opened.server.endpoint).get()
        let other = try WorkspaceClient.connect(opened.server.endpoint).get()
        let scriptA = "IFS= read -r line; printf '%s' \"$line\" > out-a; /bin/sleep 30"
        let scriptB = "IFS= read -r line; printf '%s' \"$line\" > out-b; /bin/sleep 30"
        let runtimeA = try client.launchRuntime(
            executable: "/bin/sh",
            arguments: ["-c", scriptA],
            terminalRows: 24,
            terminalColumns: 80
        ).get()
        let runtimeB = try client.launchRuntime(
            executable: "/bin/sh",
            arguments: ["-c", scriptB],
            terminalRows: 24,
            terminalColumns: 80
        ).get()
        #expect(client.subscribeTerminal(runtimeA.runtime).isSuccess)
        #expect(other.subscribeTerminal(runtimeB.runtime).isSuccess)
        #expect(client.acquireTerminalInput(runtimeA.runtime).isSuccess)
        #expect(client.writeTerminal(runtimeB.runtime, bytes: Data("only-a\n".utf8)).isFailure(.terminalBusy))
        #expect(client.writeTerminal(runtimeA.runtime, bytes: Data("only-a\n".utf8)).isSuccess)
        let outA = opened.tree.workspaceURL.appendingPathComponent("out-a")
        let outB = opened.tree.workspaceURL.appendingPathComponent("out-b")
        #expect(waitUntil(seconds: 10) {
            (try? String(contentsOf: outA, encoding: .utf8)) == "only-a"
        })
        #expect(FileManager.default.fileExists(atPath: outB.path) == false)
        #expect(client.detach().isSuccess)
        let watcher = try WorkspaceClient.connect(opened.server.endpoint).get()
        let afterDetach = try watcher.listRuntimes().get()
        #expect(afterDetach.contains { $0.runtime == runtimeA.runtime && $0.running })
        #expect(other.acquireTerminalInput(runtimeB.runtime).isSuccess)
        #expect(other.writeTerminal(runtimeB.runtime, bytes: Data("only-b\n".utf8)).isSuccess)
        #expect(waitUntil(seconds: 10) {
            (try? String(contentsOf: outB, encoding: .utf8)) == "only-b"
        })
        #expect(try String(contentsOf: outA, encoding: .utf8) == "only-a")
    }

    @Test func runtimeExitClosesTheTerminalAndLeavesTheWorkspace() throws {
        let opened = try PTYHost()
        defer { opened.close() }
        let payload = opened.tree.workspaceURL.appendingPathComponent("payload.bin")
        let bytes = binaryPayload(count: 12_000)
        try bytes.write(to: payload)
        let probe = try compileProbe(in: opened.tree.workspaceURL)
        let client = try WorkspaceClient.connect(opened.server.endpoint).get()
        let runtime = try client.launchRuntime(
            executable: probe.path,
            arguments: ["cat", payload.path],
            terminalRows: 24,
            terminalColumns: 80
        ).get()
        #expect(client.subscribeTerminal(runtime.runtime).isSuccess)
        let events = readEvents(client, seconds: 15)
        let body = terminalBytes(events)
        #expect(body == bytes)
        let sequences = terminalSequences(events)
        #expect(sequences.count > 1)
        #expect(zip(sequences, sequences.dropFirst()).allSatisfy { $0 < $1 })
        #expect(events.contains { if case .exited(0) = $0.body { true } else { false } })
        let watcher = try WorkspaceClient.connect(opened.server.endpoint).get()
        let facts = try watcher.listRuntimes().get()
        #expect(facts.contains { $0.runtime == runtime.runtime && $0.running == false })
        #expect(client.acquireTerminalInput(runtime.runtime).isFailure(.terminalUnavailable))
        #expect(opened.supervisor.snapshot.phase == .active)
        #expect(opened.supervisor.publishCount == 0)
        let next = try client.launchRuntime(
            executable: "/bin/echo",
            arguments: ["next"],
            terminalRows: 24,
            terminalColumns: 80
        ).get()
        #expect(next.runtime != runtime.runtime)
        #expect(next.terminal)
    }

    @Test func launchFaultsDoNotReportARunningRuntime() throws {
        let opened = try PTYHost()
        defer { opened.close() }
        let raw = try WorkspaceControlSocket.connect(path: opened.server.endpoint.socketPath, timeout: 2).get()
        defer { close(raw) }
        let hello = WorkspaceControlMessage(
            version: 1,
            id: UUID(),
            op: WorkspaceControlOp.hello.rawValue,
            token: opened.server.endpoint.ownerToken
        )
        #expect(writeFrame(raw, hello))
        _ = try WorkspaceControlSocket.readFrame(fd: raw, timeout: 2).get()
        let stolen = WorkspaceControlMessage(
            version: 1,
            id: UUID(),
            op: "stealTerminal",
            runtime: UUID()
        )
        #expect(writeFrame(raw, stolen))
        let body = try WorkspaceControlSocket.readFrame(fd: raw, timeout: 2).get()
        guard case .message(let reply) = WorkspaceControlCodec.decode(body) else {
            Issue.record("unknown terminal operation must get a reply")
            return
        }
        #expect(reply.ok == false)
        #expect(reply.error == WorkspaceControlCode.invalidRequest.rawValue)
        let marker = opened.tree.workspaceURL.appendingPathComponent("must-not-run")
        let command = try #require(IsolatedCommand(
            executable: "/bin/sh",
            arguments: ["-c", "printf ran > must-not-run"]
        ))
        let plan = compileContainedPlan(workspace: opened.supervisor.snapshot.policyWorkspace)
        let log = opened.tree.rootURL.appendingPathComponent("fault.jsonl")
        let before = ttyPaths()
        TerminalTestInjection.failSpawn.withLock { $0 = true }
        let spawned = opened.supervisor.launch(
            host: nil,
            command: command,
            plan: plan,
            io: .pseudoTerminal(rows: 24, columns: 80),
            admission: .failClosed,
            sessionStore: .file(log)
        )
        TerminalTestInjection.failSpawn.withLock { $0 = false }
        guard case .failure(.apply(.processSpawnFailed)) = spawned else {
            Issue.record("spawn fault must fail before the agent, got \(spawned)")
            return
        }
        TerminalTestInjection.failRegistration.withLock { $0 = true }
        let registered = opened.supervisor.launch(
            host: nil,
            command: command,
            plan: plan,
            io: .pseudoTerminal(rows: 24, columns: 80),
            admission: .failClosed,
            sessionStore: .file(log)
        )
        TerminalTestInjection.failRegistration.withLock { $0 = false }
        guard case .failure(.apply(.lifetimeBoundaryFailed)) = registered else {
            Issue.record("registration fault must not report a running runtime, got \(registered)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
        #expect(opened.supervisor.runtimeFacts().contains { $0.running } == false)
        #expect(opened.supervisor.snapshot.phase == .active)
        #expect(ttyPaths().subtracting(before).isEmpty)
    }

    @Test func closingTheWorkspaceKillsEveryPTYRuntime() throws {
        let opened = try PTYHost()
        defer { opened.close() }
        let client = try WorkspaceClient.connect(opened.server.endpoint).get()
        let watcher = try WorkspaceClient.connect(opened.server.endpoint).get()
        let firstPID = opened.tree.workspaceURL.appendingPathComponent("pid-a")
        let secondPID = opened.tree.workspaceURL.appendingPathComponent("pid-b")
        let first = try client.launchRuntime(
            executable: "/bin/sh",
            arguments: ["-c", "printf '%s\\n' $$ > pid-a; /bin/sleep 60"],
            terminalRows: 24,
            terminalColumns: 80
        ).get()
        let second = try client.launchRuntime(
            executable: "/bin/sh",
            arguments: ["-c", "printf '%s\\n' $$ > pid-b; /bin/sleep 60"],
            terminalRows: 24,
            terminalColumns: 80
        ).get()
        #expect(waitUntil(seconds: 20) {
            FileManager.default.fileExists(atPath: firstPID.path)
                && FileManager.default.fileExists(atPath: secondPID.path)
        })
        let pidA = try #require(Int32(try String(contentsOf: firstPID, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let pidB = try #require(Int32(try String(contentsOf: secondPID, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(client.subscribeTerminal(first.runtime).isSuccess)
        let watched = WatchBox()
        let thread = Thread { watched.result = watcher.watchClose(timeout: 30) }
        thread.start()
        Thread.sleep(forTimeInterval: 0.2)
        let closed = try client.closeWorkspace().get()
        #expect(closed.phase == .closed)
        #expect(processIsGone(pidA))
        #expect(processIsGone(pidB))
        #expect(waitUntil(seconds: 10) { watched.result != nil })
        #expect(watched.result?.isSuccess == true)
        #expect(opened.supervisor.publishCount == 1)
        let refused = client.launchRuntime(
            executable: "/bin/echo",
            arguments: ["late"],
            terminalRows: 24,
            terminalColumns: 80
        )
        #expect(refused.isFailure)
        #expect(first.runtime != second.runtime)
    }

    @Test func aSlowSocketDoesNotStopTheOtherSubscriberOrClose() throws {
        let opened = try PTYHost()
        defer { opened.close() }
        let healthy = try WorkspaceClient.connect(opened.server.endpoint).get()
        let runtime = try healthy.launchRuntime(
            executable: "/bin/sh",
            arguments: ["-c", "i=0; while [ \"$i\" -lt 400 ]; do printf 'xxxxxxxx'; i=$((i+1)); done; printf END; /bin/sleep 30"],
            terminalRows: 24,
            terminalColumns: 80
        ).get()
        let raw = try WorkspaceControlSocket.connect(path: opened.server.endpoint.socketPath, timeout: 2).get()
        defer { close(raw) }
        var receive = 2048
        _ = setsockopt(raw, SOL_SOCKET, SO_RCVBUF, &receive, socklen_t(MemoryLayout<Int32>.size))
        let hello = WorkspaceControlMessage(
            version: 1,
            id: UUID(),
            op: WorkspaceControlOp.hello.rawValue,
            token: opened.server.endpoint.ownerToken
        )
        #expect(writeFrame(raw, hello))
        _ = try WorkspaceControlSocket.readFrame(fd: raw, timeout: 2).get()
        let subscribe = WorkspaceControlMessage(
            version: 1,
            id: UUID(),
            op: WorkspaceControlOp.subscribeTerminal.rawValue,
            runtime: runtime.runtime
        )
        #expect(writeFrame(raw, subscribe))
        _ = try WorkspaceControlSocket.readFrame(fd: raw, timeout: 2).get()
        #expect(healthy.subscribeTerminal(runtime.runtime).isSuccess)
        let seen = readUntil(healthy, contains: Data("END".utf8), seconds: 15)
        #expect(seen.contains(Data("END".utf8)))
        let closed = try healthy.closeWorkspace().get()
        #expect(closed.phase == .closed)
        #expect(opened.supervisor.publishCount == 1)
    }

    @Test func repeatedAttachCyclesDoNotLeakPTYs() throws {
        let opened = try PTYHost()
        defer { opened.close() }
        let client = try WorkspaceClient.connect(opened.server.endpoint).get()
        let before = ttyPaths()
        for index in 0..<8 {
            let name = opened.tree.workspaceURL.appendingPathComponent("cycle-\(index)")
            let runtime = try client.launchRuntime(
                executable: "/bin/sh",
                arguments: ["-c", "printf '%s' $$ > 'cycle-\(index)'; /bin/sleep 30"],
                terminalRows: 24,
                terminalColumns: 80
            ).get()
            #expect(client.subscribeTerminal(runtime.runtime).isSuccess)
            #expect(client.acquireTerminalInput(runtime.runtime).isSuccess)
            #expect(client.writeTerminal(runtime.runtime, bytes: Data("\n".utf8)).isSuccess)
            #expect(waitUntil(seconds: 15) { FileManager.default.fileExists(atPath: name.path) })
            #expect(client.unsubscribeTerminal(runtime.runtime).isSuccess)
            let again = try WorkspaceClient.connect(opened.server.endpoint).get()
            #expect(again.subscribeTerminal(runtime.runtime).isSuccess)
            #expect(again.detach().isSuccess)
            #expect(client.cancelRuntime(runtime.runtime).isSuccess)
            let pid = try #require(Int32(
                try String(contentsOf: name, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            #expect(processIsGone(pid))
        }
        #expect(ttyPaths().subtracting(before).isEmpty)
        #expect(opened.supervisor.snapshot.phase == .active)
    }

    @Test func provingClientRestoresTheLocalTerminal() throws {
        let home = try shortDirectory(prefix: "/tmp/rvt")
        defer { try? FileManager.default.removeItem(at: home) }
        let workspace = home.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let rv = try builtProduct("rv")
        let pty = try TestPTY()
        defer {
            pty.close()
        }
        var cooked = termios()
        #expect(tcgetattr(pty.slave, &cooked) == 0)
        cooked.c_lflag |= tcflag_t(ICANON | ECHO)
        #expect(tcsetattr(pty.slave, TCSANOW, &cooked) == 0)
        let original = try termFlags(pty.slave)
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        defer { closeWorkspaceTool(rv, workspace: workspace, environment: environment) }
        let sleepRun = try spawn(
            rv.path,
            ["workspace", "run", "--workspace", workspace.path, "--rows", "24", "--columns", "80", "--", "/bin/sh", "-c", "printf '%s\\n' $$ > client-sleep.pid; printf ready > ready; /bin/sleep 30"],
            environment: environment,
            slave: pty.slave
        )
        defer { if processIsGone(sleepRun) == false { kill(sleepRun, SIGKILL) } }
        let ready = workspace.appendingPathComponent("ready")
        #expect(waitUntil(seconds: 40) { FileManager.default.fileExists(atPath: ready.path) })
        #expect(waitUntilRaw(pty.slave))
        let runtimePID = try #require(Int32(
            try String(contentsOf: workspace.appendingPathComponent("client-sleep.pid"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        kill(sleepRun, SIGINT)
        #expect(waitStatus(sleepRun, seconds: 5) == 1)
        #expect(reopenFlags(pty) == normalized(original))
        #expect(processIsGone(runtimePID) == false)
        let echo = try spawn(
            rv.path,
            ["workspace", "run", "--workspace", workspace.path, "--rows", "24", "--columns", "80", "--", "/bin/echo", "done"],
            environment: environment,
            slave: pty.slave
        )
        #expect(waitUntil(seconds: 30) { reaped(echo) })
        #expect(reopenFlags(pty) == normalized(original))
        let failed = try spawn(
            rv.path,
            ["workspace", "run", "--workspace", workspace.path, "--rows", "24", "--columns", "80", "--", "/bin/sh", "-c", "exit 7"],
            environment: environment,
            slave: pty.slave
        )
        #expect(waitStatus(failed, seconds: 30) == 7)
        #expect(reopenFlags(pty) == normalized(original))
        let closing = try spawn(
            rv.path,
            ["workspace", "run", "--workspace", workspace.path, "--rows", "24", "--columns", "80", "--", "/bin/sleep", "30"],
            environment: environment,
            slave: pty.slave
        )
        #expect(waitUntilRaw(pty.slave))
        let closer = Process()
        closer.executableURL = rv
        closer.arguments = ["workspace", "close", "--workspace", workspace.path]
        closer.environment = environment
        try closer.run()
        closer.waitUntilExit()
        #expect(closer.terminationStatus == 0)
        #expect(waitUntil(seconds: 15) { reaped(closing) })
        #expect(reopenFlags(pty) == normalized(original))
        #expect(processIsGone(runtimePID))
        let held = try spawn(
            rv.path,
            ["workspace", "run", "--workspace", workspace.path, "--rows", "24", "--columns", "80", "--", "/bin/sleep", "30"],
            environment: environment,
            slave: pty.slave
        )
        #expect(waitUntilRaw(pty.slave))
        close(pty.master)
        pty.master = -1
        #expect(waitUntil(seconds: 10) { reaped(held) })
        let final = try? termFlags(pty.slave)
        #expect(final.map(normalized) == normalized(original))
    }

    @Test func hostDeathDropsTheTerminalAndRecoveryKillsTheGroup() throws {
        let home = try shortDirectory(prefix: "/tmp/rvh")
        defer { try? FileManager.default.removeItem(at: home) }
        let workspace = home.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let rv = try builtProduct("rv")
        let hostBinary = try builtProduct("rv-workspace-host")
        let pty = try TestPTY()
        defer { pty.close() }
        var cooked = termios()
        #expect(tcgetattr(pty.slave, &cooked) == 0)
        cooked.c_lflag |= tcflag_t(ICANON | ECHO)
        #expect(tcsetattr(pty.slave, TCSANOW, &cooked) == 0)
        let original = try termFlags(pty.slave)
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        let script = "printf '%s\\n' $$ > leader.pid; /bin/sleep 60 & printf '%s\\n' $! > child.pid; wait"
        let clientPID = try spawn(
            rv.path,
            ["workspace", "run", "--workspace", workspace.path, "--rows", "24", "--columns", "80", "--", "/bin/sh", "-c", script],
            environment: environment,
            slave: pty.slave
        )
        defer { if processIsGone(clientPID) == false { kill(clientPID, SIGKILL) } }
        let leaderURL = workspace.appendingPathComponent("leader.pid")
        let childURL = workspace.appendingPathComponent("child.pid")
        #expect(waitUntil(seconds: 40) {
            FileManager.default.fileExists(atPath: leaderURL.path)
                && FileManager.default.fileExists(atPath: childURL.path)
        })
        #expect(waitUntilRaw(pty.slave))
        let leader = try #require(pidFile(leaderURL))
        let child = try #require(pidFile(childURL))
        let host = try #require(workspaceHostPID(parent: clientPID))
        kill(host, SIGKILL)
        #expect(waitUntil(seconds: 10) { reaped(clientPID) })
        #expect(reopenFlags(pty) == normalized(original))
        let config = home.appendingPathComponent(".config/rv", isDirectory: true)
        if case .live = WorkspaceDiscovery.inspect(project: workspace.path, configurationDirectory: config) {
            Issue.record("a dead host must not stay discoverable as live")
        }
        let restarted = Process()
        restarted.executableURL = hostBinary
        restarted.arguments = ["--workspace", workspace.path]
        restarted.environment = environment
        try restarted.run()
        defer {
            if restarted.isRunning { restarted.terminate() }
            restarted.waitUntilExit()
        }
        let endpoint = try #require(waitLive(project: workspace.path, configuration: config, seconds: 60))
        #expect(processIsGone(leader))
        #expect(processIsGone(child))
        let recovered = try WorkspaceClient.connect(endpoint).get()
        let facts = try recovered.listRuntimes().get()
        #expect(facts.contains { $0.running } == false)
        #expect(recovered.subscribeTerminal(UUID()).isFailure)
        #expect(try recovered.closeWorkspace().get().phase == .closed)
        restarted.waitUntilExit()
    }
}

private let reattachScript = """
printf 'before'
while [ ! -f stage-during ]; do /bin/sleep 0.05; done
printf 'during'
while [ ! -f stage-after ]; do /bin/sleep 0.05; done
printf 'after'
/bin/sleep 30
"""

private func binaryPayload(count: Int) -> Data {
    var data = Data([0x1b, 0x5b, 0x33, 0x31, 0x6d, 0xc3, 0xa9, 0xff, 0xfe, 0x00, 0x0d, 0x0a, 0x03])
    if count > data.count {
        for index in 0..<(count - data.count) {
            data.append(UInt8(index % 251))
        }
    }
    return data
}

private func dictionary(_ text: String) -> [String: String] {
    var fields: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2 { fields[parts[0]] = parts[1] }
    }
    return fields
}

private func waitUntil(seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
}

private func ttyPaths() -> Set<String> {
    var paths: Set<String> = []
    for fd in 0..<256 {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(Int32(fd), F_GETPATH, &buffer) == 0 else { continue }
        let path = utf8Path(buffer)
        if path.contains("/dev/ttys") || path.contains("/dev/pty") {
            paths.insert(path)
        }
    }
    return paths
}

private func openSlave(_ path: String) throws -> Int32 {
    // Without a master, a blocking open of the slave waits forever.
    let fd = path.withCString { Darwin.open($0, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC) }
    try #require(fd >= 0)
    let flags = fcntl(fd, F_GETFL)
    if flags >= 0 {
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
    }
    return fd
}

private func writeAll(fd: Int32, bytes: Data) -> Bool {
    let raw = [UInt8](bytes)
    var offset = 0
    while offset < raw.count {
        let count = raw.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
        }
        if count > 0 {
            offset += count
            continue
        }
        if count < 0, errno == EINTR || errno == EAGAIN { continue }
        return false
    }
    return true
}

private func writeFrame(_ fd: Int32, _ message: WorkspaceControlMessage) -> Bool {
    guard let body = WorkspaceControlCodec.encode(message) else { return false }
    return WorkspaceControlSocket.writeFrame(fd: fd, body: body)
}

private func reopenFlags(_ pty: TestPTY) -> TermFlags? {
    let flags = (try? termFlags(pty.slave)) ?? {
        guard let fd = try? openSlave(pty.path) else { return nil }
        defer { close(fd) }
        return try? termFlags(fd)
    }()
    return flags.map(normalized)
}

/// `PENDIN` (0x20000000) is a kernel input-queue bit. Restoring the
/// caller's cooked mode does not round-trip that bit.
private func normalized(_ flags: TermFlags) -> TermFlags {
    var copy = flags
    copy.local &= ~tcflag_t(0x20000000)
    return copy
}

private func reaped(_ pid: pid_t) -> Bool {
    var status: Int32 = 0
    if waitpid(pid, &status, WNOHANG) == pid { return true }
    return processIsGone(pid)
}

private func processIsGone(_ pid: pid_t) -> Bool {
    guard pid > 1 else { return true }
    return kill(pid, 0) == -1 && errno == ESRCH
}

private func waitUntilRaw(_ fd: Int32) -> Bool {
    waitUntil(seconds: 10) {
        ((try? termFlags(fd))?.local ?? tcflag_t(ICANON)) & tcflag_t(ICANON) == 0
    }
}

private func waitStatus(_ pid: pid_t, seconds: TimeInterval) -> Int32? {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid {
            guard status & 0x7f == 0 else { return nil }
            return (status >> 8) & 0xff
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return nil
}

private func pidFile(_ url: URL) -> pid_t? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

private func workspaceHostPID(parent: pid_t) -> pid_t? {
    let capacity = 4096
    var buffer = [pid_t](repeating: 0, count: capacity)
    let bytes = buffer.withUnsafeMutableBytes { raw -> Int32 in
        guard let base = raw.baseAddress else { return -1 }
        return proc_listpids(UInt32(PROC_ALL_PIDS), 0, base, Int32(raw.count))
    }
    guard bytes > 0 else { return nil }
    let count = min(Int(bytes) / MemoryLayout<pid_t>.size, capacity)
    var fallback: pid_t?
    for pid in buffer.prefix(count) where pid > 1 {
        guard processPath(pid)?.contains("rv-workspace-host") == true else { continue }
        var info = proc_bsdinfo()
        let wrote = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.stride))
        if wrote > 0, info.pbi_ppid == UInt32(parent) { return pid }
        fallback = pid
    }
    return fallback
}

private func processPath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return utf8Path(buffer, length: Int(length))
}

private func utf8Path(_ buffer: [CChar], length: Int? = nil) -> String {
    let limit = min(length ?? buffer.count, buffer.count)
    let bytes = buffer.prefix(limit).prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

private func waitLive(project: String, configuration: URL, seconds: TimeInterval) -> WorkspaceEndpoint? {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if case .live(let endpoint) = WorkspaceDiscovery.inspect(
            project: project,
            configurationDirectory: configuration
        ) {
            return endpoint
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return nil
}

private func closeWorkspaceTool(_ rv: URL, workspace: URL, environment: [String: String]) {
    let closer = Process()
    closer.executableURL = rv
    closer.arguments = ["workspace", "close", "--workspace", workspace.path]
    closer.environment = environment
    try? closer.run()
    closer.waitUntilExit()
}

private struct TermFlags: Equatable {
    var input: tcflag_t
    var output: tcflag_t
    var local: tcflag_t
    var control: tcflag_t
}

private func termFlags(_ fd: Int32) throws -> TermFlags {
    var term = termios()
    try #require(tcgetattr(fd, &term) == 0)
    return TermFlags(input: term.c_iflag, output: term.c_oflag, local: term.c_lflag, control: term.c_cflag)
}

private final class NoticeBox: Sendable {
    private let box = Mutex<[TerminalNotice]>([])

    func append(_ notice: TerminalNotice) -> Bool {
        box.withLock { $0.append(notice) }
        return true
    }

    var bytes: Data {
        let copy = box.withLock { $0 }
        return copy.reduce(into: Data()) { partial, notice in
            switch notice {
            case .output(_, let bytes), .replay(_, let bytes):
                partial.append(bytes)
            default:
                break
            }
        }
    }

    var replayBytes: Data {
        let copy = box.withLock { $0 }
        return copy.reduce(into: Data()) { partial, notice in
            if case .replay(_, let bytes) = notice { partial.append(bytes) }
        }
    }

    var sequences: [Int64] {
        let copy = box.withLock { $0 }
        return copy.compactMap { notice in
            switch notice {
            case .output(let sequence, _), .replay(let sequence, _):
                return sequence
            default:
                return nil
            }
        }
    }

    var exitStatus: Int32? {
        let copy = box.withLock { $0 }
        for notice in copy {
            if case .exited(let status) = notice { return status }
        }
        return nil
    }
}

private final class FinishedFlag: Sendable {
    private let box = Mutex(false)

    func set() {
        box.withLock { $0 = true }
    }

    var isSet: Bool {
        box.withLock { $0 }
    }
}

private final class FailSendBox: Sendable {
    private let box = Mutex<State>(State())

    private struct State {
        var overflow = false
        var count = 0
    }

    func append(_ notice: TerminalNotice) -> Bool {
        box.withLock {
            $0.count += 1
            if case .overflow = notice { $0.overflow = true }
        }
        return false
    }

    var sawOverflow: Bool {
        box.withLock { $0.overflow }
    }

    var calls: Int {
        box.withLock { $0.count }
    }
}

private final class BlockingBox: Sendable {
    private let box = Mutex<State>(State())
    private let release = DispatchSemaphore(value: 0)

    private struct State {
        var blocked = false
        var overflow = false
    }

    func append(_ notice: TerminalNotice) -> Bool {
        let wait = box.withLock { state -> Bool in
            if case .overflow = notice { state.overflow = true }
            if case .output = notice, state.blocked == false {
                state.blocked = true
                return true
            }
            return false
        }
        if wait { release.wait() }
        return true
    }

    var isBlocked: Bool {
        box.withLock { $0.blocked }
    }

    func unblock() {
        release.signal()
    }

    var sawOverflow: Bool {
        box.withLock { $0.overflow }
    }
}

private final class PTYHTTPSpy: Sendable {
    private let box = Mutex(0)

    var calls: Int {
        box.withLock { $0 }
    }

    func run(_ action: HTTPAction) -> Result<HTTPExecutionReceipt, HTTPEgressFailure> {
        box.withLock { $0 += 1 }
        return .success(
            HTTPExecutionReceipt(
                status: 204,
                destination: action.destination.auditedResource,
                headers: [],
                body: Data()
            )
        )
    }
}

private func ptyAdmissionNormalize(
    subject: RuntimeAdmissionSubject,
    action: RuntimeRequestedAction
) -> Result<ProposedAction, RuntimeAdmissionEvaluationError> {
    switch action {
    case .http(let method, let url):
        return normalizeRuntimeHTTP(
            subject: subject,
            method: method,
            url: url,
            resolve: { _ in
            guard let address = HTTPIPAddress(ipv4: [1, 1, 1, 1]) else {
                return .failure(.failed)
            }
            return .success([address])
        }
        )
    case .shell(let command):
        let raw = command.rawValue
        let fingerprint = ActionFingerprint(rawValue: "pty:\(raw)")
        let tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.count == 2, tokens[0] == "touch" {
            let inside = tokens[1].hasPrefix("/") == false
            return .success(
                .shell(
                    ShellAction(
                        fingerprint: fingerprint,
                        effects: ActionEffects(kinds: inside ? [.filesystemCreate] : [.outsideRepositoryMutation]),
                        resources: ActionResources(
                            path: tokens[1],
                            filesystemScope: inside ? .insideRepository : .outsideRepository,
                            resourceKind: .unknown
                        ),
                        scope: ActionScope(workingDirectory: subject.policyWorkspace),
                        supportingCommand: command
                    )
                )
            )
        }
        return .success(
            .shell(
                ShellAction(
                    fingerprint: fingerprint,
                    effects: ActionEffects(),
                    resources: ActionResources(),
                    scope: ActionScope(workingDirectory: subject.policyWorkspace),
                    supportingCommand: command
                )
            )
        )
    }
}

private func readEvents(_ client: WorkspaceClient, seconds: TimeInterval) -> [WorkspaceTerminalEvent] {
    var events: [WorkspaceTerminalEvent] = []
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        switch client.nextTerminalEvent(timeout: 0.2) {
        case .failure:
            return events
        case .success(.waiting):
            continue
        case .success(.event(let event)):
            events.append(event)
            if case .exited = event.body { return events }
        }
    }
    return events
}

private func readUntil(_ client: WorkspaceClient, contains needle: Data, seconds: TimeInterval) -> Data {
    var data = Data()
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        switch client.nextTerminalEvent(timeout: 0.2) {
        case .failure:
            return data
        case .success(.waiting):
            if data.contains(needle) { return data }
        case .success(.event(let event)):
            switch event.body {
            case .output(_, let bytes), .replay(_, let bytes):
                data.append(bytes)
                if data.contains(needle) { return data }
            case .exited:
                return data
            case .overflow, .inputOwner:
                break
            }
        }
    }
    return data
}

private func terminalBytes(_ events: [WorkspaceTerminalEvent]) -> Data {
    events.reduce(into: Data()) { partial, event in
        switch event.body {
        case .output(_, let bytes), .replay(_, let bytes):
            partial.append(bytes)
        default:
            break
        }
    }
}

private func terminalSequences(_ events: [WorkspaceTerminalEvent]) -> [Int64] {
    events.compactMap { event in
        switch event.body {
        case .output(let sequence, _), .replay(let sequence, _):
            return sequence
        default:
            return nil
        }
    }
}

private struct PTYHost {
    var tree: ContainmentTree
    var supervisor: WorkspaceSessionSupervisor
    var server: WorkspaceHostServer

    init() throws {
        tree = try ContainmentTree()
        let config = tree.rootURL.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let life = config.appendingPathComponent("workspace-sessions.jsonl")
        let runtime = config.appendingPathComponent("runtime-sessions.jsonl")
        let directory = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
        supervisor = try WorkspaceSessionSupervisor.open(directory, lifecycleLog: .file(life)).get()
        server = try WorkspaceHostServer.start(
            supervisor: supervisor,
            configurationDirectory: config,
            sessionStore: .file(runtime)
        ).get()
    }

    func close() {
        server.stop()
        _ = supervisor.close()
        tree.tearDown()
    }
}

private final class WatchBox: Sendable {
    private let box = Mutex<Result<WorkspaceDescription, WorkspaceClientFailure>?>(nil)

    var result: Result<WorkspaceDescription, WorkspaceClientFailure>? {
        get { box.withLock { $0 } }
        set { box.withLock { $0 = newValue } }
    }
}

private final class TestPTY {
    var master: Int32
    var slave: Int32
    var path: String

    init() throws {
        let terminal = try #require(RuntimeTerminal.open(rows: 24, columns: 80))
        master = terminal.masterFD
        path = terminal.slavePath
        slave = try openSlave(path)
        // The terminal object closes the master when released. Duplicate it.
        let kept = Darwin.dup(master)
        try #require(kept >= 0)
        terminal.shutdownMaster()
        master = kept
    }

    func close() {
        if master >= 0 { Darwin.close(master) }
        if slave >= 0 { Darwin.close(slave) }
    }
}

private func spawn(
    _ executable: String,
    _ arguments: [String],
    environment: [String: String],
    slave: Int32
) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { throw PTYTestError.spawn }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawn_file_actions_adddup2(&actions, slave, STDIN_FILENO) == 0,
        posix_spawn_file_actions_adddup2(&actions, slave, STDOUT_FILENO) == 0,
        posix_spawn_file_actions_adddup2(&actions, slave, STDERR_FILENO) == 0
    else { throw PTYTestError.spawn }
    var attr: posix_spawnattr_t?
    guard posix_spawnattr_init(&attr) == 0,
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0
    else { throw PTYTestError.spawn }
    defer { posix_spawnattr_destroy(&attr) }
    let argv = [executable] + arguments
    let env = environment.map { "\($0.key)=\($0.value)" }
    let argvPointers = SpawnCStrings(argv)
    let envPointers = SpawnCStrings(env)
    defer {
        argvPointers.release()
        envPointers.release()
    }
    var pid: pid_t = 0
    let result = argvPointers.withPointers { argvPointer in
        envPointers.withPointers { envPointer in
            posix_spawn(&pid, executable, &actions, &attr, argvPointer, envPointer)
        }
    }
    try #require(result == 0)
    return pid
}

private struct SpawnCStrings {
    private var storage: [UnsafeMutablePointer<CChar>?]

    init(_ values: [String]) {
        storage = values.map { $0.withCString { strdup($0) } }
        storage.append(nil)
    }

    func withPointers<T>(_ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T) -> T {
        var values = storage
        return values.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }

    func release() {
        for pointer in storage { free(pointer) }
    }
}

private enum PTYTestError: Error {
    case spawn
}

private func compileProbe(in workspace: URL) throws -> URL {
    let file = workspace.appendingPathComponent("pty-probe.c")
    let binary = workspace.appendingPathComponent("pty-probe")
    try Data(probeSource.utf8).write(to: file)
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
    compile.arguments = ["-O2", "-o", binary.path, file.path]
    let errors = Pipe()
    compile.standardOutput = FileHandle.nullDevice
    compile.standardError = errors
    try compile.run()
    compile.waitUntilExit()
    let log = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    try #require(compile.terminationStatus == 0, "clang \(log)")
    return binary
}

private func shortDirectory(prefix: String) throws -> URL {
    var bytes = Array((prefix + "XXXXXX").utf8CString)
    let path = bytes.withUnsafeMutableBufferPointer { buffer -> String? in
        guard let base = buffer.baseAddress, mkdtemp(base) != nil else { return nil }
        return String(cString: base)
    }
    return URL(fileURLWithPath: try #require(path), isDirectory: true)
}

private func builtProduct(_ name: String) throws -> URL {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    var candidates = [
        root.appendingPathComponent(".build/out/Products/Debug/\(name)"),
        root.appendingPathComponent(".build/debug/\(name)"),
        root.appendingPathComponent(".build/arm64-apple-macosx/debug/\(name)"),
    ]
    var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    for _ in 0..<8 {
        candidates.append(directory.appendingPathComponent(name))
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { break }
        directory = parent
    }
    if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
        return found
    }
    throw PTYTestError.spawn
}

private let probeSource = #"""
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <termios.h>
#include <unistd.h>

static volatile sig_atomic_t saw_winch;

static void on_winch(int signo) { (void)signo; saw_winch = 1; }

static int write_all(int fd, const void *buffer, size_t count) {
    const unsigned char *bytes = buffer;
    size_t sent = 0;
    while (sent < count) {
        ssize_t n = write(fd, bytes + sent, count - sent);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        sent += (size_t)n;
    }
    return 0;
}

static int read_full(int fd, void *buffer, size_t count) {
    unsigned char *bytes = buffer;
    size_t got = 0;
    while (got < count) {
        ssize_t n = read(fd, bytes + got, count - got);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        got += (size_t)n;
    }
    return 0;
}

static int read_frame(int fd, char *body, size_t cap) {
    unsigned char header[4];
    if (read_full(fd, header, 4) != 0) return -1;
    size_t length = ((size_t)header[0] << 24) | ((size_t)header[1] << 16)
        | ((size_t)header[2] << 8) | (size_t)header[3];
    if (length == 0 || length + 1 > cap) return -1;
    if (read_full(fd, body, length) != 0) return -1;
    body[length] = 0;
    return (int)length;
}

static int write_frame(int fd, const char *body) {
    size_t length = strlen(body);
    unsigned char header[4] = {
        (unsigned char)((length >> 24) & 0xff),
        (unsigned char)((length >> 16) & 0xff),
        (unsigned char)((length >> 8) & 0xff),
        (unsigned char)(length & 0xff),
    };
    if (write_all(fd, header, 4) != 0) return -1;
    return write_all(fd, body, length);
}

static int extract(const char *json, const char *key, char *out, size_t cap) {
    char pattern[64];
    snprintf(pattern, sizeof pattern, "\"%s\":\"", key);
    const char *found = strstr(json, pattern);
    if (found == NULL) return -1;
    found += strlen(pattern);
    size_t used = 0;
    while (found[used] != 0 && found[used] != '"' && used + 1 < cap) {
        out[used] = found[used];
        used++;
    }
    if (found[used] != '"') return -1;
    out[used] = 0;
    return 0;
}

static int exchange(int request, int response, const char *body, FILE *reply) {
    if (write_frame(request, body) != 0) return -1;
    char incoming[8192];
    if (read_frame(response, incoming, sizeof incoming) < 0) return -1;
    if (fprintf(reply, "%s\n", incoming) < 0) return -1;
    return 0;
}

static const char *kind(int fd) {
    struct stat info;
    if (fstat(fd, &info) != 0) return "closed";
    if (S_ISFIFO(info.st_mode)) return "fifo";
    if (S_ISCHR(info.st_mode)) return "chr";
    return "other";
}

static int park_output(const char *path) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return -1;
    int parked = fcntl(fd, F_DUPFD_CLOEXEC, 20);
    close(fd);
    return parked;
}

static int report_descriptors(FILE *out) {
    int open_list[32];
    int count = 0;
    for (int fd = 0; fd < 20; fd++) {
        if (fcntl(fd, F_GETFD) >= 0 && count < 32) open_list[count++] = fd;
    }
    fprintf(out, "tty %d %d %d\n", isatty(0), isatty(1), isatty(2));
    fprintf(out, "fd3 %s\nfd4 %s\nfd5 %s\n", kind(3), kind(4), kind(5));
    fprintf(out, "open");
    for (int index = 0; index < count; index++) fprintf(out, " %d", open_list[index]);
    fprintf(out, "\n");
    fprintf(out, "pid %d\nsid %d\npgid %d\ntpgid %d\n",
        getpid(), getsid(0), getpgrp(), tcgetpgrp(0));
    return 0;
}

static int cat_file(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 2;
    char buffer[512];
    while (1) {
        ssize_t n = read(fd, buffer, sizeof buffer);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) return 3;
        if (n == 0) break;
        if (write_all(1, buffer, (size_t)n) != 0) return 4;
    }
    close(fd);
    return 0;
}

static int escape_main(int argc, char **argv) {
    if (argc != 5) return 2;
    FILE *leader = fopen(argv[2], "w");
    if (leader == NULL) return 3;
    pid_t self = getpid();
    fprintf(leader, "pid %d\nsid %d\npgid %d\n", self, getsid(0), getpgrp());
    fclose(leader);
    pid_t child = fork();
    if (child < 0) return 4;
    if (child == 0) {
        errno = 0;
        pid_t sid = setsid();
        int setsid_error = sid < 0 ? errno : 0;
        errno = 0;
        int grouped = setpgid(0, 0);
        int setpgid_error = grouped == 0 ? 0 : errno;
        pid_t grand = fork();
        if (grand == 0) {
            FILE *out = fopen(argv[3], "w");
            if (out != NULL) {
                fprintf(out, "pid %d\npgid %d\nsid %d\nsetsid %d\nsetpgid %d\n",
                    getpid(), getpgrp(), getsid(0), setsid_error, setpgid_error);
                fclose(out);
            }
            sleep(60);
            int survived = open(argv[4], O_WRONLY | O_CREAT | O_EXCL, 0644);
            if (survived >= 0) close(survived);
            _exit(0);
        }
        _exit(0);
    }
    sleep(60);
    return 0;
}

static int admit_main(int argc, char **argv) {
    if (argc != 5) return 2;
    int parked = park_output(argv[2]);
    if (parked < 0) return 3;
    FILE *report = fdopen(parked, "w");
    if (report == NULL) return 3;
    report_descriptors(report);
    fclose(report);
    char grant[8192];
    if (read_frame(5, grant, sizeof grant) < 0) return 4;
    char capability[80];
    char session[80];
    if (extract(grant, "capability", capability, sizeof capability) != 0) return 5;
    if (extract(grant, "session", session, sizeof session) != 0) return 5;
    FILE *reply = fopen("admit-replies", "w");
    if (reply == NULL) return 6;
    char body[1600];
    snprintf(body, sizeof body,
        "{\"v\":1,\"id\":\"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\",\"capability\":\"%s\",\"session\":\"%s\",\"command\":\"touch admitted-marker\"}",
        capability, session);
    if (exchange(4, 5, body, reply) != 0) return 7;
    if (exchange(4, 5, body, reply) != 0) return 8;
    snprintf(body, sizeof body,
        "{\"v\":1,\"id\":\"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb\",\"capability\":\"%s\",\"session\":\"%s\",\"command\":\"touch %s\"}",
        capability, session, argv[3]);
    if (exchange(4, 5, body, reply) != 0) return 9;
    snprintf(body, sizeof body,
        "{\"v\":1,\"id\":\"cccccccc-cccc-cccc-cccc-cccccccccccc\",\"capability\":\"%s\",\"session\":\"%s\",\"command\":\"echo hello\"}",
        capability, session);
    if (exchange(4, 5, body, reply) != 0) return 10;
    char fake[65];
    memset(fake, 'b', 64);
    fake[64] = 0;
    snprintf(body, sizeof body,
        "{\"v\":1,\"id\":\"dddddddd-dddd-dddd-dddd-dddddddddddd\",\"capability\":\"%s\",\"session\":\"%s\",\"command\":\"touch admitted-marker\"}",
        fake, session);
    if (exchange(4, 5, body, reply) != 0) return 11;
    snprintf(body, sizeof body,
        "{\"v\":1,\"id\":\"eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee\",\"capability\":\"%s\",\"session\":\"%s\",\"method\":\"GET\",\"url\":\"https://example.com/a\"}",
        capability, session);
    if (exchange(4, 5, body, reply) != 0) return 12;
    fclose(reply);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    if (strcmp(argv[1], "cat") == 0) return cat_file(argv[2]);
    if (strcmp(argv[1], "escape") == 0) return escape_main(argc, argv);
    if (strcmp(argv[1], "interrupt") == 0) {
        struct termios term;
        tcgetattr(0, &term);
        FILE *out = fopen(argv[2], "w");
        if (out == NULL) return 3;
        fprintf(out, "pid %d\nsid %d\npgid %d\ntpgid %d\ntty %d %d %d\nisig %d\nvintr %d\n",
            getpid(), getsid(0), getpgrp(), tcgetpgrp(0), isatty(0), isatty(1), isatty(2),
            (term.c_lflag & ISIG) ? 1 : 0, term.c_cc[VINTR]);
        fclose(out);
        pause();
        return 2;
    }
    if (strcmp(argv[1], "winsz") == 0) {
        sigset_t blocked;
        sigemptyset(&blocked);
        sigaddset(&blocked, SIGWINCH);
        sigprocmask(SIG_UNBLOCK, &blocked, NULL);
        signal(SIGWINCH, on_winch);
        struct winsize size;
        if (ioctl(0, TIOCGWINSZ, &size) != 0) return 3;
        FILE *out = fopen(argv[2], "w");
        if (out == NULL) return 4;
        fprintf(out, "%u %u\n", size.ws_row, size.ws_col);
        fclose(out);
        int matched = 0;
        for (int attempt = 0; attempt < 200; attempt++) {
            if (ioctl(0, TIOCGWINSZ, &size) != 0) return 5;
            if (size.ws_row == 40 && size.ws_col == 100) matched = 1;
            if (matched && saw_winch) {
                FILE *next = fopen(argv[3], "w");
                if (next == NULL) return 6;
                fprintf(next, "%u %u signal 1\n", size.ws_row, size.ws_col);
                fclose(next);
                return 0;
            }
            usleep(50000);
        }
        if (matched) {
            FILE *next = fopen(argv[3], "w");
            if (next == NULL) return 6;
            fprintf(next, "%u %u signal 0 tpgid %d\n", size.ws_row, size.ws_col, tcgetpgrp(0));
            fclose(next);
            return 0;
        }
        return 7;
    }
    if (strcmp(argv[1], "admit") == 0) return admit_main(argc, argv);
    return 2;
}
"""#
#endif
