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
private func eventually(_ seconds: TimeInterval = 15, _ condition: () -> Bool) -> Bool {
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

/// A stdio MCP server through the real planner, serve's own sandbox hook
/// (`MCPSandbox.apply`), the runtime and `sandbox-exec`.
@Suite("MCP server placeholders (live sandbox-exec)")
struct MCPPlaceholderLiveTests {
    @Test(.enabled(if: hostBindsPlaceholders && MCPSandbox.enforced), .timeLimit(.minutes(2)))
    func aCagedServerSpendsItsPlaceholderAndServeEndsItsWholeGroup() throws {
        // apply() takes only the account's own home; the server's scratch is
        // its rv-mcp cache directory there, under a name no other test uses.
        let home = URL(fileURLWithPath: try #require(MCPSandbox.passwdHome()), isDirectory: true)
        let name = "placeholder-live-" + UUID().uuidString.prefix(8).lowercased()
        let scratch = home.appendingPathComponent("Library/Caches/rv-mcp/\(name)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
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
        let script = """
            out="$1"
            env > "$out/env"; printf '%s %s' "$*" > "$out/argv"; echo $$ > "$out/pid"; echo $PPID > "$out/ppid"
            "$2" procargs $PPID > "$out/procargs" 2>&1
            /usr/bin/curl -s --max-time 10 --noproxy '*' -o /dev/null -w '%{http_code}' \
              -H "Authorization: Bearer $OPENAI_API_KEY" "$OPENAI_BASE_URL/models" > "$out/status"
            /bin/sh -c 'trap "" TERM; /bin/sleep 60' & echo $! > "$out/grandchild"
            echo ready > "$out/ready"
            while :; do /bin/sleep 0.05; done
            """
        let definition = MCPServerDefinition(
            name: name, command: "/bin/sh", args: ["-c", script, "sh", scratch.path, probe.path],
            sandbox: MCPSandboxPolicy(network: false), placeholders: ["OPENAI_API_KEY"])
        let configuration = MCPConfiguration(servers: [definition])
        let planned = try MCPLaunchPlanner.plan(
            servers: [name], configuration: configuration, secrets: PlaceholderSecretsFixture.definitions(),
            resolver: CountingResolver().resolver, baseEnvironment: ["PATH": "/usr/bin:/bin"], requireSandbox: true,
            sandbox: MCPSandbox.apply(configDirectory: fixture.directory, home: home), placeholders: .broker(broker)
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
        // The kernel answers the caged server's read of its parent (here this
        // test process, in serve rv): the arguments, but no environment.
        let procargs = contents(scratch, "procargs")
        #expect(procargs.hasPrefix("ok argc=\(CommandLine.arguments.count) "), "\(procargs)")
        #expect(procargs.hasSuffix(" home=no"), "\(procargs)")
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
        served = done.wait(timeout: .now() + 15) == .success
        #expect(served)
        #expect(kill(leader, 0) == -1 && errno == ESRCH)
        let grandchildGone = eventually(5) { kill(grandchild, 0) == -1 && errno == ESRCH }
        #expect(grandchildGone)
        if grandchildGone == false { _ = kill(grandchild, SIGKILL) }
        #expect(broker.broker.liveCount == 0)
        #expect(fixture.auditText.contains("\"runtime\":\"mcp:\(name)\""))
        #expect(fixture.auditText.contains(placeholderRealValue) == false)
    }

    /// Whether `pid` is a child of this process not yet reaped, running or
    /// a zombie; its id cannot have been reused. Never blocks, reaps nothing.
    private static func unreaped(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0
    }
}
#endif
