#if os(macOS)
import Darwin
import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// Productive loopback servers in the cage.
///
/// Contract: a contained process may run an ordinary localhost TCP server
/// (bind 127.0.0.1/::1, ephemeral or fixed port, listen, accept) and
/// contained clients in the same workspace may connect to it. Direct
/// connect to LAN, public, and metadata addresses stays denied with EPERM,
/// UDP and Unix sockets stay denied, and the Mach/Keychain boundary is
/// unchanged.
///
/// Measured Seatbelt residuals, locked in here (see
/// `SeatbeltProfile.allowingLoopbackBind`): bind/listen/accept cannot be
/// scoped to loopback, so 0.0.0.0/::/LAN binds also succeed; host loopback
/// is shared, so another workspace or the host can also connect to a caged
/// server's port. Every test below runs a real contained child.
@Suite("SeatbeltLoopback", .serialized)
struct SeatbeltLoopbackTests {
    /// A. IPv4 bind -> listen -> accept -> connect, all inside the cage.
    @Test func ipv4BindListenAcceptConnectRoundTrip() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        try compileLoopbackProbe(in: tree.workspaceURL)
        let run = try await runLoopbackShell(
            tree, script: "./loopback roundtrip v4 >rt-v4.out 2>&1"
        ).get()
        #expect(run.exitStatus == 0)
        let text = try readLoopbackFile(tree.workspaceURL.appendingPathComponent("rt-v4.out"))
        #expect(text.contains("ROUNDTRIP V4 OK"))
        #expect(text.contains("server got hello-v4"))
        #expect(text.contains("client got HELLO-V4"))
    }

    /// B. IPv6 equivalent on ::1.
    @Test func ipv6BindListenAcceptConnectRoundTrip() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        try compileLoopbackProbe(in: tree.workspaceURL)
        let run = try await runLoopbackShell(
            tree, script: "./loopback roundtrip v6 >rt-v6.out 2>&1"
        ).get()
        #expect(run.exitStatus == 0)
        let text = try readLoopbackFile(tree.workspaceURL.appendingPathComponent("rt-v6.out"))
        #expect(text.contains("ROUNDTRIP V6 OK"))
        #expect(text.contains("server got hello-v6"))
        #expect(text.contains("client got HELLO-V6"))
    }

    /// C1. Real stdlib HTTP server plus a contained curl client on 127.0.0.1.
    /// The cage sets HTTP_PROXY, so a correct body also proves NO_PROXY
    /// bypass for loopback.
    @Test func pythonHTTPServerServesContainedCurlClient() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let python = try resolveLoopbackTool(
            ["/usr/bin/python3", "/opt/homebrew/bin/python3"], label: "python3"
        )
        let curl = try resolveLoopbackTool(["/usr/bin/curl"], label: "curl")
        try Data(loopbackPythonServer.utf8).write(
            to: tree.workspaceURL.appendingPathComponent("pyserver.py")
        )
        let script = """
        env | grep -i proxy >proxyenv.txt
        trap 'kill $SRV 2>/dev/null' EXIT
        \(lq(python)) pyserver.py >py.log 2>&1 & SRV=$!
        PORT=""; N=0
        while [ -z "$PORT" ] && [ $N -lt 100 ]; do
          [ -f pyport.txt ] && PORT=$(cat pyport.txt)
          N=$((N+1)); sleep 0.1
        done
        [ -n "$PORT" ] || { echo PY-NOPORT; exit 3; }
        \(lq(curl)) -s --max-time 10 http://127.0.0.1:$PORT/ >pygot.txt
        echo PY-DONE
        """
        let run = try await runLoopbackShell(tree, script: script).get()
        #expect(run.exitStatus == 0)
        let proxyEnv = try readLoopbackFile(
            tree.workspaceURL.appendingPathComponent("proxyenv.txt")
        )
        #expect(proxyEnv.contains("HTTP_PROXY="))
        let body = try readLoopbackFile(tree.workspaceURL.appendingPathComponent("pygot.txt"))
        #expect(body == "rv-loopback-python-ok\n")
    }

    /// C2. Real Node HTTP server plus a contained curl client on 127.0.0.1.
    @Test func nodeHTTPServerServesContainedCurlClient() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let node = try resolveLoopbackTool(
            ["\(home)/.local/bin/node", "/opt/homebrew/bin/node", "/usr/local/bin/node"],
            label: "node"
        )
        let curl = try resolveLoopbackTool(["/usr/bin/curl"], label: "curl")
        try Data(loopbackNodeServer.utf8).write(
            to: tree.workspaceURL.appendingPathComponent("nodeserver.js")
        )
        let script = """
        trap 'kill $SRV 2>/dev/null' EXIT
        \(lq(node)) nodeserver.js >node.log 2>&1 & SRV=$!
        PORT=""; N=0
        while [ -z "$PORT" ] && [ $N -lt 150 ]; do
          [ -f nodeport.txt ] && PORT=$(cat nodeport.txt)
          N=$((N+1)); sleep 0.1
        done
        [ -n "$PORT" ] || { echo NODE-NOPORT; exit 3; }
        \(lq(curl)) -s --max-time 10 http://127.0.0.1:$PORT/ >nodegot.txt
        echo NODE-DONE
        """
        let run = try await runLoopbackShell(tree, script: script).get()
        #expect(run.exitStatus == 0)
        let body = try readLoopbackFile(tree.workspaceURL.appendingPathComponent("nodegot.txt"))
        #expect(body == "rv-loopback-node-ok\n")
    }

    /// C3. The literal `python3 -m http.server` CLI on 127.0.0.1, ephemeral
    /// port, serving a real .txt file to a contained curl client. The .txt
    /// extension forces `mimetypes` table reads, which is what the MIME
    /// grant in the profile exists for.
    @Test func literalHTTPServerCLIServesTypedFile() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let python = try resolveLoopbackTool(
            ["/usr/bin/python3", "/opt/homebrew/bin/python3"], label: "python3"
        )
        let curl = try resolveLoopbackTool(["/usr/bin/curl"], label: "curl")
        try Data("rv-loopback-cli-ok\n".utf8).write(
            to: tree.workspaceURL.appendingPathComponent("cli-index.txt")
        )
        let script = """
        trap 'kill $SRV 2>/dev/null' EXIT
        \(lq(python)) -u -m http.server 0 --bind 127.0.0.1 >cli.log 2>&1 & SRV=$!
        PORT=""; N=0
        while [ -z "$PORT" ] && [ $N -lt 150 ]; do
          PORT=$(sed -n 's/.*port \\([0-9]*\\).*/\\1/p' cli.log | head -1)
          N=$((N+1)); sleep 0.1
        done
        [ -n "$PORT" ] || { echo CLI-NOPORT; exit 3; }
        \(lq(curl)) -s --max-time 10 http://127.0.0.1:$PORT/cli-index.txt >cligot.txt
        echo CLI-DONE
        """
        let run = try await runLoopbackShell(tree, script: script).get()
        #expect(run.exitStatus == 0)
        let body = try readLoopbackFile(tree.workspaceURL.appendingPathComponent("cligot.txt"))
        #expect(body == "rv-loopback-cli-ok\n")
    }

    /// D. Runtime A serves, runtime B connects, same workspace, v4 and v6.
    @Test func twoRuntimesShareLoopbackInOneWorkspace() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        try compileLoopbackProbe(in: tree.workspaceURL)
        let opened = try openLoopbackWorkspace(tree)
        defer { _ = opened.supervisor.close() }
        for family in ["v4", "v6"] {
            let host = family == "v4" ? "127.0.0.1" : "::1"
            let server = try launchLoopbackRuntime(
                opened, arguments: [
                    "-c",
                    "./loopback server \(family) port-\(family).txt got-\(family).txt pid-\(family).txt single",
                ]
            ).get()
            let portURL = tree.workspaceURL.appendingPathComponent("port-\(family).txt")
            #expect(loopbackWaitUntil(seconds: 20) {
                FileManager.default.fileExists(atPath: portURL.path)
            })
            let port = try readLoopbackFile(portURL).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(Int(port) != nil)
            let client = try launchLoopbackRuntime(
                opened, arguments: [
                    "-c",
                    "./loopback client \(family) \(host) \(port) hello-\(family) >reply-\(family).txt 2>&1",
                ]
            ).get()
            #expect(server.session.workspaceSessionID == opened.supervisor.id)
            #expect(client.session.workspaceSessionID == opened.supervisor.id)
            #expect(server.id != client.id)
            let replyURL = tree.workspaceURL.appendingPathComponent("reply-\(family).txt")
            #expect(loopbackWaitForReply(replyURL))
            let reply = try readLoopbackFile(replyURL)
            #expect(reply.contains("REPLY=HELLO-\(family == "v4" ? "V4" : "V6")"))
            let gotURL = tree.workspaceURL.appendingPathComponent("got-\(family).txt")
            #expect(loopbackWaitUntil(seconds: 20) {
                FileManager.default.fileExists(atPath: gotURL.path)
            })
            #expect(try readLoopbackFile(gotURL).contains("hello-\(family)"))
        }
    }

    /// E. Seatbelt cannot scope TCP bind/listen by address: wildcard binds
    /// succeed. Locked in as a documented residual, not as approval. If a
    /// future macOS enforces local-host matching, this test flips and the
    /// policy comment plus threat model must be tightened. The UDP control
    /// proves bind gating itself exists (protocol-scoped, not
    /// address-scoped).
    @Test func nonLoopbackBindIsNotScopedBySeatbelt() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        try compileLoopbackProbe(in: tree.workspaceURL)
        let run = try await runLoopbackShell(
            tree, script: "./loopback bindmatrix >bind.out 2>&1"
        ).get()
        #expect(run.exitStatus == 0)
        let text = try readLoopbackFile(tree.workspaceURL.appendingPathComponent("bind.out"))
        #expect(text.contains("BIND tcp-127.0.0.1 ok"))
        #expect(text.contains("BIND tcp-::1 ok"))
        #expect(text.contains("BIND tcp-0.0.0.0 ok"))
        #expect(text.contains("BIND tcp-:: ok"))
        if text.contains("LANIP none") == false {
            #expect(text.contains("BIND tcp-lan ok"))
        }
        #expect(text.contains("WLISTEN 0.0.0.0 ok"))
        #expect(text.contains("WLISTEN :: ok"))
        #expect(text.contains("UBIND 127.0.0.1 errno-1"))
    }

    /// F/G/H. Loopback connects pass the sandbox (refused only when nothing
    /// listens); LAN, metadata, and direct public connects fail with EPERM
    /// before any packet. Targets equal to an own interface address route
    /// via lo0 and are reported SKIP-OWN instead.
    @Test func loopbackOnlyConnectMatrix() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        try compileLoopbackProbe(in: tree.workspaceURL)
        let run = try await runLoopbackShell(
            tree, script: "./loopback connectmatrix >conn.out 2>&1"
        ).get()
        #expect(run.exitStatus == 0)
        let text = try readLoopbackFile(tree.workspaceURL.appendingPathComponent("conn.out"))
        let lines = text.split(separator: "\n").map(String.init)
        func line(for label: String) -> String {
            lines.first(where: { $0.hasPrefix("CONN \(label) ") }) ?? "<missing \(label)>"
        }
        // Sandbox-pass controls: refused by TCP, not by Seatbelt.
        #expect(line(for: "v4-loopback") == "CONN v4-loopback errno-61")
        #expect(line(for: "v6-loopback") == "CONN v6-loopback errno-61")
        // 127/8 beyond .1 is outside the `localhost` match.
        #expect(line(for: "v4-127.0.0.2") == "CONN v4-127.0.0.2 errno-1")
        for label in [
            "test-net", "lan-10", "lan-172", "lan-192",
            "metadata", "public-1", "public-2",
        ] {
            let found = line(for: label)
            if found.contains("SKIP-OWN") {
                let ip = String(found.split(separator: " ").last ?? "")
                #expect(lines.contains("OWN \(ip)"))
            } else {
                #expect(found == "CONN \(label) errno-1")
            }
        }
    }

    /// I+K. Cancelling the runtime kills its server; the port refuses and
    /// becomes bindable again immediately.
    @Test func cancelKillsLoopbackServerAndFreesPort() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        try compileLoopbackProbe(in: tree.workspaceURL)
        let opened = try openLoopbackWorkspace(tree)
        defer { _ = opened.supervisor.close() }
        let server = try launchLoopbackRuntime(
            opened, arguments: ["-c", "./loopback server v4 port.txt got.txt pid.txt loop"]
        ).get()
        let port = try loopbackPort(tree, name: "port.txt", seconds: 20)
        #expect(port > 0)
        #expect(loopbackHostFetch(host: "127.0.0.1", port: port, message: "ping") == "HELLO-V4")
        #expect(succeededLoopback(opened.supervisor.cancel(server.id)))
        let pid = try loopbackPID(tree, name: "pid.txt")
        #expect(loopbackWaitUntil(seconds: 10) { loopbackProcessGone(pid) })
        #expect(loopbackHostFetch(host: "127.0.0.1", port: port, message: "ping") == nil)
        #expect(loopbackHostCanBind(host: "127.0.0.1", port: port))
    }

    /// J+K. Closing the workspace kills every runtime server, v4 and v6.
    @Test func closeKillsAllLoopbackServers() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        try compileLoopbackProbe(in: tree.workspaceURL)
        let opened = try openLoopbackWorkspace(tree)
        _ = try launchLoopbackRuntime(
            opened, arguments: ["-c", "./loopback server v4 port4.txt got4.txt pid4.txt loop"]
        ).get()
        _ = try launchLoopbackRuntime(
            opened, arguments: ["-c", "./loopback server v6 port6.txt got6.txt pid6.txt loop"]
        ).get()
        let port4 = try loopbackPort(tree, name: "port4.txt", seconds: 20)
        let port6 = try loopbackPort(tree, name: "port6.txt", seconds: 20)
        #expect(loopbackHostFetch(host: "127.0.0.1", port: port4, message: "ping") == "HELLO-V4")
        #expect(loopbackHostFetch(host: "::1", port: port6, message: "ping") == "HELLO-V6")
        let pid4 = try loopbackPID(tree, name: "pid4.txt")
        let pid6 = try loopbackPID(tree, name: "pid6.txt")
        #expect(succeededLoopback(opened.supervisor.close()))
        #expect(loopbackWaitUntil(seconds: 10) {
            loopbackProcessGone(pid4) && loopbackProcessGone(pid6)
        })
        #expect(loopbackHostFetch(host: "127.0.0.1", port: port4, message: "ping") == nil)
        #expect(loopbackHostFetch(host: "::1", port: port6, message: "ping") == nil)
        #expect(loopbackHostCanBind(host: "127.0.0.1", port: port4))
        #expect(loopbackHostCanBind(host: "::1", port: port6))
    }

    /// K (explicit). After a server exits on its own, its port rebinds.
    @Test func portReusableAfterNaturalServerExit() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        try compileLoopbackProbe(in: tree.workspaceURL)
        let opened = try openLoopbackWorkspace(tree)
        defer { _ = opened.supervisor.close() }
        _ = try launchLoopbackRuntime(
            opened, arguments: ["-c", "./loopback server v4 port.txt got.txt pid.txt single"]
        ).get()
        let port = try loopbackPort(tree, name: "port.txt", seconds: 20)
        _ = try launchLoopbackRuntime(
            opened, arguments: ["-c", "./loopback client v4 127.0.0.1 \(port) hi >reply.txt 2>&1"]
        ).get()
        #expect(loopbackWaitForReply(tree.workspaceURL.appendingPathComponent("reply.txt")))
        let pid = try loopbackPID(tree, name: "pid.txt")
        #expect(loopbackWaitUntil(seconds: 10) { loopbackProcessGone(pid) })
        #expect(loopbackHostCanBind(host: "127.0.0.1", port: port))
    }

    /// M. Normal collision semantics: the second bind fails EADDRINUSE, and
    /// the port the cage reports is the port the host reaches (no remap).
    @Test func portCollisionFailsWithEADDRINUSE() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        try compileLoopbackProbe(in: tree.workspaceURL)
        let run = try await runLoopbackShell(
            tree, script: "./loopback collide >collide.out 2>&1"
        ).get()
        #expect(run.exitStatus == 0)
        let text = try readLoopbackFile(tree.workspaceURL.appendingPathComponent("collide.out"))
        #expect(text.contains("second-errno-48"))
    }

    /// N. Host loopback is shared: a runtime in another workspace, and the
    /// unsandboxed host itself, can connect to a caged server's port. There
    /// is no cross-workspace loopback isolation; locked in so a future
    /// mechanism flips this test deliberately.
    @Test func crossWorkspaceLoopbackIsShared() throws {
        let firstTree = try ContainmentTree()
        defer { firstTree.tearDown() }
        let secondTree = try ContainmentTree()
        defer { secondTree.tearDown() }
        try compileLoopbackProbe(in: firstTree.workspaceURL)
        try compileLoopbackProbe(in: secondTree.workspaceURL)
        let first = try openLoopbackWorkspace(firstTree)
        defer { _ = first.supervisor.close() }
        let second = try openLoopbackWorkspace(secondTree)
        defer { _ = second.supervisor.close() }
        #expect(first.supervisor.id != second.supervisor.id)
        _ = try launchLoopbackRuntime(
            first, arguments: ["-c", "./loopback server v4 port.txt got.txt pid.txt loop"]
        ).get()
        let port = try loopbackPort(firstTree, name: "port.txt", seconds: 20)
        _ = try launchLoopbackRuntime(
            second, arguments: ["-c", "./loopback client v4 127.0.0.1 \(port) hello-xws >reply.txt 2>&1"]
        ).get()
        let replyURL = secondTree.workspaceURL.appendingPathComponent("reply.txt")
        #expect(loopbackWaitForReply(replyURL))
        #expect(try readLoopbackFile(replyURL).contains("REPLY=HELLO-V4"))
        #expect(loopbackHostFetch(host: "127.0.0.1", port: port, message: "ping") == "HELLO-V4")
    }

    /// L. The server grant coexists with the credential boundary: loopback
    /// round trip succeeds while the Security CLI still fails at the XPC
    /// boundary (paramErr marker, never a clean service answer).
    @Test func loopbackServerCoexistsWithKeychainBoundary() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        try compileLoopbackProbe(in: tree.workspaceURL)
        let account = "rv-nonexistent-probe-\(UUID().uuidString)"
        let service = "rv-nonexistent-service-\(UUID().uuidString)"
        let run = try await runLoopbackShell(
            tree, script: """
            ./loopback roundtrip v4 >rt.out 2>&1
            /usr/bin/security find-generic-password -a \(lq(account)) -s \(lq(service)) >sec.out 2>&1; echo EXIT=$? >>sec.out
            """
        ).get()
        #expect(run.exitStatus == 0)
        let roundtrip = try readLoopbackFile(tree.workspaceURL.appendingPathComponent("rt.out"))
        #expect(roundtrip.contains("ROUNDTRIP V4 OK"))
        let security = try readLoopbackFile(tree.workspaceURL.appendingPathComponent("sec.out"))
        #expect(security.contains("EXIT=44"))
        #expect(security.contains("One or more parameters"))
    }
}

private enum LoopbackToolError: Error {
    case missing(String)
}

private func lq(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func compileLoopbackProbe(in directory: URL) throws {
    let source = directory.appendingPathComponent("loopback.c")
    let binary = directory.appendingPathComponent("loopback")
    try Data(loopbackProbeSource.utf8).write(to: source)
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
    compile.arguments = ["-O2", "-o", binary.path, source.path]
    compile.standardOutput = FileHandle.nullDevice
    compile.standardError = FileHandle.nullDevice
    try compile.run()
    compile.waitUntilExit()
    try #require(compile.terminationStatus == 0)
}

private func runLoopbackShell(
    _ tree: ContainmentTree,
    script: String
) async throws -> Result<IsolatedRunResult, IsolationApplyError> {
    let command = try #require(IsolatedCommand(executable: "/bin/sh", arguments: ["-c", script]))
    return await IsolationBackends.applyOffPool(tree.contained, command: command)
}

private func readLoopbackFile(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

private func loopbackWaitUntil(seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
}

private func loopbackPort(_ tree: ContainmentTree, name: String, seconds: TimeInterval) throws -> Int {
    let url = tree.workspaceURL.appendingPathComponent(name)
    guard loopbackWaitUntil(seconds: seconds, { FileManager.default.fileExists(atPath: url.path) }) else {
        Issue.record("loopback server did not write \(name)")
        throw LoopbackToolError.missing(name)
    }
    let port = try readLoopbackFile(url).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let number = Int(port), number > 0 else {
        Issue.record("loopback server wrote an invalid port: \(port)")
        throw LoopbackToolError.missing(name)
    }
    return number
}

/// Poll for reply CONTENT, not mere existence: the shell redirect
/// creates the file when the client starts, before it connects.
private func loopbackWaitForReply(_ url: URL, seconds: TimeInterval = 20) -> Bool {
    loopbackWaitUntil(seconds: seconds) {
        ((try? readLoopbackFile(url)) ?? "").contains("REPLY=")
    }
}

private func loopbackPID(_ tree: ContainmentTree, name: String) throws -> pid_t {
    let text = try readLoopbackFile(tree.workspaceURL.appendingPathComponent(name))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let number = Int32(text) else {
        Issue.record("loopback server wrote an invalid pid: \(text)")
        throw LoopbackToolError.missing(name)
    }
    return pid_t(number)
}

private func loopbackProcessGone(_ pid: pid_t) -> Bool {
    if kill(pid, 0) == 0 { return false }
    return errno == ESRCH
}

private func resolveLoopbackTool(_ candidates: [String], label: String) throws -> String {
    for candidate in candidates {
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    if let path = ProcessInfo.processInfo.environment["PATH"] {
        for directory in path.split(separator: ":") {
            let full = "\(directory)/\(label)"
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
    }
    Issue.record("loopback test requires \(label); tried \(candidates.joined(separator: ", ")) and PATH")
    throw LoopbackToolError.missing(label)
}

private struct OpenedLoopbackWorkspace {
    var supervisor: WorkspaceSessionSupervisor
    var runtimeLog: URL
}

private func openLoopbackWorkspace(_ tree: ContainmentTree) throws -> OpenedLoopbackWorkspace {
    let runtimeLog = tree.rootURL.appendingPathComponent("loopback-runtime-\(UUID().uuidString).jsonl")
    let lifeLog = tree.rootURL.appendingPathComponent("loopback-workspace-\(UUID().uuidString).jsonl")
    let directory = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
    let supervisor = try WorkspaceSessionSupervisor.open(
        directory,
        lifecycleLog: .file(lifeLog)
    ).get()
    return OpenedLoopbackWorkspace(supervisor: supervisor, runtimeLog: runtimeLog)
}

private func launchLoopbackRuntime(
    _ opened: OpenedLoopbackWorkspace,
    arguments: [String]
) throws -> Result<RunningRuntime, WorkspaceSessionError> {
    let command = try #require(IsolatedCommand(executable: "/bin/sh", arguments: arguments))
    return opened.supervisor.launch(
        host: .opencode,
        command: command,
        plan: compileContainedPlan(workspace: opened.supervisor.snapshot.policyWorkspace),
        io: .discard,
        admission: .failClosed,
        sessionStore: .file(opened.runtimeLog)
    )
}

private func succeededLoopback(_ result: Result<Void, WorkspaceSessionError>) -> Bool {
    if case .success = result { return true }
    return false
}

/// Unsandboxed TCP fetch from the test host. Single owner of the fd;
/// bounded by socket timeouts; nil on any failure. Used to prove a caged
/// server is reachable at the port it reported (I/J/N) and unreachable
/// after teardown.
private func loopbackHostFetch(host: String, port: Int, message: String) -> String? {
    guard (0...65535).contains(port) else { return nil }
    let family: Int32 = host.contains(":") ? AF_INET6 : AF_INET
    let fd = socket(family, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let connected: Int32
    if family == AF_INET6 {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET6, host, &address.sin6_addr) == 1 else { return nil }
        connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
    } else {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }
        connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
    guard connected == 0 else { return nil }
    let bytes = Array(message.utf8)
    guard send(fd, bytes, bytes.count, 0) == bytes.count else { return nil }
    var buffer = [UInt8](repeating: 0, count: 64)
    let count = recv(fd, &buffer, buffer.count, 0)
    guard count > 0 else { return nil }
    return String(decoding: buffer.prefix(count), as: UTF8.self)
}

/// True when the host can bind the loopback port right now (K), the way
/// every real server (python http.server, node) does: with SO_REUSEADDR.
/// Without the flag a just-closed connection's TIME_WAIT holds the port
/// with EADDRINUSE; that is normal TCP, not a leak. The companion
/// fetch-refused assertion is what proves no listener survived.
private func loopbackHostCanBind(host: String, port: Int) -> Bool {
    guard (0...65535).contains(port) else { return false }
    let family: Int32 = host.contains(":") ? AF_INET6 : AF_INET
    let fd = socket(family, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var reuse = Int32(1)
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    if family == AF_INET6 {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET6, host, &address.sin6_addr) == 1 else { return false }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        } == 0
    }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return false }
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    } == 0
}

private let loopbackPythonServer = """
import http.server


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"rv-loopback-python-ok\\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open("pyport.txt", "w") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
"""

private let loopbackNodeServer = """
const http = require('http');
const fs = require('fs');
const server = http.createServer((request, response) => {
  response.end('rv-loopback-node-ok\\n');
});
server.listen(0, '127.0.0.1', () => {
  fs.writeFileSync('nodeport.txt', String(server.address().port));
});
"""

/// Contained socket probe. Modes: `roundtrip v4|v6`, `server v4|v6
/// <portfile> <gotfile> <pidfile> single|loop`, `client v4|v6 <host> <port>
/// <msg>`, `bindmatrix`, `connectmatrix`, `collide`. Every mode is bounded
/// by alarm() so a sandbox surprise fails the test instead of hanging it.
private let loopbackProbeSource = #"""
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

static int dial_with_timeout(int family, const char *host, int port, int timeoutSecs) {
    int fd = socket(family, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int rc;
    if (family == AF_INET6) {
        struct sockaddr_in6 a;
        memset(&a, 0, sizeof(a));
        a.sin6_family = AF_INET6;
        a.sin6_port = htons((unsigned short)port);
        if (inet_pton(AF_INET6, host, &a.sin6_addr) != 1) { close(fd); errno = EINVAL; return -1; }
        rc = connect(fd, (struct sockaddr *)&a, sizeof(a));
    } else {
        struct sockaddr_in a;
        memset(&a, 0, sizeof(a));
        a.sin_family = AF_INET;
        a.sin_port = htons((unsigned short)port);
        if (inet_pton(AF_INET, host, &a.sin_addr) != 1) { close(fd); errno = EINVAL; return -1; }
        rc = connect(fd, (struct sockaddr *)&a, sizeof(a));
    }
    if (rc == 0) { fcntl(fd, F_SETFL, flags); return fd; }
    if (errno != EINPROGRESS) { int e = errno; close(fd); errno = e; return -1; }
    fd_set writers;
    FD_ZERO(&writers);
    FD_SET(fd, &writers);
    struct timeval tv;
    tv.tv_sec = timeoutSecs;
    tv.tv_usec = 0;
    rc = select(fd + 1, NULL, &writers, NULL, &tv);
    if (rc <= 0) { close(fd); errno = ETIMEDOUT; return -1; }
    int err = 0;
    socklen_t len = sizeof(err);
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
    if (err != 0) { close(fd); errno = err; return -1; }
    fcntl(fd, F_SETFL, flags);
    return fd;
}

static int is_v6(const char *family) { return strcmp(family, "v6") == 0; }

static int run_roundtrip(int v6) {
    alarm(60);
    setvbuf(stdout, NULL, _IONBF, 0);
    int family = v6 ? AF_INET6 : AF_INET;
    const char *tag = v6 ? "V6" : "V4";
    int srv = socket(family, SOCK_STREAM, 0);
    if (srv < 0) { printf("socket errno=%d\n", errno); return 1; }
    if (v6) {
        struct sockaddr_in6 a;
        memset(&a, 0, sizeof(a));
        a.sin6_family = AF_INET6;
        a.sin6_addr = in6addr_loopback;
        if (bind(srv, (struct sockaddr *)&a, sizeof(a)) != 0) { printf("bind errno=%d\n", errno); close(srv); return 1; }
        socklen_t l = sizeof(a);
        getsockname(srv, (struct sockaddr *)&a, &l);
        if (listen(srv, 5) != 0) { printf("listen errno=%d\n", errno); close(srv); return 1; }
        int port = ntohs(a.sin6_port);
        pid_t pid = fork();
        if (pid < 0) { printf("fork errno=%d\n", errno); close(srv); return 1; }
        if (pid == 0) {
            usleep(100000);
            int c = dial_with_timeout(AF_INET6, "::1", port, 15);
            if (c < 0) { printf("client connect errno=%d\n", errno); _exit(12); }
            const char *msg = "hello-v6";
            if (write(c, msg, strlen(msg)) < 0) { printf("client write errno=%d\n", errno); close(c); _exit(13); }
            char buf[64];
            ssize_t n = read(c, buf, sizeof(buf) - 1);
            if (n <= 0) { printf("client read errno=%d\n", errno); close(c); _exit(14); }
            buf[n] = 0;
            printf("client got %s\n", buf);
            close(c);
            _exit(strcmp(buf, "HELLO-V6") == 0 ? 0 : 15);
        }
        int conn = accept(srv, NULL, NULL);
        if (conn < 0) { printf("accept errno=%d\n", errno); close(srv); return 1; }
        char buf[64];
        ssize_t n = read(conn, buf, sizeof(buf) - 1);
        if (n <= 0) { printf("server read errno=%d\n", errno); close(conn); close(srv); return 1; }
        buf[n] = 0;
        printf("server got %s\n", buf);
        const char *resp = "HELLO-V6";
        write(conn, resp, strlen(resp));
        close(conn);
        close(srv);
        int status = 0;
        waitpid(pid, &status, 0);
        if (WIFEXITED(status) && WEXITSTATUS(status) == 0) { printf("ROUNDTRIP %s OK\n", tag); return 0; }
        return 1;
    }
    struct sockaddr_in a4;
    memset(&a4, 0, sizeof(a4));
    a4.sin_family = AF_INET;
    a4.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(srv, (struct sockaddr *)&a4, sizeof(a4)) != 0) { printf("bind errno=%d\n", errno); close(srv); return 1; }
    socklen_t l4 = sizeof(a4);
    getsockname(srv, (struct sockaddr *)&a4, &l4);
    if (listen(srv, 5) != 0) { printf("listen errno=%d\n", errno); close(srv); return 1; }
    int port = ntohs(a4.sin_port);
    pid_t pid = fork();
    if (pid < 0) { printf("fork errno=%d\n", errno); close(srv); return 1; }
    if (pid == 0) {
        usleep(100000);
        int c = dial_with_timeout(AF_INET, "127.0.0.1", port, 15);
        if (c < 0) { printf("client connect errno=%d\n", errno); _exit(12); }
        const char *msg = "hello-v4";
        if (write(c, msg, strlen(msg)) < 0) { printf("client write errno=%d\n", errno); close(c); _exit(13); }
        char buf[64];
        ssize_t n = read(c, buf, sizeof(buf) - 1);
        if (n <= 0) { printf("client read errno=%d\n", errno); close(c); _exit(14); }
        buf[n] = 0;
        printf("client got %s\n", buf);
        close(c);
        _exit(strcmp(buf, "HELLO-V4") == 0 ? 0 : 15);
    }
    int conn = accept(srv, NULL, NULL);
    if (conn < 0) { printf("accept errno=%d\n", errno); close(srv); return 1; }
    char buf[64];
    ssize_t n = read(conn, buf, sizeof(buf) - 1);
    if (n <= 0) { printf("server read errno=%d\n", errno); close(conn); close(srv); return 1; }
    buf[n] = 0;
    printf("server got %s\n", buf);
    const char *resp = "HELLO-V4";
    write(conn, resp, strlen(resp));
    close(conn);
    close(srv);
    int status = 0;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) { printf("ROUNDTRIP %s OK\n", tag); return 0; }
    return 1;
}

static int run_server(int v6, const char *portfile, const char *gotfile, const char *pidfile, int loop) {
    alarm(240);
    int family = v6 ? AF_INET6 : AF_INET;
    int srv = socket(family, SOCK_STREAM, 0);
    if (srv < 0) { printf("SERVER socket errno=%d\n", errno); return 1; }
    int port = 0;
    if (v6) {
        struct sockaddr_in6 a;
        memset(&a, 0, sizeof(a));
        a.sin6_family = AF_INET6;
        a.sin6_addr = in6addr_loopback;
        if (bind(srv, (struct sockaddr *)&a, sizeof(a)) != 0) { printf("SERVER bind errno=%d\n", errno); close(srv); return 1; }
        socklen_t l = sizeof(a);
        getsockname(srv, (struct sockaddr *)&a, &l);
        port = ntohs(a.sin6_port);
    } else {
        struct sockaddr_in a;
        memset(&a, 0, sizeof(a));
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(srv, (struct sockaddr *)&a, sizeof(a)) != 0) { printf("SERVER bind errno=%d\n", errno); close(srv); return 1; }
        socklen_t l = sizeof(a);
        getsockname(srv, (struct sockaddr *)&a, &l);
        port = ntohs(a.sin_port);
    }
    if (listen(srv, 16) != 0) { printf("SERVER listen errno=%d\n", errno); close(srv); return 1; }
    FILE *pf = fopen(portfile, "w");
    if (!pf) { printf("SERVER portfile errno=%d\n", errno); close(srv); return 1; }
    fprintf(pf, "%d\n", port);
    fclose(pf);
    FILE *pidf = fopen(pidfile, "w");
    if (pidf) { fprintf(pidf, "%d\n", (int)getpid()); fclose(pidf); }
    printf("SERVER %s port=%d pid=%d\n", v6 ? "V6" : "V4", port, (int)getpid());
    fflush(stdout);
    const char *resp = v6 ? "HELLO-V6" : "HELLO-V4";
    do {
        int conn = accept(srv, NULL, NULL);
        if (conn < 0) {
            if (errno == EINTR) continue;
            printf("SERVER accept errno=%d\n", errno);
            close(srv);
            return 1;
        }
        char buf[256];
        ssize_t n = read(conn, buf, sizeof(buf) - 1);
        if (n > 0) {
            buf[n] = 0;
            FILE *gf = fopen(gotfile, "a");
            if (gf) { fprintf(gf, "%s\n", buf); fclose(gf); }
            write(conn, resp, strlen(resp));
        }
        close(conn);
    } while (loop);
    close(srv);
    return 0;
}

static int run_client(int v6, const char *host, int port, const char *msg) {
    alarm(60);
    int fd = dial_with_timeout(v6 ? AF_INET6 : AF_INET, host, port, 15);
    if (fd < 0) { printf("CLIENT connect errno=%d\n", errno); return 1; }
    if (write(fd, msg, strlen(msg)) < 0) { printf("CLIENT write errno=%d\n", errno); close(fd); return 1; }
    char buf[256];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    if (n <= 0) { printf("CLIENT read n=%zd errno=%d\n", n, errno); close(fd); return 1; }
    buf[n] = 0;
    printf("CLIENT REPLY=%s\n", buf);
    close(fd);
    return 0;
}

static void tcp_bind_v4(const char *label, const char *ip) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { printf("BIND %s socket-errno-%d\n", label, errno); return; }
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    inet_pton(AF_INET, ip, &a.sin_addr);
    int rc = bind(fd, (struct sockaddr *)&a, sizeof(a));
    if (rc == 0) printf("BIND %s ok\n", label);
    else printf("BIND %s errno-%d\n", label, errno);
    close(fd);
}

static void tcp_bind_v6(const char *label, const char *ip) {
    int fd = socket(AF_INET6, SOCK_STREAM, 0);
    if (fd < 0) { printf("BIND %s socket-errno-%d\n", label, errno); return; }
    struct sockaddr_in6 a;
    memset(&a, 0, sizeof(a));
    a.sin6_family = AF_INET6;
    inet_pton(AF_INET6, ip, &a.sin6_addr);
    int rc = bind(fd, (struct sockaddr *)&a, sizeof(a));
    if (rc == 0) printf("BIND %s ok\n", label);
    else printf("BIND %s errno-%d\n", label, errno);
    close(fd);
}

static void tcp_wild_listen_v4(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { printf("WLISTEN 0.0.0.0 socket-errno-%d\n", errno); return; }
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) != 0) { printf("WLISTEN 0.0.0.0 bind-errno-%d\n", errno); close(fd); return; }
    if (listen(fd, 5) != 0) printf("WLISTEN 0.0.0.0 listen-errno-%d\n", errno);
    else printf("WLISTEN 0.0.0.0 ok\n");
    close(fd);
}

static void tcp_wild_listen_v6(void) {
    int fd = socket(AF_INET6, SOCK_STREAM, 0);
    if (fd < 0) { printf("WLISTEN :: socket-errno-%d\n", errno); return; }
    struct sockaddr_in6 a;
    memset(&a, 0, sizeof(a));
    a.sin6_family = AF_INET6;
    a.sin6_addr = in6addr_any;
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) != 0) { printf("WLISTEN :: bind-errno-%d\n", errno); close(fd); return; }
    if (listen(fd, 5) != 0) printf("WLISTEN :: listen-errno-%d\n", errno);
    else printf("WLISTEN :: ok\n");
    close(fd);
}

static int run_bindmatrix(void) {
    alarm(60);
    tcp_bind_v4("tcp-127.0.0.1", "127.0.0.1");
    tcp_bind_v4("tcp-0.0.0.0", "0.0.0.0");
    char lan[64] = "";
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) == 0) {
        for (struct ifaddrs *cursor = list; cursor; cursor = cursor->ifa_next) {
            if (!cursor->ifa_addr || cursor->ifa_addr->sa_family != AF_INET) continue;
            if ((cursor->ifa_flags & IFF_UP) == 0) continue;
            if (cursor->ifa_flags & IFF_LOOPBACK) continue;
            struct sockaddr_in *in = (struct sockaddr_in *)cursor->ifa_addr;
            if (inet_ntop(AF_INET, &in->sin_addr, lan, sizeof(lan))) break;
            lan[0] = 0;
        }
        freeifaddrs(list);
    }
    if (lan[0]) {
        printf("LANIP %s\n", lan);
        tcp_bind_v4("tcp-lan", lan);
    } else {
        printf("LANIP none\n");
        printf("BIND tcp-lan none\n");
    }
    tcp_bind_v6("tcp-::1", "::1");
    tcp_bind_v6("tcp-::", "::");
    tcp_wild_listen_v4();
    tcp_wild_listen_v6();
    int udp = socket(AF_INET, SOCK_DGRAM, 0);
    if (udp < 0) {
        printf("UBIND 127.0.0.1 socket-errno-%d\n", errno);
    } else {
        struct sockaddr_in a;
        memset(&a, 0, sizeof(a));
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(udp, (struct sockaddr *)&a, sizeof(a)) == 0) printf("UBIND 127.0.0.1 ok\n");
        else printf("UBIND 127.0.0.1 errno-%d\n", errno);
        close(udp);
    }
    return 0;
}

static int own_v4[16];
static int own_v4_count = 0;

static void collect_own_v4(void) {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return;
    for (struct ifaddrs *cursor = list; cursor; cursor = cursor->ifa_next) {
        if (!cursor->ifa_addr || cursor->ifa_addr->sa_family != AF_INET) continue;
        if (cursor->ifa_flags & IFF_LOOPBACK) continue;
        if (own_v4_count >= 16) break;
        struct sockaddr_in *in = (struct sockaddr_in *)cursor->ifa_addr;
        own_v4[own_v4_count++] = (int)in->sin_addr.s_addr;
        char text[64];
        if (inet_ntop(AF_INET, &in->sin_addr, text, sizeof(text))) printf("OWN %s\n", text);
    }
    freeifaddrs(list);
}

static int is_own_v4(const char *ip) {
    struct in_addr parsed;
    if (inet_pton(AF_INET, ip, &parsed) != 1) return 0;
    for (int i = 0; i < own_v4_count; i++) {
        if (own_v4[i] == (int)parsed.s_addr) return 1;
    }
    return 0;
}

static void try_connect_v4(const char *label, const char *ip, int port) {
    if (is_own_v4(ip)) { printf("CONN %s SKIP-OWN %s\n", label, ip); return; }
    int fd = dial_with_timeout(AF_INET, ip, port, 5);
    if (fd >= 0) { printf("CONN %s ok\n", label); close(fd); return; }
    printf("CONN %s errno-%d\n", label, errno);
}

static void try_connect_v6(const char *label, const char *ip, int port) {
    int fd = dial_with_timeout(AF_INET6, ip, port, 5);
    if (fd >= 0) { printf("CONN %s ok\n", label); close(fd); return; }
    printf("CONN %s errno-%d\n", label, errno);
}

static int run_connectmatrix(void) {
    alarm(120);
    collect_own_v4();
    try_connect_v4("v4-loopback", "127.0.0.1", 1);
    try_connect_v6("v6-loopback", "::1", 1);
    try_connect_v4("v4-127.0.0.2", "127.0.0.2", 1);
    try_connect_v4("test-net", "192.0.2.1", 80);
    try_connect_v4("lan-10", "10.255.255.1", 80);
    try_connect_v4("lan-172", "172.16.0.1", 80);
    try_connect_v4("lan-192", "192.168.0.1", 80);
    try_connect_v4("metadata", "169.254.169.254", 80);
    try_connect_v4("public-1", "1.1.1.1", 443);
    try_connect_v4("public-2", "8.8.8.8", 53);
    return 0;
}

static int run_collide(void) {
    alarm(60);
    int first = socket(AF_INET, SOCK_STREAM, 0);
    if (first < 0) { printf("COLLIDE socket errno=%d\n", errno); return 1; }
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(first, (struct sockaddr *)&a, sizeof(a)) != 0) { printf("COLLIDE bind errno=%d\n", errno); close(first); return 1; }
    socklen_t l = sizeof(a);
    getsockname(first, (struct sockaddr *)&a, &l);
    int port = ntohs(a.sin_port);
    if (listen(first, 5) != 0) { printf("COLLIDE listen errno=%d\n", errno); close(first); return 1; }
    int second = socket(AF_INET, SOCK_STREAM, 0);
    if (second < 0) { printf("COLLIDE socket2 errno=%d\n", errno); close(first); return 1; }
    struct sockaddr_in b;
    memset(&b, 0, sizeof(b));
    b.sin_family = AF_INET;
    b.sin_port = htons((unsigned short)port);
    b.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int rc = bind(second, (struct sockaddr *)&b, sizeof(b));
    if (rc == 0) printf("COLLIDE port=%d second-errno-0\n", port);
    else printf("COLLIDE port=%d second-errno-%d\n", port, errno);
    close(second);
    close(first);
    return rc == 0 ? 1 : 0;
}

int main(int argc, char **argv) {
    alarm(300);
    if (argc < 2) { printf("usage: loopback <mode> ...\n"); return 64; }
    if (strcmp(argv[1], "roundtrip") == 0 && argc == 3) return run_roundtrip(is_v6(argv[2]));
    if (strcmp(argv[1], "server") == 0 && argc == 7)
        return run_server(is_v6(argv[2]), argv[3], argv[4], argv[5], strcmp(argv[6], "loop") == 0);
    if (strcmp(argv[1], "client") == 0 && argc == 6)
        return run_client(is_v6(argv[2]), argv[3], atoi(argv[4]), argv[5]);
    if (strcmp(argv[1], "bindmatrix") == 0) return run_bindmatrix();
    if (strcmp(argv[1], "connectmatrix") == 0) return run_connectmatrix();
    if (strcmp(argv[1], "collide") == 0) return run_collide();
    printf("unknown mode %s\n", argv[1]);
    return 64;
}
"""#

@Test func loopbackHelpersRejectOutOfRangePorts() {
    // Ports outside UInt16 trap on conversion; the helpers fail closed.
    #expect(loopbackHostFetch(host: "127.0.0.1", port: -1, message: "x") == nil)
    #expect(loopbackHostFetch(host: "127.0.0.1", port: 65_536, message: "x") == nil)
    #expect(loopbackHostCanBind(host: "127.0.0.1", port: -1) == false)
    #expect(loopbackHostCanBind(host: "127.0.0.1", port: 70_000) == false)
}
#endif

