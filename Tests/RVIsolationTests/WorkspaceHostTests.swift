#if canImport(Darwin)
import Darwin
#endif
import Foundation
import RVDomain
import Synchronization
import Testing
@testable import RVIsolation

@Test func workspaceControlRejectsUnknownVersionAndFields() {
    let close = Data(#"{"v":2,"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","op":"closeWorkspace"}"#.utf8)
    #expect(WorkspaceControlCodec.decode(close) == .incompatible)
    let extra = Data(
        #"{"v":1,"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","op":"cancelRuntime","pid":1}"#.utf8
    )
    #expect(WorkspaceControlCodec.decode(extra) == .invalid)
    let unknown = Data(
        #"{"v":1,"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","op":"killProcess"}"#.utf8
    )
    guard case .message(let message) = WorkspaceControlCodec.decode(unknown) else {
        Issue.record("unknown operation must still decode so the host can refuse it")
        return
    }
    #expect(WorkspaceControlOp(rawValue: message.op) == nil)
    let long = String(repeating: "a", count: 2_048)
    let acceptedArgument = Data(
        """
        {"v":1,"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","op":"launchRuntime","executable":"/bin/sh","arguments":["\(long)"]}
        """.utf8
    )
    #expect(acceptedArgument.count <= WorkspaceControlLimits.maxBodyBytes)
    guard case .message = WorkspaceControlCodec.decode(acceptedArgument) else {
        Issue.record("a long argument within the total command budget should decode")
        return
    }
    let oversized = String(repeating: "a", count: WorkspaceControlLimits.maxLaunchCommandBytes)
    let oversizedCommand = Data(
        """
        {"v":1,"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","op":"launchRuntime","executable":"/bin/sh","arguments":["\(oversized)"]}
        """.utf8
    )
    #expect(oversizedCommand.count <= WorkspaceControlLimits.maxBodyBytes)
    #expect(WorkspaceControlCodec.decode(oversizedCommand) == .invalid)
    var header = UInt32(WorkspaceControlLimits.maxBodyBytes + 1).bigEndian
    let declared = Data(bytes: &header, count: 4)
    #expect(WorkspaceControlCodec.headerCount(declared).isFailure)
    #if os(macOS)
    #expect(WorkspacePeerPolicy.decide(peerUID: 1, ownerUID: 2) == .unauthorizedClient)
    #expect(WorkspacePeerPolicy.decide(peerUID: 2, ownerUID: 2) == nil)
    #expect(WorkspaceAcceptLoop.action(for: ECONNABORTED, retired: false) == .retryImmediately)
    #expect(WorkspaceAcceptLoop.action(for: EINTR, retired: false) == .retryImmediately)
    #expect(WorkspaceAcceptLoop.action(for: EBADF, retired: false) == .stop)
    #expect(WorkspaceAcceptLoop.action(for: ECONNABORTED, retired: true) == .stop)
    #expect(WorkspaceAcceptLoop.action(for: EMFILE, retired: false) == .retryAfterPause)
    let older = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let newer = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let running = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    let dropped = RuntimeRetention.finishedIDsToDrop(
        [
            .init(id: older, startedAt: Date(timeIntervalSince1970: 1), running: false),
            .init(id: newer, startedAt: Date(timeIntervalSince1970: 2), running: false),
            .init(id: running, startedAt: Date(timeIntervalSince1970: 3), running: true),
        ],
        limit: 2
    )
    #expect(dropped == [older])
    #endif
}

#if os(macOS)
@Suite("Workspace host", .serialized)
struct WorkspaceHostTests {
    @Test func workspaceRootPolicyRejectsOnlyTheHomeDirectory() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = parent.appendingPathComponent("home", isDirectory: true)
        let project = home.appendingPathComponent("project", isDirectory: true)
        let homeAlias = parent.appendingPathComponent("home-alias", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: homeAlias, withDestinationURL: home)
        defer { try? FileManager.default.removeItem(at: parent) }

        #expect(WorkspaceRootPolicy.isHomeDirectory(project: home.path, homeDirectory: home.path))
        #expect(WorkspaceRootPolicy.isHomeDirectory(project: homeAlias.path, homeDirectory: home.path))
        #expect(WorkspaceRootPolicy.isHomeDirectory(project: project.path, homeDirectory: home.path) == false)
    }

    @Test func startingNewWorkspaceAtHomeRefusesBeforeLaunchingHost() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let result = WorkspaceHosts.ensure(
            project: home.path,
            executable: URL(fileURLWithPath: "/missing/rv-workspace-host"),
            timeout: 2,
            homeDirectory: home.path
        )
        if case .failure(.homeDirectory) = result {
            return
        }
        Issue.record("new workspaces rooted at home must fail before host launch")
    }

    @Test func clientsAttachDetachAndCancelWithoutSharingAuthority() throws {
        let opened = try TestHost()
        defer { opened.close() }
        let first = try WorkspaceClient.connect(opened.server.endpoint).get()
        let second = try WorkspaceClient.connect(opened.server.endpoint).get()
        let described = try first.describe().get()
        #expect(described.workspace == opened.supervisor.id.rawValue)
        #expect(described.host == opened.server.endpoint.host)
        #expect(described.phase == .active)
        #expect(described.attached == 2)
        let created = WorkspaceLifecycleLog.records(at: opened.lifeLog).filter { $0.kind == .created }.count
        _ = try second.describe().get()
        #expect(WorkspaceLifecycleLog.records(at: opened.lifeLog).filter { $0.kind == .created }.count == created)
        let runtimeA = try first.launchRuntime(
            executable: "/bin/sh",
            arguments: ["-c", "printf from-a > from-a.txt; /bin/sleep 30"]
        ).get()
        #expect(waitFor(opened.tree.workspaceURL.appendingPathComponent("from-a.txt")))
        let listed = try second.listRuntimes().get()
        #expect(listed.contains { $0.runtime == runtimeA.runtime && $0.running })
        let runtimeB = try second.launchRuntime(
            executable: "/bin/sh",
            arguments: ["-c", "printf from-b > from-b.txt; /bin/sleep 30"]
        ).get()
        #expect(waitFor(opened.tree.workspaceURL.appendingPathComponent("from-b.txt")))
        let both = try first.listRuntimes().get().map(\.runtime)
        #expect(Set(both) == Set([runtimeA.runtime, runtimeB.runtime]))
        let response = try #require(WorkspaceControlCodec.encode(
            WorkspaceControlMessage(
                version: 1,
                id: UUID(),
                op: "launchRuntime",
                runtime: runtimeA.runtime,
                ok: true,
                running: true
            )
        ))
        let json = try #require(String(data: response, encoding: .utf8))
        #expect(json.contains("capability") == false)
        #expect(json.contains("pgid") == false)
        let departing = try WorkspaceClient.connect(opened.server.endpoint).get()
        #expect(departing.detach().isSuccess)
        #expect(try second.listRuntimes().get().contains { $0.runtime == runtimeA.runtime && $0.running })
        #expect(opened.supervisor.snapshot.phase == .active)
        #expect(second.cancelRuntime(runtimeA.runtime).isSuccess)
        #expect(try second.listRuntimes().get().contains { $0.runtime == runtimeB.runtime && $0.running })
        #expect(try second.listRuntimes().get().contains { $0.runtime == runtimeA.runtime && $0.running == false })
        let watcher = try WorkspaceClient.connect(opened.server.endpoint).get()
        let watched = WatchBox()
        let thread = Thread {
            watched.result = watcher.watchClose(timeout: 30)
        }
        thread.start()
        Thread.sleep(forTimeInterval: 0.2)
        let closed = try first.closeWorkspace().get()
        #expect(closed.phase == .closed)
        let deadline = Date().addingTimeInterval(10)
        while watched.result == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(watched.result?.isSuccess == true)
        #expect(opened.supervisor.publishCount == 1)
        #expect(opened.supervisor.snapshot.phase == .closed)
        #expect(WorkspaceLifecycleLog.records(at: opened.lifeLog).filter { $0.kind == .closed }.count == 1)
        #expect(opened.supervisor.close().isSuccess)
        #expect(opened.supervisor.publishCount == 1)
    }

    @Test func malformedFramesAndForeignTokensDoNotMutate() throws {
        let opened = try TestHost()
        defer { opened.close() }
        let client = try WorkspaceClient.connect(opened.server.endpoint).get()
        defer { _ = client.detach() }
        var forged = opened.server.endpoint
        forged = WorkspaceEndpoint(
            host: forged.host,
            workspace: forged.workspace,
            canonicalPath: forged.canonicalPath,
            socketPath: forged.socketPath,
            socketDevice: forged.socketDevice,
            socketInode: forged.socketInode,
            ownerToken: UUID(),
            uid: forged.uid
        )
        #expect(WorkspaceClient.connect(forged).isFailure(.unauthorizedClient))
        let fd = try WorkspaceControlSocket.connect(
            path: opened.server.endpoint.socketPath,
            timeout: 2
        ).get()
        defer { close(fd) }
        var huge = UInt32(WorkspaceControlLimits.maxBodyBytes + 8).bigEndian
        let header = Data(bytes: &huge, count: 4)
        let hugeBody = Data(count: WorkspaceControlLimits.maxBodyBytes + 1)
        #expect(WorkspaceControlSocket.writeFrame(fd: fd, body: hugeBody) == false)
        #expect(writeAll(fd: fd, data: header))
        #expect(opened.supervisor.snapshot.phase == .active)
        #expect(opened.supervisor.runtimeFacts().isEmpty)
        let fresh = try WorkspaceClient.connect(opened.server.endpoint).get()
        defer { _ = fresh.detach() }
        let attack = WorkspaceControlMessage(
            version: 1,
            id: UUID(),
            op: "closeWorkspace"
        )
        // Rewrite the version after a legal encode so the host sees a close under v=9.
        let encoded = try #require(WorkspaceControlCodec.encode(attack))
        let text = try #require(String(data: encoded, encoding: .utf8))
            .replacingOccurrences(of: "\"v\":1", with: "\"v\":9")
        let body = Data(text.utf8)
        let raw = try WorkspaceControlSocket.connect(
            path: opened.server.endpoint.socketPath,
            timeout: 2
        ).get()
        defer { close(raw) }
        #expect(WorkspaceControlSocket.writeFrame(fd: raw, body: body))
        let reply = try WorkspaceControlSocket.readFrame(fd: raw, timeout: 2).get()
        guard case .message(let refused) = WorkspaceControlCodec.decode(reply) else {
            Issue.record("unknown version must receive a protocol error")
            return
        }
        #expect(refused.ok == false)
        #expect(refused.error == WorkspaceControlCode.incompatibleProtocol.rawValue)
        #expect(opened.supervisor.snapshot.phase == .active)
        #expect(opened.supervisor.publishCount == 0)
        var mode = stat()
        #expect(opened.server.endpoint.socketPath.withCString { lstat($0, &mode) == 0 })
        #expect(mode.st_mode & 0o777 == 0o600)
        let parent = (opened.server.endpoint.socketPath as NSString).deletingLastPathComponent
        #expect(WorkspaceSocketMode.isOwnerDirectory(parent))
    }

    @Test func hostSurvivesTheCreatingClientAndAKilledClient() throws {
        let home = try shortDirectory(prefix: "/tmp/rvw")
        defer { try? FileManager.default.removeItem(at: home) }
        let workspace = home.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let hostBinary = try builtProduct("rv-workspace-host")
        let rvBinary = try builtProduct("rv")
        let pidFile = home.appendingPathComponent("host.pid")
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sh")
        parent.arguments = [
            "-c",
            "\"$1\" --workspace \"$2\" >/dev/null 2>&1 & echo $! > \"$3\"; exit 0",
            "sh",
            hostBinary.path,
            workspace.path,
            pidFile.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        parent.environment = environment
        try parent.run()
        parent.waitUntilExit()
        #expect(parent.terminationStatus == 0)
        let hostPID = pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        let host = try #require(hostPID)
        defer { terminate(host) }
        let config = home.appendingPathComponent(".config/rv", isDirectory: true)
        let endpoint = try #require(waitLive(project: workspace.path, configuration: config, seconds: 60))
        #expect(kill(host, 0) == 0)
        let owner = try WorkspaceClient.connect(endpoint).get()
        let runtime = try owner.launchRuntime(
            executable: "/bin/sh",
            arguments: ["-c", "printf live > live.txt; /bin/sleep 30"]
        ).get()
        #expect(waitFor(workspace.appendingPathComponent("live.txt")))
        _ = owner.detach()
        let attach = Process()
        attach.executableURL = rvBinary
        attach.arguments = ["workspace", "attach", "--workspace", workspace.path]
        attach.environment = environment
        let input = Pipe()
        attach.standardInput = input
        let output = Pipe()
        attach.standardOutput = output
        let captured = OutputBox()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty == false { captured.append(data) }
        }
        try attach.run()
        let attached = waitUntil(seconds: 20) { captured.text.contains("attached") }
        #expect(attached)
        kill(attach.processIdentifier, SIGKILL)
        attach.waitUntilExit()
        let again = try WorkspaceClient.connect(endpoint).get()
        #expect(try again.listRuntimes().get().contains { $0.runtime == runtime.runtime && $0.running })
        #expect(try again.describe().get().phase == .active)
        #expect(kill(host, 0) == 0)
        kill(host, SIGTERM)
        #expect(waitUntil(seconds: 5) { kill(host, 0) != 0 })
        #expect(again.ping().isFailure)
        let afterDeath = WorkspaceDiscovery.inspect(
            project: workspace.path,
            configurationDirectory: config
        )
        if case .live = afterDeath {
            Issue.record("a dead host must not stay discoverable as live")
        }
        let restarted = Process()
        restarted.executableURL = hostBinary
        restarted.arguments = ["--workspace", workspace.path]
        restarted.environment = environment
        try restarted.run()
        defer { terminate(restarted.processIdentifier) }
        let recovered = try #require(waitLive(project: workspace.path, configuration: config, seconds: 90))
        #expect(recovered.workspace != endpoint.workspace)
        let closing = try WorkspaceClient.connect(recovered).get()
        #expect(try closing.closeWorkspace().get().phase == .closed)
        restarted.waitUntilExit()
    }

    @Test func hostDeathDuringAPtyRuntimeIsOrphanedNotReattachable() throws {
        let home = try shortDirectory(prefix: "/tmp/rvp")
        defer { try? FileManager.default.removeItem(at: home) }
        let workspace = home.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let hostBinary = try builtProduct("rv-workspace-host")
        let pidFile = home.appendingPathComponent("host.pid")
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sh")
        parent.arguments = [
            "-c",
            "\"$1\" --workspace \"$2\" >/dev/null 2>&1 & echo $! > \"$3\"; exit 0",
            "sh",
            hostBinary.path,
            workspace.path,
            pidFile.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        parent.environment = environment
        try parent.run()
        parent.waitUntilExit()
        #expect(parent.terminationStatus == 0)
        let hostPID = pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        let host = try #require(hostPID)
        defer { terminate(host) }
        let config = home.appendingPathComponent(".config/rv", isDirectory: true)
        let endpoint = try #require(waitLive(project: workspace.path, configuration: config, seconds: 60))
        let owner = try WorkspaceClient.connect(endpoint).get()
        let runtime = try owner.launchRuntime(
            executable: "/bin/sh",
            arguments: ["-c", "printf '%s\\n' $$ > pty-death.pid; exec /bin/sleep 120"],
            terminalRows: 24,
            terminalColumns: 80
        ).get()
        #expect(runtime.terminal)
        #expect(runtime.running)
        let childFile = workspace.appendingPathComponent("pty-death.pid")
        #expect(waitFor(childFile))
        let child = pid_t(
            try String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let childPID = try #require(child)
        defer {
            if kill(childPID, 0) == 0 { kill(childPID, SIGKILL) }
        }
        try #require(owner.subscribeTerminal(runtime.runtime).get() == ())
        kill(host, SIGKILL)
        #expect(waitUntil(seconds: 5) { kill(host, 0) != 0 })
        #expect(owner.ping().isFailure)
        #expect(owner.subscribeTerminal(runtime.runtime).isFailure)
        let afterDeath = WorkspaceDiscovery.inspect(
            project: workspace.path,
            configurationDirectory: config
        )
        guard case .orphaned = afterDeath else {
            Issue.record("host death must classify the workspace as orphaned, got \(afterDeath)")
            return
        }
        #expect(WorkspaceClient.connect(endpoint).isFailure)
        let restarted = Process()
        restarted.executableURL = hostBinary
        restarted.arguments = ["--workspace", workspace.path]
        restarted.environment = environment
        try restarted.run()
        defer { terminate(restarted.processIdentifier) }
        let recovered = try #require(waitLive(project: workspace.path, configuration: config, seconds: 90))
        #expect(recovered.workspace != endpoint.workspace)
        #expect(waitUntil(seconds: 10) { kill(childPID, 0) != 0 })
        let closing = try WorkspaceClient.connect(recovered).get()
        let described = try closing.describe().get()
        #expect(described.workspace == recovered.workspace)
        #expect(described.phase == .active)
        #expect(try closing.listRuntimes().get().contains { $0.runtime == runtime.runtime } == false)
        #expect(try closing.closeWorkspace().get().phase == .closed)
        restarted.waitUntilExit()
    }

    @Test func workspaceStartLeavesALiveHostAfterTheClientExits() throws {
        let home = try shortDirectory(prefix: "/tmp/rvs")
        defer { try? FileManager.default.removeItem(at: home) }
        let workspace = home.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let rvBinary = try builtProduct("rv")
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        let start = Process()
        start.executableURL = rvBinary
        start.arguments = ["workspace", "start", "--workspace", workspace.path]
        start.environment = environment
        try start.run()
        start.waitUntilExit()
        #expect(start.terminationStatus == 0)
        let config = home.appendingPathComponent(".config/rv", isDirectory: true)
        let endpoint = try #require(waitLive(project: workspace.path, configuration: config, seconds: 60))
        let client = try WorkspaceClient.connect(endpoint).get()
        let described = try client.describe().get()
        #expect(described.workspace == endpoint.workspace)
        #expect(described.phase == .active)
        #expect(described.attached == 1)
        #expect(try client.closeWorkspace().get().phase == .closed)
    }

    @Test func simultaneousCreatorsProduceOneOwner() throws {
        let home = try shortDirectory(prefix: "/tmp/rvr")
        defer { try? FileManager.default.removeItem(at: home) }
        let workspace = home.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let hostBinary = try builtProduct("rv-workspace-host")
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        let first = Process()
        let second = Process()
        for process in [first, second] {
            process.executableURL = hostBinary
            process.arguments = ["--workspace", workspace.path]
            process.environment = environment
        }
        try first.run()
        try second.run()
        defer {
            terminate(first.processIdentifier)
            terminate(second.processIdentifier)
        }
        let config = home.appendingPathComponent(".config/rv", isDirectory: true)
        let endpoint = try #require(waitLive(project: workspace.path, configuration: config, seconds: 60))
        let deadline = Date().addingTimeInterval(30)
        var loser: Int32?
        while Date() < deadline, loser == nil {
            if first.isRunning == false { loser = first.terminationStatus }
            if second.isRunning == false { loser = second.terminationStatus }
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(loser == WorkspaceHostExit.liveOwner)
        #expect(first.isRunning != second.isRunning)
        let log = config.appendingPathComponent("workspace-sessions.jsonl")
        let openCreated = WorkspaceLifecycleLog.records(at: log).filter {
            $0.kind == .created && $0.workspace == endpoint.workspace
        }
        #expect(openCreated.count == 1)
        let client = try WorkspaceClient.connect(endpoint).get()
        #expect(try client.describe().get().workspace == endpoint.workspace)
        #expect(try client.closeWorkspace().get().phase == .closed)
    }

    @Test func runningLimitRefusesASecondLaunch() throws {
        let opened = try TestHost()
        defer { opened.close() }
        let command = try #require(IsolatedCommand(
            executable: "/bin/sh",
            arguments: ["-c", "/bin/sleep 30"]
        ))
        let plan = compileContainedPlan(workspace: opened.supervisor.snapshot.policyWorkspace)
        let log = opened.tree.rootURL.appendingPathComponent("runtime-limit.jsonl")
        let first = try opened.supervisor.launch(
            host: nil,
            command: command,
            plan: plan,
            io: .discard,
            admission: .failClosed,
            sessionStore: .file(log),
            runningLimit: 1
        ).get()
        let second = opened.supervisor.launch(
            host: nil,
            command: command,
            plan: plan,
            io: .discard,
            admission: .failClosed,
            sessionStore: .file(log),
            runningLimit: 1
        )
        guard case .failure(.runtimeLimit) = second else {
            Issue.record("a second running runtime must be refused at the cap")
            return
        }
        #expect(opened.supervisor.runtimeFacts().contains { $0.id == first.id.rawValue && $0.running })
    }

    @Test func oneClientSerializesOverlappedCalls() throws {
        let opened = try TestHost()
        defer { opened.close() }
        let client = try WorkspaceClient.connect(opened.server.endpoint).get()
        defer { _ = client.detach() }
        let box = OverlapBox()
        for _ in 0..<8 {
            box.reset()
            let thread = Thread {
                box.finish(client.ping())
            }
            thread.start()
            let primary = client.ping()
            let deadline = Date().addingTimeInterval(5)
            while box.secondary == nil, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            #expect(primary.isSuccess)
            #expect(box.secondary?.isSuccess == true)
        }
    }

    @Test func negotiatedFeaturesRejectHostsWithoutRequiredCapabilities() {
        #expect(WorkspaceClient.negotiatedFeatures(from: .failure(.invalidRequest))
            .isFailure(.incompatibleProtocol))
        #expect(WorkspaceClient.negotiatedFeatures(from: .failure(.timedOut)).isFailure)
        let reply = WorkspaceControlMessage(
            version: 1,
            id: UUID(),
            op: WorkspaceControlOp.capabilities.rawValue,
            ok: true,
            features: [
                WorkspaceControlFeature.ensureTerminalRuntime,
                WorkspaceControlFeature.resizeLeaseAuthority,
                WorkspaceControlFeature.runtimeResourceProfilesV1,
                WorkspaceControlFeature.terminalReplayBatchesV1,
            ]
        )
        guard case .success(let features) = WorkspaceClient.negotiatedFeatures(from: .success(reply)) else {
            Issue.record("capabilities reply must map to its features")
            return
        }
        #expect(WorkspaceClient.acceptsHostFeatures(features))
        let wrongOp = WorkspaceControlMessage(
            version: 1,
            id: UUID(),
            op: WorkspaceControlOp.ping.rawValue,
            ok: true,
            features: []
        )
        #expect(WorkspaceClient.negotiatedFeatures(from: .success(wrongOp)).isFailure)
    }

    @Test func leaseResizeResourcesAndReplayBatchesAreRequiredHostFeatures() {
        #expect(WorkspaceClient.acceptsHostFeatures([]) == false)
        #expect(WorkspaceClient.acceptsHostFeatures([WorkspaceControlFeature.ensureTerminalRuntime]) == false)
        #expect(WorkspaceClient.acceptsHostFeatures([WorkspaceControlFeature.resizeLeaseAuthority]) == false)
        #expect(WorkspaceClient.acceptsHostFeatures([
            WorkspaceControlFeature.ensureTerminalRuntime,
            WorkspaceControlFeature.resizeLeaseAuthority,
        ]) == false)
        #expect(WorkspaceClient.acceptsHostFeatures([
            WorkspaceControlFeature.ensureTerminalRuntime,
            WorkspaceControlFeature.resizeLeaseAuthority,
            WorkspaceControlFeature.runtimeResourceProfilesV1,
        ]) == false)
        #expect(WorkspaceClient.acceptsHostFeatures([
            WorkspaceControlFeature.ensureTerminalRuntime,
            WorkspaceControlFeature.resizeLeaseAuthority,
            WorkspaceControlFeature.runtimeResourceProfilesV1,
            WorkspaceControlFeature.terminalReplayBatchesV1,
        ]))
    }

    @Test func oldLiveHostRequiresRestartWithoutStoppingItsRuntime() throws {
        let opened = try TestHost(advertisedFeatures: [WorkspaceControlFeature.ensureTerminalRuntime])
        defer { opened.close() }
        let raw = try WorkspaceControlSocket.connect(path: opened.server.endpoint.socketPath, timeout: 2).get()
        defer { close(raw) }
        let hello = WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            id: UUID(),
            op: WorkspaceControlOp.hello.rawValue,
            token: opened.server.endpoint.ownerToken
        )
        let helloBody = try #require(WorkspaceControlCodec.encode(hello))
        #expect(WorkspaceControlSocket.writeFrame(fd: raw, body: helloBody))
        _ = try WorkspaceControlSocket.readFrame(fd: raw, timeout: 2).get()
        let launch = WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            id: UUID(),
            op: WorkspaceControlOp.launchRuntime.rawValue,
            executable: "/bin/sh",
            arguments: ["-c", "/bin/sleep 30"],
            io: "terminal",
            rows: 24,
            columns: 80
        )
        let launchBody = try #require(WorkspaceControlCodec.encode(launch))
        #expect(WorkspaceControlSocket.writeFrame(fd: raw, body: launchBody))
        let reply = try WorkspaceControlSocket.readFrame(fd: raw, timeout: 10).get()
        guard case .message(let launched) = WorkspaceControlCodec.decode(reply) else {
            Issue.record("legacy host launch response did not decode")
            return
        }
        let runtime = try #require(launched.runtime)
        #expect(launched.ok == true)
        #expect(WorkspaceClient.connect(opened.server.endpoint).isFailure(.incompatibleProtocol))

        let ensured = WorkspaceHosts.ensure(
            project: opened.tree.workspaceURL.path,
            executable: URL(fileURLWithPath: "/missing-rv-workspace-host"),
            timeout: 1,
            homeDirectory: "/not-the-workspace",
            inspect: { _ in .live(opened.server.endpoint) }
        )
        #expect(ensured == .failure(.control(.incompatibleProtocol)))
        #expect(opened.supervisor.runtimeFacts().contains { $0.id == runtime && $0.running })
        #expect(opened.supervisor.snapshot.phase == .active)
    }

    @Test func explicitProfilesKeepSyntheticCredentialsAndSupportDisjoint() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let config = tree.rootURL.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let sourceA = tree.rootURL.appendingPathComponent("credential-a")
        let sourceB = tree.rootURL.appendingPathComponent("credential-b")
        let supportA = tree.rootURL.appendingPathComponent("support-a")
        let supportB = tree.rootURL.appendingPathComponent("support-b")
        for (url, value) in [
            (sourceA, "synthetic-a"), (sourceB, "synthetic-b"),
            (supportA, "support-a"), (supportB, "support-b"),
        ] {
            try Data(value.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let directory = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
        let supervisor = try WorkspaceSessionSupervisor.open(
            directory, lifecycleLog: .file(config.appendingPathComponent("life.jsonl"))
        ).get()
        let canonicalProject = supervisor.snapshot.originalPath.rawValue
        let policy = RuntimeResourcePolicy(profiles: [
            RuntimeResourceProfile(
                id: "alpha", projects: [canonicalProject], readFiles: [supportA.path],
                credentials: [.init(source: sourceA.path, destination: ".config/auth")]
            ),
            RuntimeResourceProfile(
                id: "beta", projects: [canonicalProject], readFiles: [supportB.path],
                credentials: [.init(source: sourceB.path, destination: ".config/auth")]
            ),
        ])
        let server = try WorkspaceHostServer.start(
            supervisor: supervisor, configurationDirectory: config,
            sessionStore: .file(config.appendingPathComponent("runtime.jsonl")),
            resourcePolicy: policy
        ).get()
        defer { server.stop(); _ = supervisor.close() }
        let client = try WorkspaceClient.connect(server.endpoint).get()

        let marker = tree.workspaceURL.appendingPathComponent("unapproved-marker")
        let oversized = client.launchRuntime(
            executable: "/bin/sh",
            arguments: [String(repeating: "x", count: WorkspaceControlLimits.maxLaunchCommandBytes)]
        )
        #expect(oversized.isFailure(.launchCommandTooLarge))
        let denied = client.launchRuntime(
            executable: "/bin/sh", arguments: ["-c", "echo bad > unapproved-marker"],
            resourceProfileID: "missing"
        )
        #expect(denied.isFailure(.resourceProfileUnavailable))
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)

        _ = try client.launchRuntime(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "cat \"$HOME/.config/auth\" > selected-a; cat \"$1\" > seen-a; "
                    + "if cat \"$2\" >/dev/null 2>&1; then echo leak > leak-b; fi; "
                    + "printf '%s' \"$HOME\" > home-a; /bin/sleep 30",
                "rv", supportA.path, supportB.path,
            ],
            resourceProfileID: "alpha"
        ).get()
        #expect(waitFor(tree.workspaceURL.appendingPathComponent("home-a")))
        #expect(try String(contentsOf: tree.workspaceURL.appendingPathComponent("selected-a"), encoding: .utf8)
            == "synthetic-a")
        #expect(try String(contentsOf: tree.workspaceURL.appendingPathComponent("seen-a"), encoding: .utf8)
            == "support-a")
        #expect(FileManager.default.fileExists(atPath: tree.workspaceURL.appendingPathComponent("leak-b").path) == false)

        _ = try client.launchRuntime(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "cat \"$HOME/.config/auth\" > selected-b; "
                    + "if cat \"$(cat home-a)/.config/auth\" >/dev/null 2>&1; then echo leak > leak-a; fi",
            ],
            resourceProfileID: "beta"
        ).get()
        #expect(waitFor(tree.workspaceURL.appendingPathComponent("selected-b")))
        #expect(try String(contentsOf: tree.workspaceURL.appendingPathComponent("selected-b"), encoding: .utf8)
            == "synthetic-b")
        #expect(FileManager.default.fileExists(atPath: tree.workspaceURL.appendingPathComponent("leak-a").path) == false)
        #expect(FileManager.default.fileExists(atPath: tree.workspaceURL.appendingPathComponent(".config/auth").path)
            == false)
    }

    @Test func hookAndProfileStayOrthogonalAtLaunch() throws {
        let opened = try TestHost()
        defer { opened.close() }
        let client = try WorkspaceClient.connect(opened.server.endpoint).get()
        defer { _ = client.detach() }
        // A declared hook does not bypass profile enforcement.
        let refused = client.launchRuntime(
            executable: "/bin/sh", arguments: ["-c", "/bin/sleep 30"],
            hook: "opencode", resourceProfileID: "missing"
        )
        #expect(refused.isFailure(.resourceProfileUnavailable))
        // A declared hook is recorded and echoed back.
        let hooked = try client.launchRuntime(
            executable: "/bin/sh", arguments: ["-c", "/bin/sleep 30"], hook: "codex"
        ).get()
        #expect(hooked.hook == "codex")
        #expect(opened.supervisor.runtimeFacts().contains { $0.id == hooked.runtime && $0.hookHost == "codex" })
        // A hook-less launch stays hook-less: no backfill from behavior.
        let plain = try client.launchRuntime(
            executable: "/bin/sh", arguments: ["-c", "/bin/sleep 30"]
        ).get()
        #expect(plain.hook == nil)
    }

    @Test func malformedHookTagIsRefusedClientSideBeforeSpawn() throws {
        let opened = try TestHost()
        defer { opened.close() }
        let client = try WorkspaceClient.connect(opened.server.endpoint).get()
        defer { _ = client.detach() }
        let factsBefore = opened.supervisor.runtimeFacts().count
        #expect(client.launchRuntime(
            executable: "/bin/sh", arguments: ["-c", "/bin/sleep 30"], hook: "not a tag!"
        ).isFailure(.invalidRequest))
        #expect(client.ensureTerminalRuntime(
            executable: "/bin/sh", arguments: ["-c", "/bin/sleep 30"], hook: "not a tag!",
            terminalRows: 24, terminalColumns: 80
        ).isFailure(.invalidRequest))
        #expect(opened.supervisor.runtimeFacts().count == factsBefore)
    }

    @Test func stagingOnlyTagStagesFilteredCredentialsWithoutHookRecord() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let config = tree.rootURL.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let secret = tree.rootURL.appendingPathComponent("synthetic-muse.auth")
        try Data("synthetic-muse-secret".utf8).write(to: secret)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)
        let directory = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
        let supervisor = try WorkspaceSessionSupervisor.open(
            directory, lifecycleLog: .file(config.appendingPathComponent("life.jsonl"))
        ).get()
        let policy = RuntimeResourcePolicy(profiles: [
            RuntimeResourceProfile(
                id: "phase04", projects: [supervisor.snapshot.originalPath.rawValue],
                credentials: [.init(
                    source: secret.path, destination: ".config/staged.auth", agents: ["muse"]
                )]
            ),
        ])
        let server = try WorkspaceHostServer.start(
            supervisor: supervisor, configurationDirectory: config,
            sessionStore: .file(config.appendingPathComponent("runtime.jsonl")),
            resourcePolicy: policy
        ).get()
        defer { server.stop(); _ = supervisor.close() }
        let client = try WorkspaceClient.connect(server.endpoint).get()
        defer { _ = client.detach() }
        // "muse" names no HookHost: staging-only. The filtered credential
        // stages, but no hook protocol participation is recorded or echoed.
        let staged = try client.launchRuntime(
            executable: "/bin/sh",
            arguments: ["-c", "cat \"$HOME/.config/staged.auth\" > proved-muse.txt"],
            hook: "muse",
            resourceProfileID: "phase04"
        ).get()
        #expect(staged.hook == nil)
        #expect(openedHookHost(supervisor, staged.runtime) == nil)
        // Poll for content, not mere existence: the shell creates the file
        // before `cat` finishes writing it.
        #expect(waitUntil(seconds: 20) {
            (try? String(
                contentsOf: tree.workspaceURL.appendingPathComponent("proved-muse.txt"), encoding: .utf8
            )) == "synthetic-muse-secret"
        })
        // A known host that does not match the filter stages nothing.
        _ = try client.launchRuntime(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "if cat \"$HOME/.config/staged.auth\" >/dev/null 2>&1; then echo leak > leak-codex.txt; fi; "
                    + "printf launched > launched-codex.txt",
            ],
            hook: "codex",
            resourceProfileID: "phase04"
        ).get()
        // The marker prints last, so its presence proves the leak branch ran.
        #expect(waitFor(tree.workspaceURL.appendingPathComponent("launched-codex.txt")))
        #expect(FileManager.default.fileExists(atPath: tree.workspaceURL.appendingPathComponent("leak-codex.txt").path)
            == false)
    }

    @Test func malformedHookTagIsRefusedBeforeSpawn() throws {
        let opened = try TestHost()
        defer { opened.close() }
        let factsBefore = opened.supervisor.runtimeFacts().count
        let raw = try WorkspaceControlSocket.connect(path: opened.server.endpoint.socketPath, timeout: 2).get()
        defer { close(raw) }
        let hello = WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            id: UUID(),
            op: WorkspaceControlOp.hello.rawValue,
            token: opened.server.endpoint.ownerToken
        )
        let helloBody = try #require(WorkspaceControlCodec.encode(hello))
        #expect(WorkspaceControlSocket.writeFrame(fd: raw, body: helloBody))
        _ = try WorkspaceControlSocket.readFrame(fd: raw, timeout: 2).get()
        let launch = WorkspaceControlMessage(
            version: WorkspaceControlLimits.version,
            id: UUID(),
            op: WorkspaceControlOp.launchRuntime.rawValue,
            executable: "/bin/sh",
            arguments: ["-c", "/bin/sleep 30"],
            hook: "not a tag!",
            io: "terminal",
            rows: 24,
            columns: 80
        )
        let launchBody = try #require(WorkspaceControlCodec.encode(launch))
        #expect(WorkspaceControlSocket.writeFrame(fd: raw, body: launchBody))
        let reply = try WorkspaceControlSocket.readFrame(fd: raw, timeout: 10).get()
        guard case .message(let refused) = WorkspaceControlCodec.decode(reply) else {
            Issue.record("malformed-hook launch response did not decode")
            return
        }
        #expect(refused.ok != true)
        #expect(refused.error == WorkspaceControlCode.invalidRequest.rawValue)
        #expect(opened.supervisor.runtimeFacts().count == factsBefore)
    }

}

private final class WatchBox: Sendable {
    private let box = Mutex<Result<WorkspaceDescription, WorkspaceClientFailure>?>(nil)

    var result: Result<WorkspaceDescription, WorkspaceClientFailure>? {
        get { box.withLock { $0 } }
        set { box.withLock { $0 = newValue } }
    }
}

private final class OverlapBox: Sendable {
    private let box = Mutex<Result<Void, WorkspaceClientFailure>?>(nil)

    func reset() {
        box.withLock { $0 = nil }
    }

    func finish(_ result: Result<Void, WorkspaceClientFailure>) {
        box.withLock { $0 = result }
    }

    var secondary: Result<Void, WorkspaceClientFailure>? {
        box.withLock { $0 }
    }
}

private final class OutputBox: Sendable {
    private let box = Mutex(Data())

    func append(_ next: Data) {
        box.withLock { $0.append(next) }
    }

    var text: String {
        let copy = box.withLock { $0 }
        return String(data: copy, encoding: .utf8) ?? ""
    }
}

private struct TestHost {
    var tree: ContainmentTree
    var supervisor: WorkspaceSessionSupervisor
    var server: WorkspaceHostServer
    var lifeLog: URL

    init(advertisedFeatures: [String]? = nil) throws {
        tree = try ContainmentTree()
        let config = tree.rootURL.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        lifeLog = config.appendingPathComponent("workspace-sessions.jsonl")
        let runtime = config.appendingPathComponent("runtime-sessions.jsonl")
        let directory = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
        supervisor = try WorkspaceSessionSupervisor.open(directory, lifecycleLog: .file(lifeLog)).get()
        server = try WorkspaceHostServer.start(
            supervisor: supervisor,
            configurationDirectory: config,
            sessionStore: .file(runtime),
            advertisedFeatures: advertisedFeatures
        ).get()
    }

    func close() {
        server.stop()
        _ = supervisor.close()
        tree.tearDown()
    }
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

private func waitFor(_ url: URL) -> Bool {
    waitUntil(seconds: 20) { FileManager.default.fileExists(atPath: url.path) }
}

private func openedHookHost(_ supervisor: WorkspaceSessionSupervisor, _ id: UUID) -> String? {
    supervisor.runtimeFacts().first { $0.id == id }?.hookHost
}

private func waitUntil(seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
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
    Issue.record("missing built product \(name)")
    throw WorkspaceHostFailure.hostBinaryMissing
}

private func shortDirectory(prefix: String) throws -> URL {
    var bytes = Array((prefix + "XXXXXX").utf8CString)
    let path = bytes.withUnsafeMutableBufferPointer { buffer -> String? in
        guard let base = buffer.baseAddress, mkdtemp(base) != nil else { return nil }
        return String(cString: base)
    }
    return URL(fileURLWithPath: try #require(path), isDirectory: true)
}

private func terminate(_ pid: pid_t) {
    guard pid > 1 else { return }
    kill(pid, SIGKILL)
    var status: Int32 = 0
    _ = waitpid(pid, &status, WNOHANG)
}

private func writeAll(fd: Int32, data: Data) -> Bool {
    var offset = 0
    let bytes = [UInt8](data)
    while offset < bytes.count {
        let count = bytes.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return write(fd, base.advanced(by: offset), bytes.count - offset)
        }
        if count > 0 {
            offset += count
            continue
        }
        if count < 0, errno == EINTR { continue }
        return false
    }
    return true
}
#endif

extension Result where Failure: Equatable {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }

    func isFailure(_ failure: Failure) -> Bool {
        if case .failure(let error) = self { return error == failure }
        return false
    }
}

extension Result where Failure == WorkspaceControlCode {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
