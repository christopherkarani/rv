#if os(macOS)
import Darwin
import Foundation
@testable import RVIsolation
import Synchronization
import Testing
@testable import RVMCP

/// Whether the real suspended spawn and kernel peer check work here.
private let hostBindsPlaceholders = SecretRunCapability.check(.runtime) == nil

/// Records what the gateway forwards and answers 200.
private final class FixtureUpstream: Sendable {
    let authorizations = Mutex<[String]>([])

    var transport: SecretUpstreamTransport {
        SecretUpstreamTransport { request, sink in
            let authorization = request.headers.first { $0.name.lowercased() == "authorization" }?.value ?? ""
            self.authorizations.withLock { $0.append(authorization) }
            sink.head(status: 200, headers: [])
            sink.finish()
        }
    }
}

private func contents(_ directory: URL, _ name: String) -> String {
    let text = (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Polls `condition` for up to `seconds`; the test thread never blocks in a wait call.
private func eventually(_ seconds: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while condition() == false {
        guard Date() < deadline else { return false }
        usleep(20_000)
    }
    return true
}

/// One raw HTTP/1.1 request to 127.0.0.1:`port`; the status code, or nil.
private func loopbackStatus(port: Int, _ request: String) -> Int? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { return nil }
    let bytes = Array(request.utf8)
    guard write(fd, bytes, bytes.count) == bytes.count else { return nil }
    var response = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &chunk, chunk.count)
        guard n > 0 else { break }
        response.append(contentsOf: chunk[0..<n])
    }
    let line = String(decoding: response.prefix { $0 != 0x0D }, as: UTF8.self)
    return line.split(separator: " ").dropFirst().first.flatMap { Int($0) }
}

/// A stdio MCP server through the real planner, the runtime and
/// `sandbox-exec`, caged by `cage(home:configDirectory:)`.
@Suite("MCP server placeholders (live sandbox-exec)")
struct MCPPlaceholderLiveTests {
    @Test(.enabled(if: hostBindsPlaceholders && MCPSandbox.enforced), .timeLimit(.minutes(2)))
    func aCagedServerSpendsItsPlaceholderAndServeEndsItsWholeGroup() throws {
        // A fake home, never the real one. Spelled as the kernel resolves it
        // (no /var firmlink), since the cage refuses a write root that
        // resolves elsewhere.
        let temporary = try #require(MCPSandbox.resolveExisting(FileManager.default.temporaryDirectory.path))
        let root = URL(fileURLWithPath: temporary, isDirectory: true)
            .appendingPathComponent("rv-placeholder-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
        let name = "placeholder-live"
        let scratch = home.appendingPathComponent("Library/Caches/rv-mcp/\(name)", isDirectory: true)
        let fixture = try PlaceholderSecretsFixture()
        defer { fixture.tearDown() }
        let upstream = FixtureUpstream()
        let broker = SecretPlaceholderBroker(
            configDirectory: fixture.directory, resolver: CountingResolver().resolver, transport: upstream.transport)
        defer { broker.stop() }

        // The server answers nothing and ignores its stdin closing and
        // SIGTERM's grandchild: only the group kill after the leader exits
        // ends `sleep`. The probe asks the kernel for its parent's arguments
        // and environment (`KERN_PROCARGS2`), which is where a secret read
        // from rv's own environment would be.
        let probe = try mcpProbe()
        // A process of this user outside the cage, not a platform binary,
        // with an environment: it waits on its stdin until the test ends.
        let outside = Process()
        outside.executableURL = probe
        outside.arguments = ["hold"]
        outside.environment = ["HOME": "/rv-procargs-outside", "PATH": "/usr/bin:/bin"]
        let outsideInput = Pipe()
        outside.standardInput = outsideInput
        outside.standardOutput = FileHandle.nullDevice
        outside.standardError = FileHandle.nullDevice
        try outside.run()
        defer {
            try? outsideInput.fileHandleForWriting.close()
            if outside.isRunning { kill(outside.processIdentifier, SIGKILL) }
            outside.waitUntilExit()
        }
        // Readable from here once it runs the probe's image: the cage's
        // refusal below is then the cage's, not a process still starting.
        let outsideRead = Self.procargsFromHere(probe, readableWithin: 10, outside.processIdentifier, in: root)
        try #require(outsideRead.hasSuffix(" home=yes"), "the outside process never showed its environment here: \(outsideRead)")
        let script = """
            out="$1"
            env > "$out/env"; printf '%s %s' "$*" > "$out/argv"; echo $$ > "$out/pid"; echo $PPID > "$out/ppid"
            "$2" procargs $PPID > "$out/procargs" 2>&1
            "$2" procargs self > "$out/procargs-self" 2>&1
            "$2" procargs "$3" > "$out/procargs-outside" 2>&1
            /usr/bin/curl -s --max-time 10 --noproxy '*' -o /dev/null -w '%{http_code}' \
              -H "Authorization: Bearer $OPENAI_API_KEY" "$OPENAI_BASE_URL/models" > "$out/status"
            /bin/sh -c 'trap "" TERM; /bin/sleep 60' & echo $! > "$out/grandchild"
            echo ready > "$out/ready"
            while :; do /bin/sleep 0.05; done
            """
        let definition = MCPServerDefinition(
            name: name, command: "/bin/sh",
            args: ["-c", script, "sh", scratch.path, probe.path, String(outside.processIdentifier)],
            sandbox: MCPSandboxPolicy(network: false), placeholders: ["OPENAI_API_KEY"])
        let configuration = MCPConfiguration(servers: [definition])
        let planned = try MCPLaunchPlanner.plan(
            servers: [name], configuration: configuration, secrets: PlaceholderSecretsFixture.definitions(),
            resolver: CountingResolver().resolver, baseEnvironment: ["PATH": "/usr/bin:/bin"], requireSandbox: true,
            sandbox: Self.cage(home: home, configDirectory: fixture.directory), placeholders: .broker(broker)
        ).get()
        guard case .placeholderBound(let launch, let binding) = planned.first?.1 else {
            Issue.record("not bound: \(String(describing: planned.first?.1))")
            return
        }
        let port = binding.lease.gatewayPort
        #expect(launch.executable == MCPSandbox.sandboxExec)
        #expect(launch.arguments.contains { $0.contains("(remote tcp \"localhost:\(port)\")") })

        let client = LineClient()
        let core = MCPGatewayCore(
            configuration: configuration, upstreams: planned.map { $0.0 },
            approvals: MCPApprovalGate(consumeGrant: { _, _, _, _, _ in .none }, request: { _, _, _, _, _ in nil }),
            pinning: .unenforced, recordForward: { _ in true })
        let bindings = Mutex<[String]>([])
        let runtime = MCPGatewayRuntime(
            core: core, connections: planned.map { $0.1 },
            input: client.toGateway.fileHandleForReading.fileDescriptor,
            output: client.fromGateway.fileHandleForWriting.fileDescriptor,
            audit: { _ in }, log: { _ in },
            placeholdersBound: { server, definitions in
                bindings.withLock { $0.append("\(server): " + definitions.map(\.name).joined(separator: ",")) }
            })
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            runtime.run()
            done.signal()
        }
        // Whatever fails below, nothing outlives the test. The leader is this
        // process's child, so only this process (the runtime's supervisor)
        // reaps it: its group is killed only while `waitid` (WNOHANG,
        // WNOWAIT, reaping nothing) still finds it, so a reused id is not
        // signalled, bar a reap in the instant between the check and the
        // kill. The grandchild is in that group.
        var served = false
        defer {
            if served == false {
                if let leader = pid_t(contents(scratch, "pid")), leader > 1, Self.unreaped(leader) {
                    _ = kill(-leader, SIGKILL)
                }
                try? client.toGateway.fileHandleForWriting.close()
                _ = done.wait(timeout: .now() + 10)
            }
        }
        try #require(eventually { contents(scratch, "ready") == "ready" }, "the server never got going")
        // Reported once it runs bound, with what its lease staged.
        #expect(bindings.withLock { $0 } == ["\(name): OPENAI_API_KEY"])

        // sandbox-exec and env exec in place: the shell is the group leader
        // rv spawned, and its parent is this process, not a wrapper.
        let leader = try #require(pid_t(contents(scratch, "pid")))
        #expect(getpgid(leader) == leader)
        #expect(pid_t(contents(scratch, "ppid")) == getpid())
        // KERN_PROCARGS2 hands a same-uid process the arguments and
        // environment of any non-platform process. The cage refuses it for
        // every process outside the server's own sandbox: its parent (this
        // test process, in serve's place) and another of this user's
        // processes. Its own read still works. Each caged read is made once:
        // inside the cage a process that has exited is refused EPERM too,
        // so the outside process is shown readable from here before and
        // after it, and the parent is this live process.
        #expect(contents(scratch, "procargs") == "failed errno=\(EPERM)", "\(contents(scratch, "procargs"))")
        #expect(contents(scratch, "procargs-outside") == "failed errno=\(EPERM)",
            "\(contents(scratch, "procargs-outside"))")
        #expect(contents(scratch, "procargs-self").hasPrefix("ok argc="), "\(contents(scratch, "procargs-self"))")
        let outsideAfter = Self.procargsFromHere(probe, readableWithin: 10, outside.processIdentifier, in: root)
        #expect(outsideAfter.hasSuffix(" home=yes"), "\(outsideAfter)")
        #expect(outside.isRunning)
        let environment = contents(scratch, "env")
        #expect(environment.contains("OPENAI_API_KEY=sk-rvph_"))
        #expect(environment.contains("OPENAI_BASE_URL=http://127.0.0.1:\(port)/s/OPENAI_API_KEY"))
        #expect(environment.contains(placeholderRealValue) == false)
        #expect(contents(scratch, "argv").contains(placeholderRealValue) == false)
        #expect(contents(scratch, "status") == "200")
        #expect(upstream.authorizations.withLock { $0 } == ["Bearer \(placeholderRealValue)"])

        // The same placeholder from this test process, outside the group.
        let placeholder = try #require(environment.split(separator: "\n")
            .first { $0.hasPrefix("OPENAI_API_KEY=") }.map { String($0.dropFirst("OPENAI_API_KEY=".count)) })
        #expect(loopbackStatus(port: port,
            "GET /s/OPENAI_API_KEY/models HTTP/1.1\r\nAuthorization: Bearer \(placeholder)\r\n\r\n") == 403)
        #expect(upstream.authorizations.withLock { $0.count } == 1)

        let grandchild = try #require(pid_t(contents(scratch, "grandchild")))
        #expect(kill(grandchild, 0) == 0)
        // The client goes away: serve closes the server's stdin, then SIGTERMs its group.
        try client.toGateway.fileHandleForWriting.close()
        served = done.wait(timeout: .now() + 30) == .success
        #expect(served)
        #expect(kill(leader, 0) == -1 && errno == ESRCH)
        let grandchildGone = eventually(5) { kill(grandchild, 0) == -1 && errno == ESRCH }
        #expect(grandchildGone)
        if grandchildGone == false { _ = kill(grandchild, SIGKILL) }
        #expect(broker.broker.liveCount == 0)
        #expect(fixture.auditText.contains("\"runtime\":\"mcp:\(name)\""))
        #expect(fixture.auditText.contains(placeholderRealValue) == false)
    }

    /// A bound server that never answers `initialize` is stopped at the start
    /// deadline: the kill reaches its whole group (a grandchild that ignores
    /// SIGTERM included) while serve keeps running, and its lease ends.
    @Test(.enabled(if: hostBindsPlaceholders && MCPSandbox.enforced), .timeLimit(.minutes(3)))
    func aBoundServerThatNeverAnswersInitializeHasItsWholeGroupKilled() throws {
        let temporary = try #require(MCPSandbox.resolveExisting(FileManager.default.temporaryDirectory.path))
        let root = URL(fileURLWithPath: temporary, isDirectory: true)
            .appendingPathComponent("rv-placeholder-start-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
        let name = "placeholder-start"
        let scratch = home.appendingPathComponent("Library/Caches/rv-mcp/\(name)", isDirectory: true)
        let fixture = try PlaceholderSecretsFixture()
        defer { fixture.tearDown() }
        let broker = SecretPlaceholderBroker(configDirectory: fixture.directory, resolver: CountingResolver().resolver)
        defer { broker.stop() }
        let script = """
            out="$1"
            echo $$ > "$out/pid"
            /bin/sh -c 'trap "" TERM; /bin/sleep 120' & echo $! > "$out/grandchild"
            echo ready > "$out/ready"
            while :; do /bin/sleep 0.05; done
            """
        var definition = MCPServerDefinition(
            name: name, command: "/bin/sh", args: ["-c", script, "sh", scratch.path],
            sandbox: MCPSandboxPolicy(network: false), placeholders: ["OPENAI_API_KEY"])
        // Long enough for the caged sh to start its grandchild under load.
        definition.startTimeoutSeconds = 5
        let configuration = MCPConfiguration(servers: [definition])
        let planned = try MCPLaunchPlanner.plan(
            servers: [name], configuration: configuration, secrets: PlaceholderSecretsFixture.definitions(),
            resolver: CountingResolver().resolver, baseEnvironment: ["PATH": "/usr/bin:/bin"], requireSandbox: true,
            sandbox: Self.cage(home: home, configDirectory: fixture.directory), placeholders: .broker(broker)
        ).get()
        guard case .placeholderBound = planned.first?.1 else {
            Issue.record("not bound: \(String(describing: planned.first?.1))")
            return
        }
        let client = LineClient()
        let core = MCPGatewayCore(
            configuration: configuration, upstreams: planned.map { $0.0 },
            approvals: MCPApprovalGate(consumeGrant: { _, _, _, _, _ in .none }, request: { _, _, _, _, _ in nil }),
            pinning: .unenforced, recordForward: { _ in true }, deadlines: MCPGatewayDeadlines(list: 300))
        let logged = Mutex<[String]>([])
        let runtime = MCPGatewayRuntime(
            core: core, connections: planned.map { $0.1 },
            input: client.toGateway.fileHandleForReading.fileDescriptor,
            output: client.fromGateway.fileHandleForWriting.fileDescriptor,
            audit: { _ in }, log: { line in logged.withLock { $0.append(line) } })
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            runtime.run()
            done.signal()
        }
        // Whatever fails below, nothing outlives the test (see the test above).
        var served = false
        var grandchild: pid_t?
        defer {
            if served == false {
                if let leader = pid_t(contents(scratch, "pid")), leader > 1, Self.unreaped(leader) {
                    _ = kill(-leader, SIGKILL)
                }
                try? client.toGateway.fileHandleForWriting.close()
                _ = done.wait(timeout: .now() + 10)
            }
            if let grandchild, kill(grandchild, 0) == 0 { _ = kill(grandchild, SIGKILL) }
        }
        try #require(eventually(60) { contents(scratch, "ready") == "ready" }, "the server never got going")
        let leader = try #require(pid_t(contents(scratch, "pid")))
        grandchild = try #require(pid_t(contents(scratch, "grandchild")))
        #expect(getpgid(leader) == leader)

        #expect(eventually(60) { logged.withLock { $0 }.contains { $0.contains("did not answer initialize within 5 s") } },
            "\(logged.withLock { $0 })")
        // Serve is still running; the group is gone and the lease with it.
        #expect(eventually(60) { kill(leader, 0) == -1 && errno == ESRCH })
        #expect(eventually(60) { grandchild.map { kill($0, 0) == -1 && errno == ESRCH } ?? false })
        #expect(eventually(60) { broker.broker.liveCount == 0 })
        try client.toGateway.fileHandleForWriting.close()
        served = done.wait(timeout: .now() + 30) == .success
        #expect(served)
    }

    /// A bound server that went away is planned again only once its last
    /// lease is revoked, and its new launch runs bound under a lease of its own.
    @Test(.enabled(if: hostBindsPlaceholders && MCPSandbox.enforced && python3Available), .timeLimit(.minutes(3)))
    func aRelaunchedBoundServerIsLeasedOnlyOnceItsLastLeaseEnded() async throws {
        let temporary = try #require(MCPSandbox.resolveExisting(FileManager.default.temporaryDirectory.path))
        let root = URL(fileURLWithPath: temporary, isDirectory: true)
            .appendingPathComponent("rv-placeholder-restart-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
        try Data(restartingServer.utf8).write(to: root.appendingPathComponent("server.py"))
        let name = "placeholder-restart"
        let scratch = home.appendingPathComponent("Library/Caches/rv-mcp/\(name)", isDirectory: true)
        let fixture = try PlaceholderSecretsFixture()
        defer { fixture.tearDown() }
        let broker = SecretPlaceholderBroker(configDirectory: fixture.directory, resolver: CountingResolver().resolver)
        defer { broker.stop() }
        // The launches file is in the server's scratch, one of its write roots.
        let definition = MCPServerDefinition(
            name: name, command: "python3",
            args: ["-u", root.appendingPathComponent("server.py").path, scratch.appendingPathComponent("launches").path],
            tools: MCPToolPolicy(allow: ["*"]), sandbox: MCPSandboxPolicy(network: false), placeholders: ["OPENAI_API_KEY"])
        let configuration = MCPConfiguration(servers: [definition])
        let secrets = try PlaceholderSecretsFixture.definitions()
        let base = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "TMPDIR": temporary]
        let configDirectory = fixture.directory
        let plan: @Sendable () -> Result<(MCPGatewayCore.Upstream, MCPUpstreamConnection), MCPLaunchError> = {
            MCPLaunchPlanner.plan(
                servers: [name], configuration: configuration, secrets: secrets, resolver: CountingResolver().resolver,
                baseEnvironment: base, requireSandbox: true,
                sandbox: Self.cage(home: home, configDirectory: configDirectory), placeholders: .broker(broker)
            ).flatMap { planned in planned.first.map { .success($0) } ?? .failure(.unknownServer(name)) }
        }
        let first = try plan().get()
        guard case .placeholderBound = first.1 else {
            Issue.record("not bound: \(first.1)")
            return
        }
        let core = MCPGatewayCore(
            configuration: configuration, upstreams: [first.0],
            approvals: MCPApprovalGate(consumeGrant: { _, _, _, _, _ in .none }, request: { _, _, _, _, _ in nil }),
            pinning: .unenforced, recordForward: { _ in true })
        // How many leases were live each time it was planned again.
        let liveAtRelaunch = Mutex<[Int]>([])
        let run = GatewayRun(
            core: core, connections: [first.1],
            relaunch: { _ in
                liveAtRelaunch.withLock { $0.append(broker.broker.liveCount) }
                return plan()
            })
        defer { run.stopNow() }
        #expect(await run.initialize())
        #expect(broker.broker.liveCount == 1)
        run.client.send(MCPGatewayRestartRuntimeTests.call(2, "crash"))
        _ = await MCPGatewayRestartRuntimeTests.reply(run, 2)
        let answer = await MCPGatewayRestartRuntimeTests.echoes(run, from: 3)
        #expect(answer?["result"] != nil, "\(run.logs.text)")
        #expect(liveAtRelaunch.withLock { $0 } == [0])
        #expect(broker.broker.liveCount == 1)
        #expect(MCPGatewayRestartRuntimeTests.starts(in: scratch) == 2)
        #expect(await run.finish())
        #expect(await offThePool { eventually { broker.broker.liveCount == 0 } })
    }

    /// The cage `MCPSandbox.apply` builds, for a fake home: apply() takes only
    /// the passwd home (`unreviewedHome`), and a test must not write there.
    /// Same scratch, network reach, profile and launch rewrite.
    private static func cage(
        home: URL, configDirectory: URL
    ) -> (MCPServerDefinition, MCPUpstreamLaunch, MCPCageReach) -> Result<MCPUpstreamLaunch, MCPLaunchError> {
        { definition, launch, reach in
            guard let policy = definition.sandbox else { return .failure(.sandbox("no sandbox policy")) }
            let scratch = home.appendingPathComponent("Library/Caches/rv-mcp/\(definition.name)", isDirectory: true)
            guard MCPSandbox.createCheckedDirectory(scratch.path) else {
                return .failure(.sandbox(MCPSandbox.scratchCreationFailure(scratch.path)))
            }
            let network = MCPSandbox.cageNetwork(launch.environment, proxy: nil, reach: reach)
            return MCPSandbox.profile(
                policy: policy, scratch: scratch.path, home: home.path, configDirectory: configDirectory.path,
                temporaryDirectory: launch.environment["TMPDIR"] ?? NSTemporaryDirectory(),
                loopbackPorts: network.loopbackPorts
            ).map { text in
                var caged = launch
                caged.environment = network.environment
                caged.executable = MCPSandbox.sandboxExec
                caged.arguments = ["-p", text, launch.executable] + launch.arguments
                caged.workingDirectory = scratch.path
                return caged
            }
        }
    }

    /// `procargsFromHere`, retried every 50 ms until it reads `pid`'s
    /// environment (` home=yes`) or `seconds` pass; the last answer. Only
    /// for reads that must succeed: a process still starting answers EINVAL.
    static func procargsFromHere(_ probe: URL, readableWithin seconds: TimeInterval, _ pid: pid_t, in directory: URL) -> String {
        let deadline = Date().addingTimeInterval(seconds)
        var answer = procargsFromHere(probe, pid, in: directory)
        while answer.hasSuffix(" home=yes") == false, Date() < deadline {
            usleep(50_000)
            answer = procargsFromHere(probe, pid, in: directory)
        }
        return answer
    }

    /// `rv-mcp-probe procargs <pid>` run uncaged, its answer written to a
    /// file in `directory` (no pipe another test's child could hold open);
    /// empty when it did not finish in 10 s.
    static func procargsFromHere(_ probe: URL, _ pid: pid_t, in directory: URL) -> String {
        let output = directory.appendingPathComponent("procargs-from-here-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
            let handle = try? FileHandle(forWritingTo: output)
        else { return "" }
        defer { try? handle.close() }
        let reader = Process()
        reader.executableURL = probe
        reader.arguments = ["procargs", String(pid)]
        reader.standardOutput = handle
        reader.standardError = FileHandle.nullDevice
        guard (try? reader.run()) != nil else { return "" }
        let deadline = Date().addingTimeInterval(10)
        while reader.isRunning, Date() < deadline { usleep(20_000) }
        if reader.isRunning {
            kill(reader.processIdentifier, SIGKILL)
            return ""
        }
        return contents(directory, output.lastPathComponent)
    }

    /// Whether `pid` is a child of this process not yet reaped, running or
    /// a zombie; its id cannot have been reused. Never blocks, reaps nothing.
    private static func unreaped(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0
    }
}
#endif
